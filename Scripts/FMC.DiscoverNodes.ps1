<#
.SYNOPSIS
    SolarWinds SWIS PowerShell script  add the devices managed by Cisco FMC as nodes and discover their interfaces

.DESCRIPTION
    This script combines the Cisco Secure Firewall Management Center (FMC)
    REST API with a building block from the SolarWinds SDK samples:

    o FMC REST API
        - authenticates with auth/generatetoken and reads the device records
          (the managed FTD devices) of the Global domain, page by page.

    o CRUD.AddNode.ps1
        - adds a node <component> using CRUD operations (New-SwisObject) and
          registers the standard set of pollers for it (Status, Response
          Time, Details, Uptime).

    o NPM.DiscoverAndAddInterfacesOnNode.ps1
        - uses Orion.NPM.Interfaces.DiscoverInterfacesOnNode and
          Orion.NPM.Interfaces.AddInterfacesOnNode (SWISv3 verbs, NPM only)
          to discover and add the interfaces of a node.

    The result is a single script that walks the devices FMC reports, adds
    every one of them that does not already exist in SolarWinds, and then
    discovers and adds their interfaces for monitoring. The interface filter
    in Add-DiscoveredInterfaces decides which interfaces are kept - adjust
    it to the interfaces you want monitored on the FTD devices.

    FMC registers a device by its management address, which may be an IP
    address or a DNS name. A DNS name is resolved to its first IPv4 address,
    because SolarWinds nodes are added by IP address. A device whose address
    cannot be resolved is skipped with a warning.

    FMC API notes:
      - generatetoken takes HTTP Basic auth and returns the access token, the
        refresh token and the Global domain UUID as response headers (no body).
      - An access token is valid for 30 minutes and can be refreshed up to 3
        times with the refresh token; the script refreshes it on a 401.
      - The API is rate limited to 120 requests per minute; on a 429 the
        script waits and retries.
      - The token is revoked (auth/revokeaccess) once the devices are read.

    Please update the parameter defaults below to match your environment
    before running.

.PARAMETER FmcServer
    Address of the FMC (IP or DNS name, optionally with :port).

.PARAMETER FmcCredentialPath
    Path to a PSCredential exported with Export-Clixml for a FMC user with
    REST API access. Create it once, as the account that runs the script:
        Get-Credential | Export-Clixml -Path <path>

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
    SNMP community configured on the FTD devices (FMC: Devices > Platform
    Settings > SNMP). Without it the Details/Uptime pollers have nothing to
    poll.

.PARAMETER UnDPNames
    Universal Device Pollers (UnDP) to assign to every node, by their name
    in the Universal Device Poller tool (Orion.NPM.CustomPollers.UniqueName).
    Before a UnDP is assigned, the device is asked for the UnDP's OID with an
    SNMP v2c GETNEXT - the same check as "Test" in the UnDP tool - and the
    UnDP is assigned only when the device answers inside that OID. Nodes
    that do not support it are logged and left without it. Only node UnDPs
    are handled; interface UnDPs are skipped with a warning. Empty (the
    default) assigns no UnDP.

.PARAMETER UnDPCheckOnly
    Run the UnDP support check and log which nodes support each UnDP, but
    assign nothing.

.PARAMETER LogPath
    The log file. Every run appends to it: each device that already existed
    or was added, every poller type registered on a new node, every
    interface added, and a summary line at the end of the run.

.PARAMETER LogMaxBytes
    The size at which the log is rotated. Rotation keeps LogKeep older
    generations beside it, so the space the logging can occupy is bounded at
    roughly LogMaxBytes times LogKeep plus one.

.PARAMETER LogKeep
    How many rotated logs to keep. Zero keeps none: the log starts over
    instead.

.EXAMPLE
    .\FMC.DiscoverNodes.ps1

    Runs with the defaults set in the param block.

.EXAMPLE
    .\FMC.DiscoverNodes.ps1 -FmcServer fmc.example.com -SwisHost orion.example.com -SNMPCommunity "mycommunity"

.EXAMPLE
    .\FMC.DiscoverNodes.ps1 -UnDPNames "ftdConnections","ftdVpnSessions" -UnDPCheckOnly

    Logs which devices support the two UnDPs without assigning them.

.NOTES
    Requires PowerShell 7+ for the -SkipCertificateCheck switch on
    Invoke-RestMethod / Invoke-WebRequest, and the SwisPowerShell module for
    Connect-Swis.
#>

param(
    # --- Cisco FMC connection ---
    [string]$FmcServer = "1.1.1.1",
    [string]$FmcCredentialPath = "D:\SolarWindsScripts\PowerShell\Credentials\FMC_Credential.xml",

    # --- SolarWinds connection ---
    [string]$SwisHost = "5.5.5.5",
    [string]$SwisCredentialPath = "D:\SolarWindsScripts\PowerShell\Credentials\SolarWindsCredentials.xml",

    # Shared settings applied to every device retrieved from FMC.
    [int]$EngineID = 2,
    [int]$SNMPVersion = 2,
    [string]$SNMPCommunity = '',

    # --- Universal Device Pollers (UnDP) ---
    [string[]]$UnDPNames = @(),
    [switch]$UnDPCheckOnly,

    # --- Log ---
    [string]$LogPath = (Join-Path -Path $env:ProgramData -ChildPath 'SolarWinds\fmc-discover-nodes.log'),

    [ValidateRange(4KB, 100MB)]
    [int]$LogMaxBytes = 1MB,

    [ValidateRange(0, 20)]
    [int]$LogKeep = 3
)

# --- Function: Rotate the log once it reaches LogMaxBytes ---
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
        Remove-Item -LiteralPath $Path -Force
        return
    }

    # Oldest generation falls off the end.
    $oldest = "$Path.$($script:LogKeep)"
    if (Test-Path -LiteralPath $oldest) {
        Remove-Item -LiteralPath $oldest -Force
    }

    # Shift the rest down, highest first so nothing is overwritten on the way.
    for ($i = $script:LogKeep - 1; $i -ge 1; $i--) {
        $from = "$Path.$i"
        if (Test-Path -LiteralPath $from) {
            Move-Item -LiteralPath $from -Destination "$Path.$($i + 1)" -Force
        }
    }

    Move-Item -LiteralPath $Path -Destination "$Path.1" -Force
}

# --- Function: Write a line to the console and the log ---
function Write-Log {
    <#
    .SYNOPSIS
        Show a message on the console and append it to the log file
    .PARAMETER Message
        The text to record
    .PARAMETER Level
        INFO goes to the console with Write-Host (in -Color when given),
        WARN with Write-Warning and ERROR in red
    .PARAMETER Color
        Console color for an INFO message
    #>
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Message,

        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string] $Level = 'INFO',

        [System.ConsoleColor] $Color
    )

    switch ($Level) {
        'WARN'  { Write-Warning $Message }
        'ERROR' { Write-Host $Message -ForegroundColor Red }
        default {
            if ($PSBoundParameters.ContainsKey('Color')) {
                Write-Host $Message -ForegroundColor $Color
            } else {
                Write-Host $Message
            }
        }
    }

    $line = '{0:yyyy-MM-dd HH:mm:ss} [{1,-5}] {2}' -f (Get-Date), $Level, $Message

    try {
        $directory = Split-Path -Path $script:LogPath -Parent
        if ($directory -and -not (Test-Path -LiteralPath $directory)) {
            New-Item -Path $directory -ItemType Directory -Force | Out-Null
        }
        Invoke-LogRotation -Path $script:LogPath
        Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8
    }
    catch {
        Write-Warning "Could not write to the log file '$script:LogPath': $($_.Exception.Message)"
    }
}

# --- Function: Read a header from a FMC response ---
function Get-FmcHeaderValue {
    param(
        [Parameter(Mandatory = $true)] $Headers,
        [Parameter(Mandatory = $true)] [string]$Name
    )

    # PowerShell 7 returns every response header as a string array, so take
    # the first value instead of relying on the array being turned into a
    # string later.
    $value = @($Headers[$Name])[0]
    if ([string]::IsNullOrWhiteSpace($value)) {
        throw "FMC response did not include the '$Name' header."
    }
    $value
}

# --- Function: Connect to FMC (generate token) ---
function Connect-Fmc {
    param(
        [Parameter(Mandatory = $true)] [string]$Server,
        [Parameter(Mandatory = $true)] [System.Management.Automation.PSCredential]$Credential,
        [switch]$TrustAllCertificates
    )

    $pair   = "$($Credential.UserName):$($Credential.GetNetworkCredential().Password)"
    $encode = [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes($pair))

    # The token request carries no body - FMC only needs the Basic
    # Authorization header.
    $params = @{
        Uri     = "https://$Server/api/fmc_platform/v1/auth/generatetoken"
        Method  = "Post"
        Headers = @{ "Authorization" = "Basic $encode" }
    }
    if ($TrustAllCertificates) {
        $params["SkipCertificateCheck"] = $true
    }

    $response = Invoke-WebRequest @params

    [pscustomobject]@{
        Server               = $Server
        AccessToken          = Get-FmcHeaderValue -Headers $response.Headers -Name "X-auth-access-token"
        RefreshToken         = Get-FmcHeaderValue -Headers $response.Headers -Name "X-auth-refresh-token"
        DomainUuid           = Get-FmcHeaderValue -Headers $response.Headers -Name "DOMAIN_UUID"
        RefreshCount         = 0
        TrustAllCertificates = [bool]$TrustAllCertificates
    }
}

# --- Function: Refresh the FMC access token ---
function Update-FmcToken {
    param(
        [Parameter(Mandatory = $true)] [pscustomobject]$Session
    )

    if ($Session.RefreshCount -ge 3) {
        throw "The FMC access token has already been refreshed 3 times - reconnect with Connect-Fmc."
    }

    $params = @{
        Uri     = "https://$($Session.Server)/api/fmc_platform/v1/auth/refreshtoken"
        Method  = "Post"
        Headers = @{
            "X-auth-access-token"  = $Session.AccessToken
            "X-auth-refresh-token" = $Session.RefreshToken
        }
    }
    if ($Session.TrustAllCertificates) {
        $params["SkipCertificateCheck"] = $true
    }

    $response = Invoke-WebRequest @params

    $Session.AccessToken  = Get-FmcHeaderValue -Headers $response.Headers -Name "X-auth-access-token"
    $Session.RefreshToken = Get-FmcHeaderValue -Headers $response.Headers -Name "X-auth-refresh-token"
    $Session.RefreshCount++
}

# --- Function: Disconnect from FMC (revoke token) ---
function Disconnect-Fmc {
    param(
        [Parameter(Mandatory = $true)] [pscustomobject]$Session
    )

    $params = @{
        Uri     = "https://$($Session.Server)/api/fmc_platform/v1/auth/revokeaccess"
        Method  = "Post"
        Headers = @{ "X-auth-access-token" = $Session.AccessToken }
    }
    if ($Session.TrustAllCertificates) {
        $params["SkipCertificateCheck"] = $true
    }

    Invoke-WebRequest @params | Out-Null
}

# --- Function: Call the FMC config API ---
function Invoke-FmcApi {
    param(
        [Parameter(Mandatory = $true)] [pscustomobject]$Session,
        # Path under /api/fmc_config/v1/domain/{domainUUID}/, e.g.
        # "devices/devicerecords?expanded=true".
        [Parameter(Mandatory = $true)] [string]$Path,
        [ValidateSet("Get", "Post", "Put", "Delete")] [string]$Method = "Get",
        [hashtable]$Body,
        [int]$MaxRetries = 3
    )

    $uri = "https://$($Session.Server)/api/fmc_config/v1/domain/$($Session.DomainUuid)/$Path"

    for ($attempt = 1; ; $attempt++) {
        $params = @{
            Uri     = $uri
            Method  = $Method
            Headers = @{ "X-auth-access-token" = $Session.AccessToken }
        }
        if ($Body) {
            $params["Body"]        = $Body | ConvertTo-Json -Depth 10
            $params["ContentType"] = "application/json"
        }
        if ($Session.TrustAllCertificates) {
            $params["SkipCertificateCheck"] = $true
        }

        try {
            return Invoke-RestMethod @params
        }
        catch {
            $status = $null
            if ($_.Exception.Response) {
                $status = [int]$_.Exception.Response.StatusCode
            }

            if ($attempt -gt $MaxRetries) {
                throw
            }

            if ($status -eq 401) {
                # The 30 minute access token expired mid-run - refresh it and
                # repeat the request.
                Update-FmcToken -Session $Session
            }
            elseif ($status -eq 429) {
                # Over the 120 requests per minute limit - back off before
                # trying again.
                $delay = 20 * $attempt
                Write-Log "FMC rate limit reached, retrying in $delay seconds..." -Level WARN
                Start-Sleep -Seconds $delay
            }
            else {
                throw
            }
        }
    }
}

# --- Function: Get all device records from FMC (paginated) ---
function Get-FmcDeviceRecords {
    param(
        [Parameter(Mandatory = $true)] [pscustomobject]$Session
    )

    # FMC returns at most 1000 items per page, so keep asking for the next
    # page until every device has been read.
    $limit   = 1000
    $offset  = 0
    $results = @()

    do {
        $page = Invoke-FmcApi -Session $Session -Path "devices/devicerecords?expanded=true&offset=$offset&limit=$limit"

        foreach ($device in @($page.items)) {
            $results += [pscustomobject]@{
                Name         = $device.name
                # hostName is the management address the device was
                # registered with on FMC - an IP address or a DNS name.
                HostName     = $device.hostName
                Model        = $device.model
                Version      = $device.sw_version
                HealthStatus = $device.healthStatus
                Id           = $device.id
            }
        }

        $offset += $limit
    } while ($page.paging -and $offset -lt $page.paging.count)

    $results
}

# --- Function: Resolve a management address to an IPv4 address ---
function Resolve-ManagementAddress {
    <#
    .SYNOPSIS
        Turn the management address FMC reports into an IPv4 address
    .PARAMETER HostName
        The device's hostName from FMC - an IP address or a DNS name
    .OUTPUTS
        IPv4 address text, or $null when the name cannot be resolved
    #>
    param (
        [string]$HostName
    )

    if ([string]::IsNullOrWhiteSpace($HostName)) {
        return $null
    }

    $HostName = $HostName.Trim()
    $address  = $null
    if ([System.Net.IPAddress]::TryParse($HostName, [ref]$address)) {
        return $address.ToString()
    }

    try {
        $ipv4 = [System.Net.Dns]::GetHostAddresses($HostName) |
            Where-Object { $_.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork } |
            Select-Object -First 1
        if ($ipv4) {
            return $ipv4.ToString()
        }
    } catch {
        Write-Log "Could not resolve '$HostName': $($_.Exception.Message)" -Level WARN
    }

    return $null
}

# --- Function: End the FMC and SWIS sessions ---
function Stop-Sessions {
    <#
    .SYNOPSIS
        End the FMC and SWIS sessions opened by this script
    .DESCRIPTION
        FMC publishes a revocation endpoint (auth/revokeaccess), so the
        access token is revoked rather than left to expire after 30 minutes.

        SWIS has no Disconnect-Swis cmdlet, but Connect-Swis returns an
        InfoServiceProxy, which is IDisposable, so the connection can be
        closed explicitly instead of being left to the finalizer.

        Safe to call more than once - each session is ended only once.
    #>
    if ($script:fmcSession) {
        try {
            Disconnect-Fmc -Session $script:fmcSession
            Write-Log "Revoked the FMC API token." -Color Green
        } catch {
            Write-Log "Failed to revoke the FMC API token: $($_.Exception.Message)" -Level WARN
        }
        $script:fmcSession = $null
    }

    if ($script:swis) {
        try {
            $script:swis.Close()
            Write-Log "Closed the SWIS connection." -Color Green
        } catch {
            Write-Log "Failed to close the SWIS connection: $($_.Exception.Message)" -Level WARN
        }
        $script:swis = $null
    }
}

# --- Counters for the summary at the end of the run ---
$existingCount   = 0
$addedCount      = 0
$skippedCount    = 0
$failedCount     = 0
$interfaceTotal  = 0
$undpAssigned    = 0
$undpSupported   = 0
$undpUnsupported = 0

Write-Log "===== Run started: FMC $FmcServer -> SolarWinds $SwisHost ====="

# Call function "Connect-Fmc"
try {
    $fmcCredentials = Import-Clixml -Path $FmcCredentialPath
    $fmcSession     = Connect-Fmc -Server $FmcServer -Credential $fmcCredentials -TrustAllCertificates
} catch {
    Write-Log "Failed to authenticate with FMC: $($_.Exception.Message)" -Level ERROR
    Stop-Sessions
    exit
}

# Call function "Get-FmcDeviceRecords"
try {
    $results = Get-FmcDeviceRecords -Session $fmcSession
} catch {
    Write-Log "Failed to retrieve devices from FMC: $($_.Exception.Message)" -Level ERROR
    Stop-Sessions
    exit
}

# The device list is all that is needed from FMC, so revoke the token now
# instead of letting it run out (30 minutes) while the nodes are added.
Stop-Sessions

Write-Log "FMC returned $(@($results).Count) device[s]."

if (-not $results) {
    Write-Log "FMC returned no devices - nothing to process." -Level WARN
    exit
}

try {
    $swisCredentials = Import-Clixml -Path $SwisCredentialPath
    $swis = Connect-Swis -Hostname $SwisHost -Credential $swisCredentials
    Write-Log "Connected to SolarWinds Information Service (SWIS) on $SwisHost." -Color Green
} catch {
    Write-Log "Failed to connect to SWIS: $($_.Exception.Message)" -Level ERROR
    Stop-Sessions
    exit
}

# --- Load the UnDP definitions to assign ---
# Each name in -UnDPNames is looked up once; a name that does not exist, or
# that belongs to an interface UnDP, is logged and left out.
$undps = @()
foreach ($undpName in $UnDPNames) {
    $definition = @(Get-SwisData -SwisConnection $swis -Query "SELECT CustomPollerID, UniqueName, OID, NetObjectPrefix FROM Orion.NPM.CustomPollers WHERE UniqueName = @name" -Parameters @{ name = $undpName })[0]

    if (-not $definition) {
        Write-Log "UnDP '$undpName' was not found in SolarWinds - it will not be assigned." -Level WARN
        continue
    }
    if ($definition.NetObjectPrefix -ne 'N') {
        Write-Log "UnDP '$undpName' is an interface poller - only node UnDPs are assigned, skipping it." -Level WARN
        continue
    }

    Write-Log "UnDP '$($definition.UniqueName)' loaded (OID $($definition.OID))."
    $undps += $definition
}
if ($UnDPCheckOnly -and $undps) {
    Write-Log "UnDPCheckOnly is set - UnDP support is checked and logged, nothing is assigned."
}

# --- Build the list of components to process ---
# Build $components from the devices returned by FMC: the management address
# is resolved to an IPv4 address and the FMC device name is kept as the node
# caption. A device without a usable address is skipped with a warning.
$components = foreach ($device in $results) {
    $ip = Resolve-ManagementAddress -HostName $device.HostName

    if (-not $ip) {
        Write-Log "Skipping '$($device.Name)' - no usable management address ('$($device.HostName)')." -Level WARN
        $script:skippedCount++
        continue
    }

    @{
        IPAddress   = $ip
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
        Write-Log "  Added poller $pollerType to node $($nodeProps["NodeID"])."
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

    # Keep only TenGigabit and Port-channel interfaces that are operationally
    # up (ifOperStatus 1). Both the long captions and the abbreviated Cisco
    # forms are accepted; everything else is removed before the add.
    #
    # The node list is materialised with @() first: RemoveChild shrinks the
    # live XmlNodeList, and removing from it while the pipeline is still
    # enumerating it skips nodes.
    @($discovered.DiscoveredInterfaces.DiscoveredLiteInterface) | Where-Object {
        $_.Caption.InnerText -notmatch '^(TenGigabitEthernet|TenGigE|Te\d|Port-channel|Po\d)' -or
        $_.ifOperStatus -ne '1'
    } | ForEach-Object { $discovered.DiscoveredInterfaces.RemoveChild($_) | Out-Null }

    # Where-Object drops the $null left once every interface was removed -
    # @($null).Count is 1, which would report one interface and add none.
    $interfaceCount = @($discovered.DiscoveredInterfaces.DiscoveredLiteInterface | Where-Object { $_ }).Count

    if ($interfaceCount -eq 0) {
        Write-Log " No interfaces left to add for node $($nodeId) after filtering." -Color DarkBlue
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
            Write-Log " No new interfaces for node $($nodeId) - the $interfaceCount matching interface[s] were already monitored." -Color DarkBlue
            return
        }

        foreach ($interface in $added) {
            Write-Log "  Added interface $($interface.Caption) [InterfaceID $($interface.InterfaceID)] to node $nodeId." -Color Green
        }
        Write-Log " Added $($added.Count) interface[s] for node $($nodeId)." -Color Green
        $script:interfaceTotal += $added.Count
    } catch {
        Write-Log " Failed to add interfaces for node $($nodeId): $($_.Exception.Message)" -Level ERROR
    }
}

# --- Function: Encode a BER (SNMP) length ---
function ConvertTo-BerLength {
    param([int]$Length)

    if ($Length -lt 0x80) {
        return ,[byte[]]@($Length)
    }

    $bytes = [System.Collections.Generic.List[byte]]::new()
    while ($Length -gt 0) {
        $bytes.Insert(0, [byte]($Length -band 0xFF))
        $Length = $Length -shr 8
    }
    return ,[byte[]](@([byte](0x80 -bor $bytes.Count)) + $bytes.ToArray())
}

# --- Function: Encode a BER (SNMP) tag-length-value ---
function New-BerTlv {
    param([byte]$Tag, [byte[]]$Value = @())

    return ,[byte[]](@($Tag) + (ConvertTo-BerLength $Value.Length) + $Value)
}

# --- Function: Encode a BER (SNMP) INTEGER ---
function ConvertTo-BerInteger {
    param([int]$Value)

    $bytes = [System.BitConverter]::GetBytes($Value)
    [array]::Reverse($bytes)

    # Drop the leading bytes that only repeat the sign.
    $i = 0
    while ($i -lt 3 -and (($bytes[$i] -eq 0x00 -and $bytes[$i + 1] -lt 0x80) -or
                          ($bytes[$i] -eq 0xFF -and $bytes[$i + 1] -ge 0x80))) {
        $i++
    }
    return ,(New-BerTlv 0x02 ([byte[]]$bytes[$i..3]))
}

# --- Function: Encode a BER (SNMP) OBJECT IDENTIFIER ---
function ConvertTo-BerOid {
    param([string]$Oid)

    $arcs  = @($Oid.Trim('.').Split('.') | ForEach-Object { [uint64]$_ })
    $bytes = [System.Collections.Generic.List[byte]]::new()
    $bytes.Add([byte](40 * $arcs[0] + $arcs[1]))

    for ($a = 2; $a -lt $arcs.Count; $a++) {
        $arc   = $arcs[$a]
        $chunk = [System.Collections.Generic.List[byte]]::new()
        $chunk.Insert(0, [byte]($arc -band 0x7F))
        $arc = $arc -shr 7
        while ($arc -gt 0) {
            $chunk.Insert(0, [byte](0x80 -bor ($arc -band 0x7F)))
            $arc = $arc -shr 7
        }
        $bytes.AddRange($chunk)
    }
    return ,(New-BerTlv 0x06 $bytes.ToArray())
}

# --- Function: Read one BER (SNMP) tag-length-value ---
function Read-BerTlv {
    param([byte[]]$Data, [int]$Offset)

    $tag    = $Data[$Offset]
    $length = [int]$Data[$Offset + 1]
    $start  = $Offset + 2

    if ($length -band 0x80) {
        $count  = $length -band 0x7F
        $length = 0
        for ($k = 0; $k -lt $count; $k++) {
            $length = ($length -shl 8) -bor $Data[$start]
            $start++
        }
    }

    [pscustomobject]@{ Tag = $tag; Start = $start; Length = $length; Next = $start + $length }
}

# --- Function: Decode a BER (SNMP) INTEGER ---
function ConvertFrom-BerInteger {
    param([byte[]]$Data, [pscustomobject]$Tlv)

    [long]$value = if ($Data[$Tlv.Start] -ge 0x80) { -1 } else { 0 }
    for ($i = $Tlv.Start; $i -lt $Tlv.Next; $i++) {
        $value = ($value -shl 8) -bor $Data[$i]
    }
    $value
}

# --- Function: Decode a BER (SNMP) OBJECT IDENTIFIER ---
function ConvertFrom-BerOid {
    param([byte[]]$Data, [pscustomobject]$Tlv)

    $first = $Data[$Tlv.Start]
    $arcs  = [System.Collections.Generic.List[uint64]]::new()
    $arcs.Add([uint64][math]::Floor($first / 40))
    $arcs.Add([uint64]($first % 40))

    $value = [uint64]0
    for ($i = $Tlv.Start + 1; $i -lt $Tlv.Next; $i++) {
        $value = ($value -shl 7) -bor ($Data[$i] -band 0x7F)
        if (-not ($Data[$i] -band 0x80)) {
            $arcs.Add($value)
            $value = [uint64]0
        }
    }
    $arcs -join '.'
}

# --- Function: Send one SNMP v2c GETNEXT request ---
function Invoke-SnmpGetNext {
    <#
    .SYNOPSIS
        Ask a device for the object that follows an OID (SNMP v2c GETNEXT)
    .DESCRIPTION
        Built on a plain UDP socket so the script needs no SNMP module or
        DLL. The request is sent from the host running the script - normally
        the SolarWinds server, which already polls the devices over SNMP.
    .OUTPUTS
        ErrorStatus, Oid and ValueTag of the answer, or $null when the device
        did not answer
    #>
    param(
        [string]$IPAddress,
        [string]$Community,
        [string]$Oid,
        [int]$Port = 161,
        [int]$TimeoutMs = 2000,
        [int]$Retries = 1
    )

    $requestId = Get-Random -Minimum 1 -Maximum 2147483647
    $varbind   = New-BerTlv 0x30 ([byte[]]((ConvertTo-BerOid $Oid) + (New-BerTlv 0x05)))
    $pdu       = New-BerTlv 0xA1 ([byte[]]((ConvertTo-BerInteger $requestId) + (ConvertTo-BerInteger 0) + (ConvertTo-BerInteger 0) + (New-BerTlv 0x30 $varbind)))
    $message   = New-BerTlv 0x30 ([byte[]]((ConvertTo-BerInteger 1) + (New-BerTlv 0x04 ([System.Text.Encoding]::ASCII.GetBytes($Community))) + $pdu))

    $udp = [System.Net.Sockets.UdpClient]::new()
    try {
        $udp.Client.ReceiveTimeout = $TimeoutMs
        $udp.Connect($IPAddress, $Port)

        for ($attempt = 0; $attempt -le $Retries; $attempt++) {
            [void]$udp.Send($message, $message.Length)

            try {
                $remote   = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0)
                $response = $udp.Receive([ref]$remote)
            } catch [System.Net.Sockets.SocketException] {
                continue   # timed out - try again
            }

            # Message: version, community, Response-PDU (request-id,
            # error-status, error-index, varbind list).
            $msgTlv       = Read-BerTlv $response 0
            $versionTlv   = Read-BerTlv $response $msgTlv.Start
            $communityTlv = Read-BerTlv $response $versionTlv.Next
            $pduTlv       = Read-BerTlv $response $communityTlv.Next
            $ridTlv       = Read-BerTlv $response $pduTlv.Start
            $errTlv       = Read-BerTlv $response $ridTlv.Next
            $idxTlv       = Read-BerTlv $response $errTlv.Next
            $vblTlv       = Read-BerTlv $response $idxTlv.Next
            $vbTlv        = Read-BerTlv $response $vblTlv.Start
            $oidTlv       = Read-BerTlv $response $vbTlv.Start
            $valueTlv     = Read-BerTlv $response $oidTlv.Next

            if ((ConvertFrom-BerInteger $response $ridTlv) -ne $requestId) {
                continue   # an answer to an older request
            }

            return [pscustomobject]@{
                ErrorStatus = ConvertFrom-BerInteger $response $errTlv
                Oid         = ConvertFrom-BerOid $response $oidTlv
                ValueTag    = $valueTlv.Tag
            }
        }
    } finally {
        $udp.Dispose()
    }

    $null
}

# --- Function: Check whether a device supports a UnDP ---
function Test-UnDPSupport {
    <#
    .SYNOPSIS
        Check that a device answers the OID a UnDP polls
    .DESCRIPTION
        A GETNEXT on the UnDP's OID returns the first object under it - the
        .0 instance of a scalar or the first row of a table column. The
        device supports the UnDP when that object is inside the OID; an
        object outside it, or noSuchObject / noSuchInstance / endOfMibView,
        means the device does not have it.
    .OUTPUTS
        Supported ($true/$false) and the Reason when it is not supported
    #>
    param(
        [string]$IPAddress,
        [string]$Community,
        [string]$Oid
    )

    $base   = $Oid.Trim('.')
    $answer = Invoke-SnmpGetNext -IPAddress $IPAddress -Community $Community -Oid $base

    $reason = if (-not $answer) {
        "no SNMP answer - check the community and that SNMP is enabled"
    } elseif ($answer.ErrorStatus -ne 0) {
        "SNMP error-status $($answer.ErrorStatus)"
    } elseif ($answer.ValueTag -in 0x80, 0x81, 0x82) {
        "the device does not have OID $base"
    } elseif ($answer.Oid -ne $base -and -not $answer.Oid.StartsWith("$base.")) {
        "the device does not have OID $base"
    }

    [pscustomobject]@{ Supported = -not $reason; Reason = $reason }
}

# --- Function: Assign the UnDPs a node supports ---
function Add-UnDPPollers {
    param($nodeId, $component)

    if (-not $script:undps) {
        return
    }

    # Test with the SNMP settings the node has in SolarWinds, so an existing
    # node with its own community is tested the way Orion polls it.
    $node = @(Get-SwisData -SwisConnection $swis -Query "SELECT SNMPVersion, Community FROM Orion.Nodes WHERE NodeID = @nodeId" -Parameters @{ nodeId = $nodeId })[0]

    if ($node -and $node.SNMPVersion -eq 3) {
        Write-Log " Node $nodeId polls with SNMPv3 - the UnDP check supports v2c only, no UnDP assigned." -Level WARN
        return
    }

    $community = if ($node -and $node.Community) { $node.Community } else { $component.Community }

    $assigned = @(Get-SwisData -SwisConnection $swis -Query "SELECT CustomPollerID FROM Orion.NPM.CustomPollerAssignmentOnNode WHERE NodeID = @nodeId" -Parameters @{ nodeId = $nodeId } |
        ForEach-Object { "$_" })

    foreach ($undp in $script:undps) {
        if ($assigned -contains "$($undp.CustomPollerID)") {
            Write-Log "  UnDP $($undp.UniqueName) is already assigned to node $nodeId." -Color DarkBlue
            continue
        }

        try {
            $test = Test-UnDPSupport -IPAddress $component.IPAddress -Community $community -Oid $undp.OID

            if (-not $test.Supported) {
                Write-Log "  UnDP $($undp.UniqueName) not supported on node $nodeId ($($test.Reason)) - not assigned." -Color DarkYellow
                $script:undpUnsupported++
                continue
            }

            if ($script:UnDPCheckOnly) {
                Write-Log "  UnDP $($undp.UniqueName) supported on node $nodeId (check only - not assigned)." -Color Green
                $script:undpSupported++
                continue
            }

            New-SwisObject -SwisConnection $swis -EntityType "Orion.NPM.CustomPollerAssignmentOnNode" -Properties @{
                NodeID         = $nodeId
                CustomPollerID = $undp.CustomPollerID
            } | Out-Null
            Write-Log "  Assigned UnDP $($undp.UniqueName) to node $nodeId." -Color Green
            $script:undpAssigned++
        } catch {
            Write-Log "  Failed to assign UnDP $($undp.UniqueName) to node $($nodeId): $($_.Exception.Message)" -Level ERROR
        }
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
            Write-Log " Node already exists: $($component.Caption) ($($component.IPAddress)) [NodeID $nodeId], skipping add." -Color DarkBlue
            $existingCount++
        }
        else {
            $nodeId = Add-Component $component
            Write-Log " Added node: $($component.Caption) ($($component.IPAddress)) [NodeID $nodeId]." -Color Green
            $addedCount++
        }

        # Discover and add interfaces for the node (whether new or existing)
        Add-DiscoveredInterfaces $nodeId

        # Assign the UnDPs the node supports (whether new or existing)
        Add-UnDPPollers $nodeId $component

    } catch {
        Write-Log " Failed to process $($component.Caption) ($($component.IPAddress)): $($_.Exception.Message)" -Level ERROR
        $failedCount++
    }
}

# --- End the FMC and SWIS sessions ---
Stop-Sessions

if ($undps) {
    Write-Log "UnDP: $undpAssigned assigned, $undpSupported supported (check only), $undpUnsupported not supported."
}
Write-Log "===== Run completed: $addedCount node[s] added, $existingCount already existed, $skippedCount skipped, $failedCount failed, $interfaceTotal interface[s] added ====="
