<#
.SYNOPSIS
    SolarWinds SWIS PowerShell script - discover Check Point gateways and
    cluster members via the SmartConsole (Management) API, add them as
    SolarWinds nodes, and discover their interfaces

.DESCRIPTION
    This script unifies the building blocks that were previously split across
    separate files into one self-contained script, based on
    "Discover Nodes And Interfaces From SmartConsole.ps1":

    o Check Point SmartConsole (Management API)
        - authenticates against web_api/login and pages through both
          show-cluster-members and show-simple-gateways, so the node list
          covers ClusterXL cluster members as well as standalone gateways.

    o CRUD.AddNode.ps1
        - adds a node <component> using CRUD operations (New-SwisObject) and
          registers the standard set of pollers for it.

    o NPM.DiscoverAndAddInterfacesOnNode.ps1
        - uses Orion.NPM.Interfaces.DiscoverInterfacesOnNode and
          Orion.NPM.Interfaces.AddInterfacesOnNode (SWISv3 verbs, NPM only)
          to discover and add the interfaces of a node, filtering out
          loopback/bond/VLAN sub-interfaces and interfaces that are down.

    o The logging (Invoke-LogRotation, Write-Log) is carried over unchanged
      from FMC.DiscoverNodes.ps1, so every script in this repository that
      talks to a management API logs to console and file the same way.

    The result is a single script that logs into SmartConsole, discovers
    every cluster member and simple gateway, adds every one of them that
    does not already exist in SolarWinds as a monitored node, and then
    discovers and adds their interfaces.

    Please update the parameter defaults below to match your environment
    before running.

.PARAMETER CpServer
    Address of the Check Point Security Management Server (IP or DNS name).

.PARAMETER CpPort
    HTTPS port the Management API listens on.

.PARAMETER CpCredentialPath
    Path to a PSCredential exported with Export-Clixml for a SmartConsole
    user with API access. Create it once, as the account that runs the
    script:
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
    SNMP community configured on the gateways/cluster members. Without it
    the Details/Uptime pollers have nothing to poll.

.PARAMETER LogPath
    The log file. Every run appends to it: each gateway/cluster member that
    already existed or was added, every poller type registered on a new
    node, every interface added, and a summary line at the end of the run.

.PARAMETER LogMaxBytes
    The size at which the log is rotated. Rotation keeps LogKeep older
    generations beside it, so the space the logging can occupy is bounded at
    roughly LogMaxBytes times LogKeep plus one.

.PARAMETER LogKeep
    How many rotated logs to keep. Zero keeps none: the log starts over
    instead.

.EXAMPLE
    .\SmartConsole.DiscoverNodesAndInterfaces.ps1

    Runs with the defaults set in the param block.

.EXAMPLE
    .\SmartConsole.DiscoverNodesAndInterfaces.ps1 -CpServer smartcenter.example.com -SwisHost orion.example.com -SNMPCommunity "mycommunity"

.NOTES
    Requires PowerShell 7+ for the -SkipCertificateCheck switch on
    Invoke-WebRequest, and the SwisPowerShell module for Connect-Swis.
#>

param(
    # --- Check Point SmartConsole connection ---
    [string]$CpServer = "1.1.1.1",
    [int]$CpPort = 443,
    [string]$CpCredentialPath = "D:\SolarWindsScripts\PowerShell\Credentials\SmartConsole_Credential.xml",

    # --- SolarWinds connection ---
    [string]$SwisHost = "5.5.5.5",
    [string]$SwisCredentialPath = "D:\SolarWindsScripts\PowerShell\Credentials\SolarWindsCredentials.xml",

    # Shared settings applied to every gateway/cluster member added as a node.
    [int]$EngineID = 2,
    [int]$SNMPVersion = 2,
    [string]$SNMPCommunity = '',

    # --- Log ---
    [string]$LogPath = (Join-Path -Path $env:ProgramData -ChildPath 'SolarWinds\smartconsole-discover-nodes.log'),

    [ValidateRange(4KB, 100MB)]
    [int]$LogMaxBytes = 1MB,

    [ValidateRange(0, 20)]
    [int]$LogKeep = 3
)

# =============================================================================
# The two functions below (Invoke-LogRotation, Write-Log) are copied unchanged
# from FMC.DiscoverNodes.ps1, so logging behaves identically across every
# script in this repository that talks to a management API.
# =============================================================================

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

# =============================================================================
# Check Point SmartConsole (Management API)
# =============================================================================

# --- Function: Get all addresses from a SmartConsole endpoint (paginated) ---
function Get-SmartConsoleAddresses {
    param(
        [string]$Url,
        [string]$IpField,
        [hashtable]$Header
    )

    # Also captures 'name', alongside the caller's chosen IP field
    # (ip-address for cluster members, ipv4-address for simple gateways), so
    # the node can be added with a real caption instead of a blank one.
    $results = @()
    $offset   = 0
    $pageSize = 500

    do {
        $body = @{
            "limit"         = $pageSize
            "offset"        = $offset
            "details-level" = "full"
        } | ConvertTo-Json

        $response     = Invoke-WebRequest -Uri $Url -Headers $Header -Body $body -Method Post -SkipCertificateCheck
        $responseJson = $response.Content | ConvertFrom-Json

        foreach ($object in $responseJson.objects) {
            $results += [pscustomobject]@{
                Name      = $object.name
                IPAddress = $object.$IpField
            }
        }

        $offset += $pageSize
    } while ($offset -lt $responseJson.total)

    return $results
}

# --- Function: Log out of SmartConsole ---
function Disconnect-SmartConsole {
    param(
        [hashtable]$Header
    )

    Invoke-WebRequest -Uri "https://${script:CpServer}:${script:CpPort}/web_api/logout" -Headers $Header -Body (@{} | ConvertTo-Json) -Method Post -SkipCertificateCheck | Out-Null
}

# =============================================================================
# SolarWinds (SWIS)
# =============================================================================

# --- Function: Add a Node [Component] ---
function Add-Component {
    param($component)

    $newNodeProps = @{
        IPAddress     = $component.IPAddress
        Caption       = $component.Name
        EngineID      = $component.EngineID
        # SNMP v2 specific
        ObjectSubType = "SNMP"
        SNMPVersion   = $component.SNMPVersion
        DNS           = $component.DNS
        SysName       = $component.SysName
        Community     = $component.Community
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

    $discovered.DiscoveredInterfaces.DiscoveredLiteInterface | Where-Object {
        $_.Caption.InnerText -match 'bond\d+\.\d+' -or
        $_.Caption.InnerText -match '\blo\b' -or
        $_.Caption.InnerText -match '\bpimreg\b' -or
        $_.Caption.InnerText -match 'eth\d+\.\d+' -or
        $_.Caption.InnerText -match 'eth\d+-\d+\.\d+' -or
        $_.ifOperStatus -match '2'
    } | ForEach-Object { $discovered.DiscoveredInterfaces.RemoveChild($_) } | Out-Null

    $interfaceCount = $discovered.DiscoveredInterfaces.DiscoveredLiteInterface.Count

    # Add the remaining interfaces
    try {
        Invoke-SwisVerb $swis Orion.NPM.Interfaces AddInterfacesOnNode @($nodeId, $discovered.DiscoveredInterfaces, "AddDefaultPollers") | Out-Null
        Write-Log " Added $interfaceCount interface[s] for node $($nodeId)." -Color Green
        $script:interfaceTotal += $interfaceCount
    } catch {
        Write-Log " Failed to add interfaces for node $($nodeId): $($_.Exception.Message)" -Level ERROR
    }
}

# =============================================================================
# Main
# =============================================================================

# --- Counters for the summary at the end of the run ---
$existingCount  = 0
$addedCount     = 0
$failedCount    = 0
$interfaceTotal = 0

Write-Log "===== Run started: SmartConsole $CpServer -> SolarWinds $SwisHost ====="

# --- Connect to SmartConsole (login) ---
try {
    $cpCredentials = Import-Clixml -Path $CpCredentialPath
    $loginBody = @{
        user     = $cpCredentials.UserName
        password = $cpCredentials.GetNetworkCredential().Password
    } | ConvertTo-Json

    $response     = Invoke-WebRequest -Uri "https://${CpServer}:${CpPort}/web_api/login" -Headers @{ "Content-Type" = "application/json" } -Body $loginBody -Method Post -SkipCertificateCheck
    $responseJson = $response.Content | ConvertFrom-Json
    $sid          = $responseJson.sid

    if (-not $sid) {
        throw "SmartConsole login did not return a session id (sid). Check credentials."
    }

    $header = @{
        "Content-Type" = "application/json"
        "x-chkp-sid"   = $sid
    }
} catch {
    Write-Log "Failed to authenticate with Check Point SmartConsole: $($_.Exception.Message)" -Level ERROR
    exit
}

# --- Get all gateways and cluster members from SmartConsole (handles pagination) ---
try {
    $clusterMembers = Get-SmartConsoleAddresses -Url "https://${CpServer}:${CpPort}/web_api/show-cluster-members" -IpField 'ip-address'   -Header $header
    $simpleGateways = Get-SmartConsoleAddresses -Url "https://${CpServer}:${CpPort}/web_api/show-simple-gateways"  -IpField 'ipv4-address' -Header $header
} catch {
    Write-Log "Failed to retrieve gateways from SmartConsole: $($_.Exception.Message)" -Level ERROR
    Disconnect-SmartConsole -Header $header
    exit
}

# The gateway/cluster member list is all that is needed from SmartConsole, so
# log out now instead of leaving the session open while the nodes are added.
try {
    Disconnect-SmartConsole -Header $header
    Write-Log "Logged out of Check Point SmartConsole." -Color Green
} catch {
    Write-Log "Failed to log out of Check Point SmartConsole: $($_.Exception.Message)" -Level WARN
}

$allAddresses = @($clusterMembers) + @($simpleGateways)
Write-Log "SmartConsole returned $($allAddresses.Count) gateway/cluster member address(es)."

# --- Build the list of components to process ---
$components = $allAddresses |
    Where-Object { $_.IPAddress } |
    Select-Object -Unique -Property Name, IPAddress |
    ForEach-Object {
        @{
            Name        = $_.Name
            IPAddress   = $_.IPAddress
            EngineID    = $EngineID
            SNMPVersion = $SNMPVersion
            DNS         = ""
            SysName     = ""
            Community   = $SNMPCommunity
        }
    }

if (-not $components) {
    Write-Log "SmartConsole returned no usable addresses - nothing to process." -Level WARN
    exit
}

try {
    $swisCredentials = Import-Clixml -Path $SwisCredentialPath
    $swis = Connect-Swis -Hostname $SwisHost -Credential $swisCredentials
    Write-Log "Connected to SolarWinds Information Service (SWIS) on $SwisHost." -Color Green
} catch {
    Write-Log "Failed to connect to SWIS: $($_.Exception.Message)" -Level ERROR
    exit
}

# --- Main Loop: Process each component ---
foreach ($component in $components) {
    Write-Log "Processing component $($component.Name) ($($component.IPAddress))..."

    try {
        # Check if node already exists
        $existing = Get-SwisData -SwisConnection $swis -Query "SELECT NodeID FROM Orion.Nodes WHERE IPAddress = @ip" -Parameters @{ ip = $component.IPAddress }

        if ($existing) {
            $nodeId = @($existing)[0]
            Write-Log " Node already exists: $($component.Name) ($($component.IPAddress)) [NodeID $nodeId], skipping add." -Color DarkBlue
            $existingCount++
        }
        else {
            $nodeId = Add-Component $component
            Write-Log " Added node: $($component.Name) ($($component.IPAddress)) [NodeID $nodeId]." -Color Green
            $addedCount++
        }

        # Discover and add interfaces for the node (whether new or existing)
        Add-DiscoveredInterfaces $nodeId

    } catch {
        Write-Log " Failed to process $($component.Name) ($($component.IPAddress)): $($_.Exception.Message)" -Level ERROR
        $failedCount++
    }
}

# --- Close the SWIS connection ---
try {
    $swis.Close()
    Write-Log "Closed the SWIS connection." -Color Green
} catch {
    Write-Log "Failed to close the SWIS connection: $($_.Exception.Message)" -Level WARN
}

Write-Log "===== Run completed: $addedCount node(s) added, $existingCount already existed, $failedCount failed, $interfaceTotal interface(s) added ====="
