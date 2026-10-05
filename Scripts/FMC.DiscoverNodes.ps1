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

.EXAMPLE
    .\FMC.DiscoverNodes.ps1

    Runs with the defaults set in the param block.

.EXAMPLE
    .\FMC.DiscoverNodes.ps1 -FmcServer fmc.example.com -SwisHost orion.example.com -SNMPCommunity "mycommunity"

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
    [string]$SNMPCommunity = ''
)

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
                Write-Warning "FMC rate limit reached, retrying in $delay seconds..."
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
        Write-Warning "Could not resolve '$HostName': $($_.Exception.Message)"
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
            Write-Host "Revoked the FMC API token." -ForegroundColor Green
        } catch {
            Write-Warning "Failed to revoke the FMC API token: $($_.Exception.Message)"
        }
        $script:fmcSession = $null
    }

    if ($script:swis) {
        try {
            $script:swis.Close()
            Write-Host "Closed the SWIS connection." -ForegroundColor Green
        } catch {
            Write-Warning "Failed to close the SWIS connection: $($_.Exception.Message)"
        }
        $script:swis = $null
    }
}

# Call function "Connect-Fmc"
try {
    $fmcCredentials = Import-Clixml -Path $FmcCredentialPath
    $fmcSession     = Connect-Fmc -Server $FmcServer -Credential $fmcCredentials -TrustAllCertificates
} catch {
    Write-Error "Failed to authenticate with FMC: $($_.Exception.Message)"
    Stop-Sessions
    exit
}

# Call function "Get-FmcDeviceRecords"
try {
    $results = Get-FmcDeviceRecords -Session $fmcSession
} catch {
    Write-Error "Failed to retrieve devices from FMC: $($_.Exception.Message)"
    Stop-Sessions
    exit
}

# The device list is all that is needed from FMC, so revoke the token now
# instead of letting it run out (30 minutes) while the nodes are added.
Stop-Sessions

if (-not $results) {
    Write-Warning "FMC returned no devices - nothing to process."
    exit
}

try {
    $swisCredentials = Import-Clixml -Path $SwisCredentialPath
    $swis = Connect-Swis -Hostname $SwisHost -Credential $swisCredentials
    Write-Host "Connected to SolarWinds Information Service (SWIS)." -ForegroundColor Green
} catch {
    Write-Error "Failed to connect to SWIS: $($_.Exception.Message)"
    Stop-Sessions
    exit
}

# --- Build the list of components to process ---
# Build $components from the devices returned by FMC: the management address
# is resolved to an IPv4 address and the FMC device name is kept as the node
# caption. A device without a usable address is skipped with a warning.
$components = foreach ($device in $results) {
    $ip = Resolve-ManagementAddress -HostName $device.HostName

    if (-not $ip) {
        Write-Warning "Skipping '$($device.Name)' - no usable management address ('$($device.HostName)')."
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

    # Where-Object drops the $null left once every interface was removed -
    # @($null).Count is 1, which would report one interface and add none.
    $interfaceCount = @($discovered.DiscoveredInterfaces.DiscoveredLiteInterface | Where-Object { $_ }).Count

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
    Write-Host "Processing component $($component.Caption) ($($component.IPAddress))..."

    try {
        # Check if node already exists
        $existing = Get-SwisData -SwisConnection $swis -Query "SELECT NodeID FROM Orion.Nodes WHERE IPAddress = @ip" -Parameters @{ ip = $component.IPAddress }

        if ($existing) {
            $nodeId = @($existing)[0]
            Write-Host " Node already exists {NodeID $nodeId}, skipping add." -ForegroundColor DarkBlue
        }
        else {
            $nodeId = Add-Component $component
            Write-Host " Added node [NodeID $nodeId]." -ForegroundColor Green
        }

        # Discover and add interfaces for the node (whether new or existing)
        Add-DiscoveredInterfaces $nodeId

    } catch {
        Write-Host " Failed to process $($component.IPAddress): $($_.Exception.Message)" -ForegroundColor Red
    }
}

# --- End the FMC and SWIS sessions ---
Stop-Sessions

Write-Host "Script completed."
