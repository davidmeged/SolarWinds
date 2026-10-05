<#
.SYNOPSIS
    SolarWinds SWIS PowerShell script  add multiple components (nodes) and discover their interfaces

.DESCRIPTION
    This script combines two building blocks from the SolarWinds SDK samples:

    o CRUD.AddNode.ps1
        - adds a node <component> using CRUD operations (New-SwisObject) and
          registers the standard set of pollers for it.
    o NPM.DiscoverAndAddInterfacesOnNode.ps1
        - uses Orion.NPM.Interfaces.DiscoverInterfacesOnNode and
          Orion.NPM.Interfaces.AddInterfacesOnNode (SWISv3 verbs, NPM only)
          to discover and add the interfaces of a node.

    The result is a single script that walks a list of components [nodes],
    adds every one of them that does not already exist, and then discovers
    and adds their interfaces for monitoring.

    Please update the hostname/credential setup below to match your
    environment before running.

    The list of components (nodes) is retrieved automatically from the
    Cisco DNA Center inventory: every device the DNA API reports is added
    by its management IP address.

    Every run writes a timestamped log file under -LogDirectory recording
    each component that was added or already existed, every interface that
    was added, and every poller that was registered. Log files older than
    -LogRetentionDays are deleted at the start of each run.
#>

param(
    # Shared settings applied to every device retrieved from DNA.
    [int]$EngineID = 2,
    [int]$SNMPVersion = 2,
    [string]$SNMPCommunity = '',

    # Where each run's log is written, and how long older logs are kept.
    # A retention of 0 or less keeps every log file.
    [string]$LogDirectory = (Join-Path -Path $env:ProgramData -ChildPath 'SolarWinds\DNA.DiscoverNodesAndInterfaces'),

    [ValidateRange(0, 3650)]
    [int]$LogRetentionDays = 30
)

# --- Logging ---
# Mirrors the Write-Log convention of DNS.SetSolarWindsRecordToActiveServer.ps1
# (same level set, same line format, same UTF8 Add-Content), but keeps a file
# per run and prunes by age, because this script is the kind of scheduled job
# whose per-run record is what you go back to read.
$script:logFile = $null
$script:stats   = [ordered]@{
    ComponentsAdded    = 0
    ComponentsExisting = 0
    ComponentsFailed   = 0
    InterfacesAdded    = 0
    PollersAdded       = 0
}

function Write-Log {
    <#
    .SYNOPSIS
        Record one line in the run log, and on the console unless suppressed
    .PARAMETER Message
        The text to record.
    .PARAMETER Level
        INFO, WARN or ERROR. The level also picks the console stream, so
        warnings and errors still reach the host's warning and error streams.
    .PARAMETER ForegroundColor
        Console colour for an INFO line; ignored for the other levels.
    .PARAMETER NoConsole
        Write to the log file only. Used for the per-item detail lines - every
        component, interface and poller - which belong in the record but would
        bury the console summary.
    #>
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Message,

        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string] $Level = 'INFO',

        [string] $ForegroundColor,

        [switch] $NoConsole
    )

    if (-not $NoConsole) {
        switch ($Level) {
            'WARN'  { Write-Warning $Message }
            'ERROR' { Write-Error   $Message }
            default {
                if ($ForegroundColor) { Write-Host $Message -ForegroundColor $ForegroundColor }
                else                  { Write-Host $Message }
            }
        }
    }

    if (-not $script:logFile) { return }

    $line = '{0:yyyy-MM-dd HH:mm:ss} [{1,-5}] {2}' -f (Get-Date), $Level, $Message
    try {
        Add-Content -LiteralPath $script:logFile -Value $line -Encoding UTF8
    } catch {
        # A logging failure must not take the run down, and must not recurse
        # back into Write-Log. Drop the path so this warns once, not per line.
        Write-Warning "Could not write to the log file '$script:logFile': $($_.Exception.Message)"
        $script:logFile = $null
    }
}

function Initialize-Log {
    <#
    .SYNOPSIS
        Create the log directory and open this run's log file
    #>
    param(
        [Parameter(Mandatory)][string] $Directory
    )

    if (-not (Test-Path -LiteralPath $Directory)) {
        New-Item -Path $Directory -ItemType Directory -Force | Out-Null
    }

    $name = 'DNA.DiscoverNodesAndInterfaces_{0:yyyyMMdd_HHmmss}.log' -f (Get-Date)
    $script:logFile = Join-Path -Path $Directory -ChildPath $name

    Write-Host "Logging to $($script:logFile)." -ForegroundColor Green
    Write-Log "=== Run started ===" -NoConsole
}

function Remove-OldLog {
    <#
    .SYNOPSIS
        Delete this script's own log files older than the retention period
    .DESCRIPTION
        Only files matching this script's own log name pattern are considered,
        so nothing else that happens to sit in the log directory is touched,
        and the current run's file is excluded by name as well as by age. A
        retention of 0 or less disables the purge and keeps every log.
    #>
    param(
        [Parameter(Mandatory)][string] $Directory,
        [Parameter(Mandatory)][int]    $Days
    )

    if ($Days -le 0) {
        Write-Log "Log retention disabled (LogRetentionDays = $Days); keeping every log file." -NoConsole
        return
    }

    $cutoff  = (Get-Date).AddDays(-$Days)
    $current = Split-Path -Path $script:logFile -Leaf

    try {
        $old = @(Get-ChildItem -LiteralPath $Directory -Filter 'DNA.DiscoverNodesAndInterfaces_*.log' -File -ErrorAction Stop |
            Where-Object { $_.LastWriteTime -lt $cutoff -and $_.Name -ne $current })
    } catch {
        Write-Log "Could not list the log directory '$Directory': $($_.Exception.Message)" -Level WARN
        return
    }

    $deleted = 0
    foreach ($file in $old) {
        try {
            Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop
            Write-Log "Deleted old log: $($file.Name) (last written $($file.LastWriteTime.ToString('yyyy-MM-dd')))" -NoConsole
            $deleted++
        } catch {
            Write-Log "Could not delete old log '$($file.Name)': $($_.Exception.Message)" -Level WARN
        }
    }

    if ($deleted) {
        Write-Log "Deleted $deleted log file[s] older than $Days day[s]." -ForegroundColor Green
    }
}

Initialize-Log -Directory $LogDirectory
Remove-OldLog  -Directory $LogDirectory -Days $LogRetentionDays

# --- Connect to SWIS ---
$hostname = ""
$username = ""
$password = Import-Clixml -Path ".\Credentials\SolarWindsCredential.xml"

# --- Connect to DNA ---
$dnaServer = ""
$dnaUrlToken = "https://$($dnaServer)/dna/system/api/v1/auth/token"
$dnaUrlDevices = "https://$($dnaServer)/dna/intent/api/v1/network-devices"
$dnaCredentials = Import-Clixml -Path ""

function Get-TokenDNA {
    <#
    .SYNOPSIS
        Authenticate with DNA server and get Token
    .PARAMETER uri
        Url for get Token
    .PARAMETER user
        Username with permission access with API
    .PARAMETER pass
        Password of username
    .OUTPUTS
        Token text
    #>
    param (
        $uri,
        $user,
        $pass
    )
    $pair = "${user}:${pass}"
    $encode = [System.Convert]::ToBase64String([text.encoding]::ASCII.GetBytes($pair))
    $header = @{
        "Content-Type" = "application/json"
        "Authorization" = "Basic $encode "
    }
    $response = Invoke-WebRequest -Uri $uri -Headers $header -Method Post -SkipCertificateCheck
    return $response.Content | ConvertFrom-Json
}

function Get-DNADevices {
    <#
    .SYNOPSIS
        Get information from devices that exist in DNA
    .PARAMETER token
        Get token for authenticate with DNA
    .PARAMETER url
        Url to get infotmation about devices
    .OUTPUTS
        Device general information
    #>
    param (
        $token,
        $url
    )
    $header = @{
        "Content-Type" = "application/json"
        "x-auth-token" = $token
    }

    # The DNA inventory is returned one page at a time, so keep asking for
    # the next page until one comes back shorter than the page size.
    $devices  = @()
    $pageSize = 500
    $offset   = 1   # the DNA device inventory is 1-based

    do {
        $pageUri  = "$($url)?offset=$($offset)&limit=$($pageSize)"
        $response = Invoke-WebRequest -Uri $pageUri -Headers $header -Method Get -SkipCertificateCheck
        $page     = @(($response.Content | ConvertFrom-Json).response)

        $devices += $page
        $offset  += $pageSize
    } while ($page.Count -eq $pageSize)

    return $devices
}

function Stop-Sessions {
    <#
    .SYNOPSIS
        End the DNA and SWIS sessions opened by this script
    .DESCRIPTION
        Cisco DNA Center publishes no token revocation endpoint - the token
        is only valid for an hour and then expires on its own - so dropping
        it from memory is the whole of the cleanup available on that side.

        SWIS has no Disconnect-Swis cmdlet either, but Connect-Swis returns
        an InfoServiceProxy, which is IDisposable, so the connection can be
        closed explicitly instead of being left to the finalizer.
    #>
    if ($script:tokenString) {
        $script:tokenObj    = $null
        $script:tokenString = $null
        Write-Log "Discarded the DNA API token." -ForegroundColor Green
    }

    if ($script:swis) {
        try {
            $script:swis.Close()
            Write-Log "Closed the SWIS connection." -ForegroundColor Green
        } catch {
            Write-Log "Failed to close the SWIS connection: $($_.Exception.Message)" -Level WARN
        }
        $script:swis = $null
    }
}

# Call function "Get-TokenDNA"
try {
    $tokenObj = Get-TokenDNA -uri $dnaUrlToken -user $dnaCredentials.UserName -pass $dnaCredentials.GetNetworkCredential().password

    # Get Token from results function
    $tokenString = $tokenObj.Token

    if (-not $tokenString) {
        Write-Log "DNA authentication did not return a token. Check URL/credentials." -Level ERROR
        Stop-Sessions
        exit
    }
} catch {
    Write-Log "Failed to authenticate with DNA: $($_.Exception.Message)" -Level ERROR
    Stop-Sessions
    exit
}

# Call function "Get-DNADevices"
try {
    $results = Get-DNADevices -token $tokenString -url $dnaUrlDevices
} catch {
    Write-Log "Failed to retrieve devices from DNA: $($_.Exception.Message)" -Level ERROR
    Stop-Sessions
    exit
}

# Get ip address of devices from results function
$addresses = @($results.managementIpAddress)

Write-Log "DNA returned $(@($results).Count) device[s], $($addresses.Count) with a management IP address."


if (-not $addresses) {
    Write-Log "DNA returned no devices - nothing to process." -Level WARN
    Stop-Sessions
    exit
}

try {
    $swis = Connect-Swis -Host $hostname -UserName $username -Password $password.GetNetworkCredential().Password
    Write-Log "Connected to SolarWinds Information Service (SWIS)." -ForegroundColor Green
} catch {
    Write-Log "Failed to connect to SWIS: $($_.Exception.Message)" -Level ERROR
    Stop-Sessions
    exit
}

# --- Build the list of components to process ---
if ($addresses) {
    # Build $components from the management IP addresses returned by DNA.
    # Each entry is normally a single address, but a comma-separated value is
    # split as well so the list can also be supplied by hand.
    $components = $addresses |
        Where-Object { $_ } |
        ForEach-Object { $_.Split(',') } |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ } |
        ForEach-Object {
            @{
                IPAddress   = $_
                EngineID    = $EngineID
                SNMPVersion = $SNMPVersion
                DNS         = ""
                SysName     = ""
                Community   = $SNMPCommunity
            }
        }
}

# --- Function: Add a Node [Component] ---
function Add-Component {
    param($component)

    $newNodeProps = @{
        IPAddress       = $component.IPAddress
        EngineID        = $component.EngineID
        # SNMP v2 specific
        ObjectSubType   = "SNMP"
        SNMPVersion     = $component.SNMPVersion
        DNS             = $component.DNS
        SysName         = $component.SysName
        Community       = $component.Community
        # === default values ===
        # EntityType    = 'Orion.Nodes'
        # Caption       = ''
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

    # Where-Object drops the null that an emptied node list yields: @($null)
    # has a Count of 1, so without it a run that filtered every interface away
    # would report one interface and still call the add verb with nothing.
    $keptInterfaces = @($discovered.DiscoveredInterfaces.DiscoveredLiteInterface | Where-Object { $_ })
    $interfaceCount = $keptInterfaces.Count

    if ($interfaceCount -eq 0) {
        Write-Log " No interfaces left to add for node $($nodeId) after filtering." -ForegroundColor DarkBlue
        return
    }

    # Collect the captions before the add, so the log can name each interface
    # rather than only count them.
    $captions = @($keptInterfaces | ForEach-Object { $_.Caption.InnerText })

    # Add the remaining interfaces
    try {
        Invoke-SwisVerb $swis Orion.NPM.Interfaces AddInterfacesOnNode @($nodeId, $discovered.DiscoveredInterfaces, "AddDefaultPollers") | Out-Null
        Write-Log " Added $interfaceCount interface[s] for node $($nodeId)." -ForegroundColor Green
        foreach ($caption in $captions) {
            Write-Log "  interface added | NodeID=$nodeId | caption=$caption" -NoConsole
        }
        $script:stats.InterfacesAdded += $interfaceCount
    } catch {
        Write-Log " Failed to add interfaces for node $($nodeId): $($_.Exception.Message)" -Level ERROR
    }
}

# --- Main Loop: Process each component ---
foreach ($component in $components) {
    Write-Log "Processing component $($component.IPAddress)..."

    try {
        # Check if node already exists
        $existing = Get-SwisData -SwisConnection $swis -Query "SELECT NodeID FROM Orion.Nodes WHERE IPAddress = '$($component.IPAddress)'"

        if ($existing) {
            $nodeId = $existing # Note: Get-SwisData returns an array of objects, access the property
            Write-Log " Node already exists {NodeID $nodeId}, skipping add." -ForegroundColor DarkBlue
            Write-Log "  component       | IP=$($component.IPAddress) | status=exists | NodeID=$nodeId" -NoConsole
            $script:stats.ComponentsExisting++
        }
        else {
            $nodeId = Add-Component $component
            Write-Log " Added node [NodeID $nodeId]."
            Write-Log "  component       | IP=$($component.IPAddress) | status=added | NodeID=$nodeId" -NoConsole
            $script:stats.ComponentsAdded++
        }

        # Discover and add interfaces for the node (whether new or existing)
        Add-DiscoveredInterfaces $nodeId

    } catch {
        Write-Log " Failed to process $($component.IPAddress): $($_.Exception.Message)" -Level ERROR
        Write-Log "  component       | IP=$($component.IPAddress) | status=failed" -NoConsole
        $script:stats.ComponentsFailed++
    }
}

# --- End the DNA and SWIS sessions ---
Stop-Sessions

$summary = "Summary: $($script:stats.ComponentsAdded) component[s] added, " +
           "$($script:stats.ComponentsExisting) already existed, " +
           "$($script:stats.ComponentsFailed) failed; " +
           "$($script:stats.InterfacesAdded) interface[s] and " +
           "$($script:stats.PollersAdded) poller[s] added."
Write-Log $summary -ForegroundColor Green

Write-Log "Script completed."
Write-Log "=== Run finished ===" -NoConsole