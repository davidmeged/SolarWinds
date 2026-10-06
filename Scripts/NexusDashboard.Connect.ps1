# This sample script demonstrates how to authenticate against the Cisco Nexus
# Dashboard (ND) REST API, keep the returned JWT for follow-up calls, refresh it
# before it expires, run a couple of read-only requests and log out cleanly.
#
# It is the first building block of the Nexus Dashboard -> SolarWinds
# integration: once the session works, the switch inventory read at the bottom
# is what later gets added to SolarWinds as nodes, the same way
# DNA.DiscoverNodesAndInterfaces.ps1 does it for Cisco DNA Center.
#
# Please update the Nexus Dashboard details and credential setup below to match
# your environment.
#
# Works on Windows PowerShell 5.1 and PowerShell 7+. Nexus Dashboard ships with a
# self-signed certificate, so use -TrustAllCertificates while testing and import
# the certificate into the trust store for production use.

function Set-NexusDashboardCertificatePolicy {
    # PowerShell 5.1 has no -SkipCertificateCheck on Invoke-RestMethod, so the
    # validation callback has to be relaxed process wide instead.
    if ($PSVersionTable.PSVersion.Major -ge 6) { return }

    if (-not ("NexusDashboardTrustAllCertsPolicy" -as [type])) {
        Add-Type @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class NexusDashboardTrustAllCertsPolicy : ICertificatePolicy {
    public bool CheckValidationResult(ServicePoint sp, X509Certificate cert, WebRequest req, int problem) {
        return true;
    }
}
"@
    }

    [System.Net.ServicePointManager]::CertificatePolicy = New-Object NexusDashboardTrustAllCertsPolicy
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
}

function Get-NexusDashboardErrorMessage {
    # Turns a failed Invoke-RestMethod into one readable line: the HTTP status
    # plus the error text ND puts in the body, when there is one.
    param(
        [Parameter(Mandatory = $true)] [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    $status = $null
    if ($ErrorRecord.Exception.Response) {
        $status = [int]$ErrorRecord.Exception.Response.StatusCode
    }

    $detail = $ErrorRecord.ErrorDetails.Message
    if (-not $detail) { $detail = $ErrorRecord.Exception.Message }

    if ($status) { "HTTP ${status}: $detail" } else { $detail }
}

function Connect-NexusDashboard {
    param(
        [Parameter(Mandatory = $true)] [string]$Server,
        [int]$Port = 443,
        [Parameter(Mandatory = $true)] [string]$Username,
        [Parameter(Mandatory = $true)] [System.Security.SecureString]$Password,
        # Login domain. "DefaultAuth" is the local user database; for a remote
        # (RADIUS/TACACS/LDAP) user pass the login domain name configured in ND.
        [string]$Domain = "DefaultAuth",
        [switch]$TrustAllCertificates
    )

    if ($TrustAllCertificates) { Set-NexusDashboardCertificatePolicy }

    # PtrToStringBSTR (rather than PtrToStringAuto) decodes the BSTR as UTF-16 on
    # every platform, and the buffer is zeroed again right after it is read.
    $passwordPtr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
    try {
        $plainPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($passwordPtr)
    }
    finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($passwordPtr)
    }

    $baseUri = "https://${Server}:${Port}"

    $body = @{
        userName   = $Username
        userPasswd = $plainPassword
        domain     = $Domain
    } | ConvertTo-Json

    $params = @{
        Uri             = "$baseUri/login"
        Method          = "Post"
        Body            = $body
        ContentType     = "application/json"
        SessionVariable = "webSession"
    }
    if ($TrustAllCertificates -and $PSVersionTable.PSVersion.Major -ge 6) {
        $params["SkipCertificateCheck"] = $true
    }

    try {
        $response = Invoke-RestMethod @params
    }
    catch {
        throw "Login to $Server failed: $(Get-NexusDashboardErrorMessage -ErrorRecord $_)"
    }

    # The token is returned as "jwttoken" (older releases also mirror it in
    # "token") and set as the AuthCookie cookie; any of the three will do.
    $token = $response.jwttoken
    if (-not $token) { $token = $response.token }
    if (-not $token) {
        $cookie = $webSession.Cookies.GetCookies($baseUri) |
            Where-Object { $_.Name -eq "AuthCookie" } |
            Select-Object -First 1
        $token = $cookie.Value
    }
    if (-not $token) {
        throw "Login to $Server succeeded but no token was returned."
    }

    [pscustomobject]@{
        Server               = $Server
        Port                 = $Port
        BaseUri              = $baseUri
        Username             = $Username
        Token                = $token
        IssuedAt             = Get-Date
        TrustAllCertificates = [bool]$TrustAllCertificates
    }
}

function Update-NexusDashboardToken {
    # ND tokens are short lived (20 minutes by default), so a long run - such as
    # walking a large switch inventory - has to renew the token before it lapses.
    # The refreshed token replaces the old one on the session object in place.
    param(
        [Parameter(Mandatory = $true)] [pscustomobject]$Session
    )

    $params = @{
        Uri         = "$($Session.BaseUri)/refresh"
        Method      = "Post"
        Headers     = @{ "Authorization" = "Bearer $($Session.Token)" }
        ContentType = "application/json"
    }
    if ($Session.TrustAllCertificates -and $PSVersionTable.PSVersion.Major -ge 6) {
        $params["SkipCertificateCheck"] = $true
    }

    try {
        $response = Invoke-RestMethod @params
    }
    catch {
        throw "Token refresh on $($Session.Server) failed: $(Get-NexusDashboardErrorMessage -ErrorRecord $_)"
    }

    $token = $response.jwttoken
    if (-not $token) { $token = $response.token }
    if (-not $token) {
        throw "Token refresh on $($Session.Server) returned no token."
    }

    $Session.Token = $token
    $Session.IssuedAt = Get-Date
}

function Invoke-NexusDashboardApi {
    param(
        [Parameter(Mandatory = $true)] [pscustomobject]$Session,
        [Parameter(Mandatory = $true)] [string]$Path,
        [ValidateSet("Get", "Post", "Put", "Delete")] [string]$Method = "Get",
        $Body,
        # Renew the token once it is older than this, ahead of the 20 minute
        # default expiry.
        [int]$RefreshAfterMinutes = 15
    )

    if (((Get-Date) - $Session.IssuedAt).TotalMinutes -ge $RefreshAfterMinutes) {
        Update-NexusDashboardToken -Session $Session
    }

    $params = @{
        Uri     = "$($Session.BaseUri)/$($Path.TrimStart('/'))"
        Method  = $Method
        Headers = @{ "Authorization" = "Bearer $($Session.Token)" }
    }
    if ($null -ne $Body) {
        $params["Body"] = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 10 }
        $params["ContentType"] = "application/json"
    }
    if ($Session.TrustAllCertificates -and $PSVersionTable.PSVersion.Major -ge 6) {
        $params["SkipCertificateCheck"] = $true
    }

    try {
        Invoke-RestMethod @params
    }
    catch {
        throw "$Method $Path on $($Session.Server) failed: $(Get-NexusDashboardErrorMessage -ErrorRecord $_)"
    }
}

function Disconnect-NexusDashboard {
    param(
        [Parameter(Mandatory = $true)] [pscustomobject]$Session
    )

    # Logging out invalidates the token right away instead of leaving it valid
    # until it expires. A failure here is not worth failing the run over.
    try {
        Invoke-NexusDashboardApi -Session $Session -Path "/logout" -Method Post | Out-Null
    }
    catch {
        Write-Warning "Logout from $($Session.Server) failed: $($_.Exception.Message)"
    }
}

# --- Example usage ----------------------------------------------------------

$server = "nexusdashboard.example.local"
$username = "admin"

# Prompts once and keeps the password as a SecureString. For unattended runs,
# read the credential from a secret store instead of prompting, e.g.
#   $credential = Get-Secret -Name NexusDashboardApi
$credential = Get-Credential -UserName $username -Message "Nexus Dashboard API credentials"

$session = Connect-NexusDashboard -Server $server `
    -Username $credential.UserName `
    -Password $credential.Password `
    -TrustAllCertificates

Write-Host "Connected to $server as $($session.Username)"

try {
    # Read-only call that proves the session works: the nodes that make up the
    # Nexus Dashboard cluster itself.
    $clusterNodes = Invoke-NexusDashboardApi -Session $session -Path "/nexus/infra/api/platform/v1/nodes"

    Write-Host "Nexus Dashboard cluster nodes:"
    $clusterNodes.items | ForEach-Object {
        [pscustomobject]@{
            Name   = $_.spec.name
            Serial = $_.spec.serialNumber
            Role   = $_.spec.role
            State  = $_.status.nodeState
        }
    } | Format-Table -AutoSize | Out-String | Write-Host

    # The switch inventory managed by the Fabric Controller (NDFC) service on
    # this Nexus Dashboard. These are the components that the next step adds to
    # SolarWinds as nodes, by their management IP address.
    $switches = Invoke-NexusDashboardApi -Session $session `
        -Path "/appcenter/cisco/ndfc/api/v1/lan-fabric/rest/inventory/allswitches"

    Write-Host "Switches managed by Nexus Dashboard Fabric Controller:"
    $switches | ForEach-Object {
        [pscustomobject]@{
            Name      = $_.logicalName
            IPAddress = $_.ipAddress
            Model     = $_.model
            Serial    = $_.serialNumber
            Fabric    = $_.fabricName
            Role      = $_.switchRole
            Version   = $_.release
            Status    = $_.status
        }
    } | Format-Table -AutoSize | Out-String | Write-Host
}
finally {
    Disconnect-NexusDashboard -Session $session
    Write-Host "Session closed."
}
