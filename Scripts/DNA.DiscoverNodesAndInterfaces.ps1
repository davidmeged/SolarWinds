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

    The list of components (nodes) can be supplied via the -IPAddresses
    parameter, e.g.:
        .\NPM.DiscoverComponentsAndInterfaces.ps1 -IPAddresses "10.0.0.1","10.0.0.2","10.0.0.3"
        .\NPM.DiscoverComponentsAndInterfaces.ps1 -IPAddresses "10.0.0.1,10.0.0.2,10.0.0.3"

    If -IPAddresses is not supplied, the sample list below is used instead.
#>

param(
    # One or more IP addresses to add/discover. Accepts either an array of
    # strings or a single comma-separated string.
    [string[]]$IPAddresses,

    # Shared settings applied to every IP address passed via -IPAddresses.
    [int]$EngineID = 2,
    [int]$SNMPVersion = 2,
    [string]$SNMPCommunnity = ''
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
    $allDevices = Invoke-WebRequest -Uri $url -Headers $header -Method Get -SkipCertificateCheck
    return $allDevices.Content | ConvertFrom-Json
}

# Call function "Get-TokenDNA"
$tokenObj = Get-TokenDNA -uri $dnaUrlToken -user $dnaCredentials.UserName -pass $dnaCredentials.GetNetworkCredential().password

# Get Token from results function
$tokenString = $tokenObj.Token

# Call function "Get-DNADevices"
$results = Get-DNADevices -token $tokenString -url $dnaUrlDevices

# Get ip address of devices from results function
$addresses = $results.response.managementIpAddress -join "`n"

try {
    $swis = Connect-Swis -Host $hostname -UserName $username -Password $password.GetNetworkCredential().Password
    Write-Host "Connected to SolarWinds Information Service (SWIS)." -ForegroundColor Green
} catch {
    Write-Error "Failed to connect to SWIS: $($_.Exception.Message)"
    exit
}

# --- Build the list of components to process ---
if ($addressesForCluster) {
    # Build $components from the -IPAddresses parameter (supports both
    # "-IPAddresses ip1,ip2" and "-IPAddresses 'ip1,ip2'" invocation styles).
    $components = $addressesForCluster |
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
                Community   = $SNMPCommunnity
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

    $discovered.DiscoveredInterfaces.DiscoveredLiteInterface | Where-Object {
        $_.Caption.InnerText -match 'bond\d.\d+' -or
        $_.Caption.InnerText -match '\blo\b' -or
        $_.Caption.InnerText -match '\bpimreg\b' -or
        $_.Caption.InnerText -match 'eth\d+\.\d+' -or
        $_.Caption.InnerText -match 'eth\d+-\d+\.\d+' -or
        $_.ifOperStatus -match '2'
    } | ForEach-Object { $discovered.DiscoveredInterfaces.RemoveChild($_) } | Out-Null

    $interfaceCount = $discovered.DiscoveredInterfaces.DiscoveredLiteInterface.Count

    # Add the remaining interfaces
    Invoke-SwisVerb $swis Orion.NPM.Interfaces AddInterfacesOnNode @($nodeId, $discovered.DiscoveredInterfaces, "AddDefaultPollers") | Out-Null

    Write-Host " Added $interfaceCount interface[s] for node $nodeId." -ForegroundColor Green
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