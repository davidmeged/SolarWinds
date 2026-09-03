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
#>

param(
    # Shared settings applied to every device retrieved from DNA.
    [int]$EngineID = 2,
    [int]$SNMPVersion = 2,
    [string]$SNMPCommunity = ''
)

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

# Call function "Get-TokenDNA"
try {
    $tokenObj = Get-TokenDNA -uri $dnaUrlToken -user $dnaCredentials.UserName -pass $dnaCredentials.GetNetworkCredential().password

    # Get Token from results function
    $tokenString = $tokenObj.Token

    if (-not $tokenString) {
        Write-Error "DNA authentication did not return a token. Check URL/credentials."
        exit
    }
} catch {
    Write-Error "Failed to authenticate with DNA: $($_.Exception.Message)"
    exit
}

# Call function "Get-DNADevices"
try {
    $results = Get-DNADevices -token $tokenString -url $dnaUrlDevices
} catch {
    Write-Error "Failed to retrieve devices from DNA: $($_.Exception.Message)"
    exit
}

# Get ip address of devices from results function
$addresses = @($results.managementIpAddress)

if (-not $addresses) {
    Write-Warning "DNA returned no devices - nothing to process."
    exit
}

try {
    $swis = Connect-Swis -Host $hostname -UserName $username -Password $password.GetNetworkCredential().Password
    Write-Host "Connected to SolarWinds Information Service (SWIS)." -ForegroundColor Green
} catch {
    Write-Error "Failed to connect to SWIS: $($_.Exception.Message)"
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
    }

    return $nodeProps["NodeID"]
}

# --- Function: Discover and Add Interfaces on a Node ---
function Add-DiscoveredInterfaces {
    param($nodeId)

    # Discover interfaces on the node
    $discovered = Invoke-SwisVerb $swis Orion.NPM.Interfaces DiscoverInterfacesOnNode $nodeId

    if ($discovered.Result -ne "Succeed") {
        Write-Host " Interface discovery failed for node $nodeId." -ForegroundColor Red
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

    $interfaceCount = @($discovered.DiscoveredInterfaces.DiscoveredLiteInterface).Count

    if ($interfaceCount -eq 0) {
        Write-Host " No interfaces left to add for node $($nodeId) after filtering." -ForegroundColor DarkBlue
        return
    }

    # Add the remaining interfaces
    try {
        Invoke-SwisVerb $swis Orion.NPM.Interfaces AddInterfacesOnNode @($nodeId, $discovered.DiscoveredInterfaces, "AddDefaultPollers") | Out-Null
        Write-Host " Added $interfaceCount interface[s] for node $($nodeId)." -ForegroundColor Green
    } catch {
        Write-Host " Failed to add interfaces for node $($nodeId): $($_.Exception.Message)" -ForegroundColor Red
    }
}

# --- Main Loop: Process each component ---
foreach ($component in $components) {
    Write-Host "Processing component $($component.IPAddress)..."

    try {
        # Check if node already exists
        $existing = Get-SwisData -SwisConnection $swis -Query "SELECT NodeID FROM Orion.Nodes WHERE IPAddress = '$($component.IPAddress)'"

        if ($existing) {
            $nodeId = $existing # Note: Get-SwisData returns an array of objects, access the property
            Write-Host " Node already exists {NodeID $nodeId}, skipping add." -ForegroundColor DarkBlue
        }
        else {
            $nodeId = Add-Component $component
            Write-Host " Added node [NodeID $nodeId]."
        }

        # Discover and add interfaces for the node (whether new or existing)
        Add-DiscoveredInterfaces $nodeId

    } catch {
        Write-Host " Failed to process $($component.IPAddress): $($_.Exception.Message)"
    }
}

Write-Host "Script completed."