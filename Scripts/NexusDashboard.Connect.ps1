#Requires -Version 7

<#
.SYNOPSIS
    SolarWinds SWIS PowerShell script  add the switches managed by Cisco Nexus Dashboard as nodes and discover their interfaces

.DESCRIPTION
    This script combines the Cisco Nexus Dashboard (ND) REST API with two
    building blocks from the SolarWinds SDK samples, the same way
    DNA.DiscoverNodesAndInterfaces.ps1 does it for Cisco DNA Center:

    o Nexus Dashboard REST API
        - authenticates (POST /login) against the login domain given in
          -NXDomain and keeps the returned JWT for follow-up calls;
        - refreshes the token (POST /refresh) before it expires - ND tokens
          are valid for 20 minutes by default;
        - reads the switch inventory managed by the Fabric Controller (NDFC)
          service;
        - logs out (POST /logout) as soon as the inventory is read, so the
          token is revoked rather than left valid while the nodes are added.

    o CRUD.AddNode.ps1
        - adds a node <component> using CRUD operations (New-SwisObject) and
          registers the standard set of pollers for it (Status, Response
          Time, Details, Uptime).

    o NPM.DiscoverAndAddInterfacesOnNode.ps1
        - uses Orion.NPM.Interfaces.DiscoverInterfacesOnNode and
          Orion.NPM.Interfaces.AddInterfacesOnNode (SWISv3 verbs, NPM only)
          to discover and add the interfaces of a node.

    The result is a single script that walks the switches Nexus Dashboard
    reports, adds every one of them that does not already exist in
    SolarWinds by its management IP address - with the switch name as the
    node caption - and then discovers and adds their interfaces for
    monitoring. -InterfaceFilter decides which interfaces are kept.

    Every run records each switch returned, each component that was added,
    already existed, was skipped or failed, every interface that was added,
    and every poller that was registered, followed by a summary line.

    Please update the parameter defaults below to match your environment
    before running.

.PARAMETER NXServer
    Host name or IP address of the Nexus Dashboard (the cluster's management
    address). The API is reached on the default HTTPS port (443).

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

.PARAMETER TokenRefreshMinutes
    Age, in minutes, after which the ND token is renewed before the next
    call. Must stay below the token lifetime configured in ND (20 minutes by
    default).

.PARAMETER SwisHost
    Address of the SolarWinds server (SWIS).

.PARAMETER SwisCredentialPath
    Path to a PSCredential exported with Export-Clixml for a SolarWinds user
    that can add nodes.

.PARAMETER EngineID
    SolarWinds polling engine the new nodes are assigned to.

.PARAMETER SNMPVersion
    SNMP version used to poll the new nodes.

.PARAMETER SNMPCommunity
    SNMP community configured on the switches. Without it the Details/Uptime
    pollers and the interface discovery have nothing to poll.

.PARAMETER InterfaceFilter
    Regular expression matched against the interface caption. Only the
    interfaces that match it and are operationally up (ifOperStatus 1) are
    added. The default keeps the NX-OS physical ports and port-channels
    (Ethernet1/1, Eth1/1, port-channel10, Po10); everything else - mgmt0,
    Vlan, loopback, nve and the like - is left out. The match is not case
    sensitive.

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
    .\NexusDashboard.Connect.ps1

    Runs with the defaults set in the param block.

.EXAMPLE
    .\NexusDashboard.Connect.ps1 -NXServer nd.example.local -SwisHost orion.example.local `
        -SNMPCommunity "mycommunity"

.NOTES
    Requires PowerShell 7+ for the -SkipCertificateCheck switch on
    Invoke-RestMethod, and the SwisPowerShell module for Connect-Swis.

    The certificate of the Nexus Dashboard is not validated: ND ships with a
    self-signed certificate, so Connect-NexusDashboard is always called with
    -TrustAllCertificates, the same way FMC.DiscoverNodes.ps1 calls
    Connect-Fmc. Once ND carries a certificate the server trusts, drop that
    switch from the call so the certificate is checked again.
#>

param(
    # --- Cisco Nexus Dashboard connection ---
    [string]$NXServer = "1.1.1.1",
    [string]$NXCredentialPath = "D:\SolarWindsScripts\PowerShell\Credentials\FMC_Credential.xml",
    [string]$NXDomain = "TACACS",

    [ValidateRange(1, 19)]
    [int]$TokenRefreshMinutes = 15,

    # --- SolarWinds connection ---
    [string]$SwisHost = "5.5.5.5",
    [string]$SwisCredentialPath = "D:\SolarWindsScripts\PowerShell\Credentials\SolarWindsCredentials.xml",

    # Shared settings applied to every switch retrieved from Nexus Dashboard.
    [int]$EngineID = 2,
    [int]$SNMPVersion = 2,
    [string]$SNMPCommunity = '',
    [string]$InterfaceFilter = '^(Ethernet|Eth\d|port-channel|Po\d)',

    # --- Log ---
    [string] $LogPath = (Join-Path -Path $env:ProgramData -ChildPath 'SolarWinds\nexusdashboard-discover-nodes.log'),

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
        switch, component, interface and poller - which belong in the record
        but would bury the console summary.
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

    $baseUri = "https://$Server"

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
    #
    # Nexus Dashboard 3.2 answers POST /logout with 405 (Method Not Allowed),
    # so GET is tried next. If neither is accepted there is nothing more to
    # do: the token simply expires on its own after the ND session timeout
    # (20 minutes by default), the same way the DNA token is left to expire.
    foreach ($method in @("Post", "Get")) {
        $params = @{
            Uri     = "$($Session.BaseUri)/logout"
            Method  = $method
            Headers = @{ "Authorization" = "Bearer $($Session.Token)" }
        }
        if ($Session.TrustAllCertificates) {
            $params["SkipCertificateCheck"] = $true
        }

        try {
            Invoke-RestMethod @params | Out-Null
            Write-Log "Logged out of $($Session.Server) ($($method.ToUpper()) /logout)."
            return
        }
        catch {
            $status = $null
            if ($_.Exception.Response) {
                $status = [int]$_.Exception.Response.StatusCode
            }
            if ($status -eq 405) { continue }

            Write-Log "Logout from $($Session.Server) failed: $(Get-NexusDashboardErrorMessage -ErrorRecord $_)" -Level WARN
            return
        }
    }

    Write-Log "Nexus Dashboard on $($Session.Server) accepts no logout request - the token is left to expire on its own."
}

# --- Function: Read the switch inventory from Nexus Dashboard ---
function Get-NexusDashboardSwitches {
    <#
    .SYNOPSIS
        Get the switches managed by the Fabric Controller (NDFC) service
    .PARAMETER Session
        The session returned by Connect-NexusDashboard
    .OUTPUTS
        One object per switch: Name, IPAddress, Model, Serial, Fabric, Role,
        Version and Status
    #>
    param(
        [Parameter(Mandatory = $true)] [pscustomobject]$Session
    )

    # The response is a JSON array; @() unrolls it whether it arrives as one
    # array object or one switch at a time.
    $rawSwitches = Invoke-NexusDashboardApi -Session $Session `
        -Path "/appcenter/cisco/ndfc/api/v1/lan-fabric/rest/inventory/allswitches"

    @($rawSwitches) | Where-Object { $_ } | ForEach-Object {
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
}

# --- Function: End the Nexus Dashboard and SWIS sessions ---
function Stop-Sessions {
    <#
    .SYNOPSIS
        End the Nexus Dashboard and SWIS sessions opened by this script
    .DESCRIPTION
        Nexus Dashboard publishes a logout endpoint, so the token is revoked
        rather than left to expire.

        SWIS has no Disconnect-Swis cmdlet, but Connect-Swis returns an
        InfoServiceProxy, which is IDisposable, so the connection can be
        closed explicitly instead of being left to the finalizer.

        Safe to call more than once - each session is ended only once.
    #>
    if ($script:ndSession) {
        Disconnect-NexusDashboard -Session $script:ndSession
        $script:ndSession = $null
    }

    if ($script:swis) {
        try {
            $script:swis.Close()
            Write-Log "Closed the SWIS connection."
        } catch {
            Write-Log "Failed to close the SWIS connection: $($_.Exception.Message)" -Level WARN
        }
        $script:swis = $null
    }
}

# --- Counters for the summary at the end of the run ---
$script:stats = [ordered]@{
    ComponentsAdded    = 0
    ComponentsExisting = 0
    ComponentsSkipped  = 0
    ComponentsFailed   = 0
    InterfacesAdded    = 0
    PollersAdded       = 0
}

Write-Log "===== Run started: Nexus Dashboard $NXServer -> SolarWinds $SwisHost ====="

# --- Connect to Nexus Dashboard ---
# A saved credential for unattended runs, otherwise a prompt that keeps the
# password as a SecureString.
try {
    if ($NXCredentialPath) {
        $ndCredential = Import-Clixml -Path $NXCredentialPath -ErrorAction Stop
    }
    else {
        $ndCredential = Get-Credential -Message "Nexus Dashboard API credentials"
    }
    if (-not $ndCredential) {
        throw "No credential was given."
    }

    $ndSession = Connect-NexusDashboard -Server $NXServer `
        -Username $ndCredential.UserName `
        -Password $ndCredential.Password `
        -Domain $NXDomain `
        -TokenRefreshMinutes $TokenRefreshMinutes `
        -TrustAllCertificates
    Write-Log "Connected to Nexus Dashboard $NXServer as $($ndSession.Username) (domain $NXDomain)."
} catch {
    Write-Log "Failed to authenticate with Nexus Dashboard: $($_.Exception.Message)" -Level ERROR
    Stop-Sessions
    exit 1
}

# Call function "Get-NexusDashboardSwitches"
try {
    $switches = @(Get-NexusDashboardSwitches -Session $ndSession)
} catch {
    Write-Log "Failed to retrieve switches from Nexus Dashboard: $($_.Exception.Message)" -Level ERROR
    Stop-Sessions
    exit 1
}

# The switch list is all that is needed from Nexus Dashboard, so log out now
# instead of keeping the token alive while the nodes are added.
Stop-Sessions

$withIp = @($switches | Where-Object { $_.IPAddress }).Count
Write-Log "Nexus Dashboard returned $($switches.Count) switch[es], $withIp with a management IP address."
foreach ($device in $switches) {
    Write-Log "  switch          | name=$($device.Name) | IP=$($device.IPAddress) | model=$($device.Model) | serial=$($device.Serial) | fabric=$($device.Fabric) | status=$($device.Status)" -NoConsole
}

if ($switches.Count -eq 0) {
    Write-Log "Nexus Dashboard returned no switches - nothing to process." -Level WARN
    exit
}

# --- Connect to SWIS ---
try {
    $swisCredential = Import-Clixml -Path $SwisCredentialPath -ErrorAction Stop
    $swis = Connect-Swis -Hostname $SwisHost -Credential $swisCredential
    Write-Log "Connected to SolarWinds Information Service (SWIS) on $SwisHost."
} catch {
    Write-Log "Failed to connect to SWIS: $($_.Exception.Message)" -Level ERROR
    Stop-Sessions
    exit 1
}

# --- Build the list of components to process ---
# Build $components from the switches returned by Nexus Dashboard: the
# management IP address is what the node is added by, and the switch name is
# kept as the node caption. A switch without a valid IP address is skipped
# with a warning.
$components = foreach ($device in $switches) {
    $address = $null
    $ip = "$($device.IPAddress)".Trim()

    if (-not $ip -or -not [System.Net.IPAddress]::TryParse($ip, [ref]$address)) {
        Write-Log "Skipping '$($device.Name)' - no usable management IP address ('$($device.IPAddress)')." -Level WARN
        Write-Log "  component       | name=$($device.Name) | IP=$($device.IPAddress) | status=skipped" -NoConsole
        $script:stats.ComponentsSkipped++
        continue
    }

    @{
        IPAddress   = $address.ToString()
        Caption     = $device.Name
        EngineID    = $EngineID
        SNMPVersion = $SNMPVersion
        DNS         = ""
        SysName     = ""
        Community   = $SNMPCommunity
    }
}

# --- Function: Add a Node [Component] ---
function Add-Component {
    param($component)

    $newNodeProps = @{
        IPAddress       = $component.IPAddress
        EngineID        = $component.EngineID
        Caption         = $component.Caption
        # SNMP v2 specific
        ObjectSubType   = "SNMP"
        SNMPVersion     = $component.SNMPVersion
        DNS             = $component.DNS
        SysName         = $component.SysName
        Community       = $component.Community
        # === default values ===
        # EntityType    = 'Orion.Nodes'
        # DynamicIP     = $false
        # PollInterval  = 120
        # RediscoveryInterval = 30
        # StatCollection    = 10
    }

    $newNodeUri = New-SwisObject -SwisConnection $swis -EntityType "Orion.Nodes" -Properties $newNodeProps
    $nodeProps  = Get-SwisObject -SwisConnection $swis -Uri $newNodeUri

    # Register the standard set of pollers for the node
    $poller = @{
        NetObject     = "N:" + $nodeProps["NodeID"]
        NetObjectType = "N"
        NetObjectID   = $nodeProps["NodeID"]
    }

    foreach ($pollerType in @(
        "N.Status.ICMP.Native",
        "N.ResponseTime.ICMP.Native",
        "N.Details.SNMP.Generic",
        "N.Uptime.SNMP.Generic"
    )) {
        $poller["PollerType"] = $pollerType
        New-SwisObject -SwisConnection $swis -EntityType "Orion.Pollers" -Properties $poller | Out-Null
        Write-Log "  poller added    | NodeID=$($nodeProps['NodeID']) | pollerType=$pollerType" -NoConsole
        $script:stats.PollersAdded++
    }

    return $nodeProps["NodeID"]
}

# --- Function: Discover and Add Interfaces on a Node ---
function Add-DiscoveredInterfaces {
    param($nodeId)

    # Discover interfaces on the node
    $discovered = Invoke-SwisVerb $swis Orion.NPM.Interfaces DiscoverInterfacesOnNode $nodeId

    if ($discovered.Result -ne "Succeed") {
        Write-Log " Interface discovery failed for node $nodeId." -Level ERROR
        return
    }

    # Keep only the interfaces that match -InterfaceFilter and are
    # operationally up (ifOperStatus 1); everything else is removed before
    # the add.
    #
    # The node list is materialised with @() first: RemoveChild shrinks the
    # live XmlNodeList, and removing from it while the pipeline is still
    # enumerating it skips nodes.
    @($discovered.DiscoveredInterfaces.DiscoveredLiteInterface) | Where-Object {
        $_.Caption.InnerText -notmatch $InterfaceFilter -or
        $_.ifOperStatus -ne '1'
    } | ForEach-Object { $discovered.DiscoveredInterfaces.RemoveChild($_) | Out-Null }

    # Where-Object drops the null that an emptied node list yields: @($null)
    # has a Count of 1, so without it a run that filtered every interface away
    # would report one interface and still call the add verb with nothing.
    $interfaceCount = @($discovered.DiscoveredInterfaces.DiscoveredLiteInterface | Where-Object { $_ }).Count

    if ($interfaceCount -eq 0) {
        Write-Log " No interfaces left to add for node $($nodeId) after filtering."
        return
    }

    # Add the remaining interfaces. The node's interfaces are read before and
    # after the add, so the log names exactly the interfaces that were added
    # and not the ones that were already monitored.
    $interfaceQuery = "SELECT InterfaceID, Caption FROM Orion.NPM.Interfaces WHERE NodeID = @nodeId"
    try {
        $before = @(Get-SwisData -SwisConnection $swis -Query $interfaceQuery -Parameters @{ nodeId = $nodeId } | ForEach-Object { $_.InterfaceID })

        Invoke-SwisVerb $swis Orion.NPM.Interfaces AddInterfacesOnNode @($nodeId, $discovered.DiscoveredInterfaces, "AddDefaultPollers") | Out-Null

        $added = @(Get-SwisData -SwisConnection $swis -Query $interfaceQuery -Parameters @{ nodeId = $nodeId } |
            Where-Object { $before -notcontains $_.InterfaceID })

        if ($added.Count -eq 0) {
            Write-Log " No new interfaces for node $($nodeId) - the $interfaceCount matching interface[s] were already monitored."
            return
        }

        Write-Log " Added $($added.Count) interface[s] for node $($nodeId)."
        foreach ($interface in $added) {
            Write-Log "  interface added | NodeID=$nodeId | InterfaceID=$($interface.InterfaceID) | caption=$($interface.Caption)" -NoConsole
        }
        $script:stats.InterfacesAdded += $added.Count
    } catch {
        Write-Log " Failed to add interfaces for node $($nodeId): $($_.Exception.Message)" -Level ERROR
    }
}

# --- Main Loop: Process each component ---
foreach ($component in $components) {
    Write-Log "Processing component $($component.Caption) ($($component.IPAddress))..."

    try {
        # Check if node already exists
        $existing = Get-SwisData -SwisConnection $swis -Query "SELECT NodeID FROM Orion.Nodes WHERE IPAddress = @ip" -Parameters @{ ip = $component.IPAddress }

        if ($existing) {
            $nodeId = @($existing)[0]
            Write-Log " Node already exists [NodeID $nodeId], skipping add."
            Write-Log "  component       | name=$($component.Caption) | IP=$($component.IPAddress) | status=exists | NodeID=$nodeId" -NoConsole
            $script:stats.ComponentsExisting++
        }
        else {
            $nodeId = Add-Component $component
            Write-Log " Added node [NodeID $nodeId]."
            Write-Log "  component       | name=$($component.Caption) | IP=$($component.IPAddress) | status=added | NodeID=$nodeId" -NoConsole
            $script:stats.ComponentsAdded++
        }

        # Discover and add interfaces for the node (whether new or existing)
        Add-DiscoveredInterfaces $nodeId

    } catch {
        Write-Log " Failed to process $($component.Caption) ($($component.IPAddress)): $($_.Exception.Message)" -Level ERROR
        Write-Log "  component       | name=$($component.Caption) | IP=$($component.IPAddress) | status=failed" -NoConsole
        $script:stats.ComponentsFailed++
    }
}

# --- End the SWIS session ---
Stop-Sessions

$summary = "Summary: $($script:stats.ComponentsAdded) component[s] added, " +
           "$($script:stats.ComponentsExisting) already existed, " +
           "$($script:stats.ComponentsSkipped) skipped, " +
           "$($script:stats.ComponentsFailed) failed; " +
           "$($script:stats.InterfacesAdded) interface[s] and " +
           "$($script:stats.PollersAdded) poller[s] added."
Write-Log $summary

Write-Log "Script completed."
Write-Log "=== Run finished ===" -NoConsole

# A scheduled task sees the run as failed when any component failed.
if ($script:stats.ComponentsFailed -gt 0) { exit 1 }
