<#
.SYNOPSIS
    Cisco Nexus Dashboard REST API - connect, read the switch inventory and
    log out

.DESCRIPTION
    First building block of the Nexus Dashboard -> SolarWinds integration.
    The script:

    o authenticates against the Nexus Dashboard (ND) REST API (POST /login)
      and keeps the returned JWT for follow-up calls;
    o refreshes the token (POST /refresh) before it expires - ND tokens are
      valid for 20 minutes by default, so a long run would otherwise fail
      half way;
    o runs two read-only requests that prove the session works:
        - the nodes of the Nexus Dashboard cluster itself;
        - the switch inventory managed by the Fabric Controller (NDFC)
          service. These switches are the components that the next step
          adds to SolarWinds as nodes by their management IP address, the
          same way DNA.DiscoverNodesAndInterfaces.ps1 does it for Cisco DNA
          Center;
    o logs out (POST /logout) in a finally block, so the token is revoked
      even when a request fails.

    The functions - Connect-NexusDashboard, Update-NexusDashboardToken,
    Invoke-NexusDashboardApi and Disconnect-NexusDashboard - are written to
    be reused unchanged by the discovery script that builds on this one.

    Works on Windows PowerShell 5.1 and PowerShell 7+. Nexus Dashboard ships
    with a self-signed certificate, so use -TrustAllCertificates while
    testing and import the certificate into the trust store for production
    use.

.PARAMETER Server
    Host name or IP address of the Nexus Dashboard (the cluster's management
    address).

.PARAMETER Port
    HTTPS port of the Nexus Dashboard API. 443 unless it was changed.

.PARAMETER Username
    The API user. Only used when -CredentialPath is not given: it is the
    name pre-filled in the credential prompt.

.PARAMETER Domain
    Login domain. "DefaultAuth" is the local user database; for a remote
    (RADIUS/TACACS/LDAP) user pass the login domain name configured in ND.

.PARAMETER CredentialPath
    Path to a credential saved with Export-Clixml, for unattended runs
    (scheduled task). Without it the script prompts for the password.
    Create the file once, as the account the task runs under:
        Get-Credential | Export-Clixml -Path .\Credentials\NexusDashboardCredential.xml

.PARAMETER TrustAllCertificates
    Accept the self-signed certificate of the Nexus Dashboard. Meant for
    testing; import the certificate into the trust store for production.

.PARAMETER TokenRefreshMinutes
    Age, in minutes, after which the token is renewed before the next call.
    Must stay below the token lifetime configured in ND (20 minutes by
    default).

.PARAMETER SkipSwitchInventory
    Only test the login and the cluster nodes, without reading the switch
    inventory. Use it when the Fabric Controller service is not installed on
    this Nexus Dashboard - the inventory request fails without it.

.EXAMPLE
    .\NexusDashboard.Connect.ps1 -Server nd.example.local -TrustAllCertificates

    Prompts for the password of "admin" and prints the cluster nodes and the
    switch inventory.

.EXAMPLE
    .\NexusDashboard.Connect.ps1 -Server nd.example.local -Domain RadiusDomain `
        -CredentialPath .\Credentials\NexusDashboardCredential.xml

    Unattended run as a RADIUS user, with the credential read from a file.
#>

param(
    # --- Cisco Nexus Dashboard connection ---
    [string]$NXServer = "1.1.1.1",
    [string]$NXCredentialPath = "D:\SolarWindsScripts\PowerShell\Credentials\FMC_Credential.xml",

    [switch]$TrustAllCertificates,

    [ValidateRange(1, 19)]
    [int]$TokenRefreshMinutes = 15,

    [switch]$SkipSwitchInventory
)

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
        [switch]$TrustAllCertificates,
        # Renew the token once it is older than this, ahead of the 20 minute
        # default expiry.
        [int]$TokenRefreshMinutes = 15
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
        TokenRefreshMinutes  = $TokenRefreshMinutes
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
        $Body
    )

    if (((Get-Date) - $Session.IssuedAt).TotalMinutes -ge $Session.TokenRefreshMinutes) {
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

# --- Main --------------------------------------------------------------------

# A saved credential for unattended runs, otherwise a prompt that keeps the
# password as a SecureString.
if ($NXCredentialPath) {
    $credential = Import-Clixml -Path $CredentialPath
}
else {
    $credential = Get-Credential -UserName $Username -Message "Nexus Dashboard API credentials"
}

$session = Connect-NexusDashboard -Server $NXServer
    -Username $NXCredentialPath.UserName `
    -Password $NXCredentialPath.Password `
    -Domain $Domain `
    -TokenRefreshMinutes $TokenRefreshMinutes `
    -TrustAllCertificates:$TrustAllCertificates

Write-Host "Connected to $NXServer as $($session.Username)"

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

    if (-not $SkipSwitchInventory) {
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
}
finally {
    Disconnect-NexusDashboard -Session $session
    Write-Host "Session closed."
}
