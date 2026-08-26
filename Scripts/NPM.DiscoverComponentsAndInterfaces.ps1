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
    Check Point SmartConsole API (cluster members and simple gateways).
#>

param(
    # One or more IP addresses to add/discover. Accepts either an array of
    # strings or a single comma-separated string.
    [string[]]$IPAddresses,

    # Shared settings applied to every IP address passed via -IPAddresses.
    [int]$EngineID = 2,
    [int]$SNMPVersion = 2,
    [string]$SNMPCommunity = ''
)

# --- Connect to SWIS ---
$hostname = ""
$username = ""
$password = Import-Clixml -Path ".\Credentials\SolarWindsCredential.xml"

# --- Function: Get all addresses from a SmartConsole endpoint (paginated) ---
function Get-SmartConsoleAddresses {
    param(
        [string]$Url,
        [string]$Field,
        [hashtable]$Header
    )

    $addresses = @()
    $offset    = 0
    $pageSize  = 500

    do {
        $body = @{
            "limit"         = $pageSize
            "offset"        = $offset
            "details-level" = "full"
        } | ConvertTo-Json

        $response     = Invoke-WebRequest -Uri $Url -Headers $Header -Body $body -Method Post -SkipCertificateCheck
        $responseJson = $response.Content | ConvertFrom-Json

        $addresses += $responseJson.objects.$Field
        $offset     += $pageSize
    } while ($offset -lt $responseJson.total)

    return $addresses
}

# --- Connect to SmartConsole ---
#url and server for login to SmartConsole
$url = "https:///web_api/login"
#username and password with permissions
$user = ""
$pass = ''

#Header type
$header = @{
    "Content-Type" = "application/json"
}

#Body with username and password for login, and convert to JSON format
$body = @{
    "user" = $user
    "password" = $pass
} | ConvertTo-Json

#login proccess for get sid <like token>
try {
    $response = Invoke-WebRequest -Uri $url -Headers $header -Body $body -Method Post -SkipCertificateCheck
    $responseJson = $response.Content | ConvertFrom-Json
    $sid = $responseJson.sid

    if (-not $sid) {
        Write-Error "SmartConsole login did not return a session id (sid). Check URL/credentials."
        exit
    }

    #Url to get gatways under Smart Console
    $urlForCluster = "https:///web_api/show-cluster-members"
    $urlForSimple  = "https:///web_api/show-simple-gateways"
    $header = @{
        "Content-Type" = "application/json"
        "x-chkp-sid" = $sid
    }

    # Calling with API to Smart Console to get gateways (handles pagination)
    $addressesForCluster = Get-SmartConsoleAddresses -Url $urlForCluster -Field 'ip-address'   -Header $header
    $addressesForSimple  = Get-SmartConsoleAddresses -Url $urlForSimple  -Field 'ipv4-address' -Header $header
} catch {
    Write-Error "Failed to retrieve gateways from SmartConsole: $($_.Exception.Message)"
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
$allAddresses = @($addressesForCluster) + @($addressesForSimple)

if ($allAddresses) {
    # Supports addresses arriving either as an array of strings or as
    # single comma-separated strings.
    $components = $allAddresses |
        ForEach-Object { $_.Split(',') } |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ } |
        Select-Object -Unique |
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
        Write-Host " Added $interfaceCount interface[s] for node $nodeId." -ForegroundColor Green
    } catch {
        Write-Host " Failed to add interfaces for node $nodeId : $($_.Exception.Message)" -ForegroundColor Red
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

# --- Logout from SmartConsole ---
if ($sid) {
    try {
        $urlForLogout = "https:///web_api/logout"
        Invoke-WebRequest -Uri $urlForLogout -Headers $header -Body (@{} | ConvertTo-Json) -Method Post -SkipCertificateCheck | Out-Null
        Write-Host "Logged out from SmartConsole session." -ForegroundColor Green
    } catch {
        Write-Warning "Failed to logout from SmartConsole session: $($_.Exception.Message)"
    }
}

Write-Host "Script completed."
