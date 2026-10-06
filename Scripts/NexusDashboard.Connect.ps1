#Requires -Version 7

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
      even when a request fails;
    o records every run in a log file - the login, each request, every
      cluster node and switch returned, and any failure - bounded by
      size-based rotation, the same way DNA.DiscoverNodesAndInterfaces.ps1
      bounds its own log.

    The functions - Connect-NexusDashboard, Update-NexusDashboardToken,
    Invoke-NexusDashboardApi and Disconnect-NexusDashboard - are written to
    be reused unchanged by the discovery script that builds on this one.

    Requires PowerShell 7+ for the -SkipCertificateCheck switch on
    Invoke-RestMethod, like the DNA, FMC and Check Point scripts. Nexus
    Dashboard ships with a self-signed certificate, so use
    -TrustAllCertificates while testing and import the certificate into the
    trust store for production use.

.PARAMETER NXServer
    Host name or IP address of the Nexus Dashboard (the cluster's management
    address). The API is reached on HTTPS port 443.

.PARAMETER NXCredentialPath
    Path to a credential saved with Export-Clixml, for unattended runs
    (scheduled task). Pass an empty string to be prompted instead. Create
    the file once, as the account the task runs under:
        Get-Credential | Export-Clixml -Path D:\SolarWindsScripts\PowerShell\Credentials\NexusDashboard_Credential.xml

.PARAMETER NXDomain
    The ND login domain the user authenticates against. "TACACS" is the
    TACACS+ login domain; it must match the domain name configured in ND
    (Admin > Authentication > Login Domains) exactly, case included. Use
    "DefaultAuth" for a user from the local ND user database.

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

.PARAMETER LogPath
    The log file this script writes to. It is bounded by rotation rather
    than by age, the same way DNA.DiscoverNodesAndInterfaces.ps1 bounds its
    own log.

.PARAMETER LogMaxBytes
    The size at which the log is rotated. Rotation keeps LogKeep older
    generations beside it, so the space the logging can occupy is bounded at
    roughly LogMaxBytes times LogKeep plus one.

.PARAMETER LogKeep
    How many rotated logs to keep. Zero keeps none: the log starts over
    instead.

.EXAMPLE
    .\NexusDashboard.Connect.ps1 -NXServer nd.example.local -TrustAllCertificates

    Reads the credential from the default -NXCredentialPath and prints the
    cluster nodes and the switch inventory.

.EXAMPLE
    .\NexusDashboard.Connect.ps1 -NXServer nd.example.local -NXCredentialPath ''

    Prompts for the credential instead of reading it from a file.
#>

param(
    # --- Cisco Nexus Dashboard connection ---
    [string]$NXServer = "1.1.1.1",
    [string]$NXCredentialPath = "D:\SolarWindsScripts\PowerShell\Credentials\FMC_Credential.xml",
    [string]$NXDomain = "TACACS",

    [switch]$TrustAllCertificates,

    [ValidateRange(1, 19)]
    [int]$TokenRefreshMinutes = 15,

    [switch]$SkipSwitchInventory,

    [string] $LogPath = (Join-Path -Path $env:ProgramData -ChildPath 'SolarWinds\nexusdashboard-connect.log'),

    [ValidateRange(4KB, 100MB)]
    [int] $LogMaxBytes = 1MB,

    [ValidateRange(0, 20)]
    [int] $LogKeep = 3
)

# --- Logging ---
# Taken from DNA.DiscoverNodesAndInterfaces.ps1: one log file bounded by
# size-based rotation, the same level set and line format, and the same lazy
# creation of the log directory on first write. The file calls carry
# -ErrorAction Stop of their own, since this script does not set
# $ErrorActionPreference = 'Stop'; without it a failed write escapes the
# catch as a raw error instead of the intended warning.

function Invoke-LogRotation {
    # Renames the log out of the way once it reaches -LogMaxBytes, keeping
    # -LogKeep older generations: .log -> .log.1, .log.1 -> .log.2, and so on,
    # with the oldest dropped. Run on a schedule the log would otherwise grow
    # without bound.
    param(
        [Parameter(Mandatory)][string] $Path
    )

    if (-not (Test-Path -LiteralPath $Path)) { return }
    if ((Get-Item -LiteralPath $Path).Length -lt $script:LogMaxBytes) { return }

    # Nothing to keep: the log simply starts over.
    if ($script:LogKeep -lt 1) {
        Remove-Item -LiteralPath $Path -Force -WhatIf:$false -Confirm:$false -ErrorAction Stop
        return
    }

    # Oldest generation falls off the end.
    $oldest = "$Path.$($script:LogKeep)"
    if (Test-Path -LiteralPath $oldest) {
        Remove-Item -LiteralPath $oldest -Force -WhatIf:$false -Confirm:$false -ErrorAction Stop
    }

    # Shift the rest down, highest first so nothing is overwritten on the way.
    for ($i = $script:LogKeep - 1; $i -ge 1; $i--) {
        $from = "$Path.$i"
        if (Test-Path -LiteralPath $from) {
            Move-Item -LiteralPath $from -Destination "$Path.$($i + 1)" -Force -WhatIf:$false -Confirm:$false -ErrorAction Stop
        }
    }

    Move-Item -LiteralPath $Path -Destination "$Path.1" -Force -WhatIf:$false -Confirm:$false -ErrorAction Stop
}

function Write-Log {
    <#
    .SYNOPSIS
        Record one line in the run log, and on the console unless suppressed
    .PARAMETER NoConsole
        Write to the log file only. Used for the per-item detail lines - every
        cluster node and switch - which belong in the record but would bury
        the console output.
    #>
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Message,

        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string] $Level = 'INFO',

        [switch] $NoConsole
    )

    $line = '{0:yyyy-MM-dd HH:mm:ss} [{1,-5}] {2}' -f (Get-Date), $Level, $Message
    if (-not $NoConsole) {
        Write-Information -MessageData $line -InformationAction Continue
    }

    # -WhatIf:$false so that the log keeps being written even if a caller
    # passes -WhatIf through; the log is a record, never one of the changes
    # being previewed.
    try {
        $directory = Split-Path -Path $script:LogPath -Parent
        if ($directory -and -not (Test-Path -LiteralPath $directory)) {
            New-Item -Path $directory -ItemType Directory -Force -WhatIf:$false -Confirm:$false -ErrorAction Stop | Out-Null
        }
        Invoke-LogRotation -Path $script:LogPath
        Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8 -WhatIf:$false -Confirm:$false -ErrorAction Stop
    }
    catch {
        Write-Warning "Could not write to the log file '$script:LogPath': $($_.Exception.Message)"
    }
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
    if ($TrustAllCertificates) {
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
    if ($Session.TrustAllCertificates) {
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
        Write-Log "Token refreshed on $($Session.Server)."
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
    if ($Session.TrustAllCertificates) {
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
        Write-Log "Logged out of $($Session.Server)."
    }
    catch {
        Write-Log "Logout from $($Session.Server) failed: $($_.Exception.Message)" -Level WARN
    }
}

# --- Main --------------------------------------------------------------------

Write-Log "===== Run started ====="

# A saved credential for unattended runs, otherwise a prompt that keeps the
# password as a SecureString.
try {
    if ($NXCredentialPath) {
        $credential = Import-Clixml -Path $NXCredentialPath -ErrorAction Stop
        Write-Log "Credential read from $NXCredentialPath."
    }
    else {
        $credential = Get-Credential -Message "Nexus Dashboard API credentials"
    }
}
catch {
    Write-Log "Failed to read the credential: $($_.Exception.Message)" -Level ERROR
    exit 1
}
if (-not $credential) {
    Write-Log "No credential was given - nothing to do." -Level ERROR
    exit 1
}

try {
    $session = Connect-NexusDashboard -Server $NXServer `
        -Username $credential.UserName `
        -Password $credential.Password `
        -Domain $NXDomain `
        -TokenRefreshMinutes $TokenRefreshMinutes `
        -TrustAllCertificates:$TrustAllCertificates
}
catch {
    Write-Log $_.Exception.Message -Level ERROR
    exit 1
}

Write-Log "Connected to $NXServer as $($session.Username) (domain $NXDomain)."

$exitCode = 0
try {
    # Read-only call that proves the session works: the nodes that make up the
    # Nexus Dashboard cluster itself.
    $clusterNodes = @(
        (Invoke-NexusDashboardApi -Session $session -Path "/nexus/infra/api/platform/v1/nodes").items |
            Where-Object { $_ } |
            ForEach-Object {
                [pscustomobject]@{
                    Name   = $_.spec.name
                    Serial = $_.spec.serialNumber
                    Role   = $_.spec.role
                    State  = $_.status.nodeState
                }
            }
    )

    Write-Log "Nexus Dashboard returned $($clusterNodes.Count) cluster node[s]."
    foreach ($node in $clusterNodes) {
        Write-Log "  cluster node    | name=$($node.Name) | serial=$($node.Serial) | role=$($node.Role) | state=$($node.State)" -NoConsole
    }
    $clusterNodes | Format-Table -AutoSize | Out-String | Write-Host

    if ($SkipSwitchInventory) {
        Write-Log "Switch inventory skipped (-SkipSwitchInventory)."
    }
    else {
        # The switch inventory managed by the Fabric Controller (NDFC) service on
        # this Nexus Dashboard. These are the components that the next step adds to
        # SolarWinds as nodes, by their management IP address.
        #
        # The response is a JSON array; @() unrolls it whether it arrives as one
        # array object or one switch at a time.
        $rawSwitches = Invoke-NexusDashboardApi -Session $session `
            -Path "/appcenter/cisco/ndfc/api/v1/lan-fabric/rest/inventory/allswitches"
        $switches = @(
            @($rawSwitches) |
                Where-Object { $_ } |
                ForEach-Object {
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
                }
        )

        $withIp = @($switches | Where-Object { $_.IPAddress }).Count
        Write-Log "Fabric Controller returned $($switches.Count) switch[es], $withIp with a management IP address."
        foreach ($device in $switches) {
            Write-Log "  switch          | name=$($device.Name) | IP=$($device.IPAddress) | model=$($device.Model) | serial=$($device.Serial) | fabric=$($device.Fabric) | status=$($device.Status)" -NoConsole
        }
        $switches | Format-Table -AutoSize | Out-String | Write-Host
    }
}
catch {
    Write-Log $_.Exception.Message -Level ERROR
    $exitCode = 1
}
finally {
    Disconnect-NexusDashboard -Session $session
    Write-Log "=== Run finished ===" -NoConsole
}

exit $exitCode
