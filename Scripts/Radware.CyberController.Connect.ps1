# This sample script demonstrates how to authenticate against the Radware
# Cyber Controller (formerly APSolute Vision) management REST API, keep the
# returned JSESSIONID for follow-up calls, run a couple of read-only requests
# and log out cleanly.
#
# The API summary this script is based on - endpoints, headers and the session
# model - is in Docs/Radware.CyberController.REST-API.md.
#
# Please update the Cyber Controller details and credential setup below to match
# your environment.
#
# Works on Windows PowerShell 5.1 and PowerShell 7+. The appliance ships with a
# self-signed certificate, so use -TrustAllCertificates while testing and import
# the certificate into the trust store for production use.

function Set-CyberControllerCertificatePolicy {
    # PowerShell 5.1 has no -SkipCertificateCheck on Invoke-RestMethod, so the
    # validation callback has to be relaxed process wide instead.
    if ($PSVersionTable.PSVersion.Major -ge 6) { return }

    if (-not ("RadwareTrustAllCertsPolicy" -as [type])) {
        Add-Type @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class RadwareTrustAllCertsPolicy : ICertificatePolicy {
    public bool CheckValidationResult(ServicePoint sp, X509Certificate cert, WebRequest req, int problem) {
        return true;
    }
}
"@
    }

    [System.Net.ServicePointManager]::CertificatePolicy = New-Object RadwareTrustAllCertsPolicy
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
}

function Connect-CyberController {
    param(
        [Parameter(Mandatory = $true)] [string]$Server,
        [int]$Port = 443,
        [Parameter(Mandatory = $true)] [string]$Username,
        [Parameter(Mandatory = $true)] [System.Security.SecureString]$Password,
        [switch]$TrustAllCertificates
    )

    if ($TrustAllCertificates) { Set-CyberControllerCertificatePolicy }

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
        username = $Username
        password = $plainPassword
    } | ConvertTo-Json

    $params = @{
        Uri             = "$baseUri/mgmt/system/user/login"
        Method          = "Post"
        Body            = $body
        ContentType     = "application/json"
        SessionVariable = "webSession"
    }
    if ($TrustAllCertificates -and $PSVersionTable.PSVersion.Major -ge 6) {
        $params["SkipCertificateCheck"] = $true
    }

    $response = Invoke-RestMethod @params

    # Cyber Controller answers with HTTP 200 even when the credentials are wrong,
    # so the status field in the body is what decides success.
    if ($response.status -and $response.status -ne "ok") {
        throw "Login to $Server failed: $($response.message)"
    }

    $jsessionId = $response.jsessionid
    if (-not $jsessionId) {
        # Older versions only return the session as a cookie.
        $cookie = $webSession.Cookies.GetCookies($baseUri) |
            Where-Object { $_.Name -eq "JSESSIONID" } |
            Select-Object -First 1
        $jsessionId = $cookie.Value
    }
    if (-not $jsessionId) {
        throw "Login to $Server succeeded but no JSESSIONID was returned."
    }

    [pscustomobject]@{
        Server               = $Server
        Port                 = $Port
        BaseUri              = $baseUri
        JSessionId           = $jsessionId
        TrustAllCertificates = [bool]$TrustAllCertificates
    }
}

function Invoke-CyberControllerApi {
    param(
        [Parameter(Mandatory = $true)] [pscustomobject]$Session,
        [Parameter(Mandatory = $true)] [string]$Path,
        [ValidateSet("Get", "Post", "Put", "Delete")] [string]$Method = "Get",
        $Body
    )

    $params = @{
        Uri     = "$($Session.BaseUri)/$($Path.TrimStart('/'))"
        Method  = $Method
        Headers = @{ "Cookie" = "JSESSIONID=$($Session.JSessionId)" }
    }
    if ($null -ne $Body) {
        $params["Body"] = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 10 }
        $params["ContentType"] = "application/json"
    }
    if ($Session.TrustAllCertificates -and $PSVersionTable.PSVersion.Major -ge 6) {
        $params["SkipCertificateCheck"] = $true
    }

    Invoke-RestMethod @params
}

function Disconnect-CyberController {
    param(
        [Parameter(Mandatory = $true)] [pscustomobject]$Session
    )

    # Sessions are limited per user and only expire on the idle timeout, so a
    # script that does not log out slowly consumes them.
    Invoke-CyberControllerApi -Session $Session -Path "/mgmt/system/user/logout" | Out-Null
}

# --- Example usage ----------------------------------------------------------

$server = "cybercontroller.example.local"
$username = "radware"

# Prompts once and keeps the password as a SecureString. For unattended runs,
# read the credential from a secret store instead of prompting, e.g.
#   $credential = Get-Secret -Name CyberControllerApi
$credential = Get-Credential -UserName $username -Message "Cyber Controller API credentials"

$session = Connect-CyberController -Server $server `
    -Username $credential.UserName `
    -Password $credential.Password `
    -TrustAllCertificates

Write-Host "Connected to $server, session $($session.JSessionId)"

try {
    # Read-only call that proves the session works: the inventory of the devices
    # managed by this Cyber Controller.
    $devices = Invoke-CyberControllerApi -Session $session -Path "/mgmt/system/config/itemlist/alldevices"

    foreach ($device in $devices) {
        [pscustomobject]@{
            Name      = $device.name
            IPAddress = $device.managementIp
            Type      = $device.deviceType
            Status    = $device.status
        }
    }
}
finally {
    Disconnect-CyberController -Session $session
    Write-Host "Session closed."
}
