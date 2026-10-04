<#
.SYNOPSIS
    SolarWinds SWIS PowerShell script  add the devices managed by Cisco FMC as nodes

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

    The result is a single script that walks the devices FMC reports and
    adds every one of them that does not already exist in SolarWinds.

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
    param(
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
    }
    catch {
        Write-Warning "Could not resolve '$HostName': $($_.Exception.Message)"
    }

    $null
}

# --- Function: Add a Node [Component] ---
function Add-SwisNode {
    param(
        [Parameter(Mandatory = $true)] $Swis,
        [Parameter(Mandatory = $true)] [string]$IPAddress,
        [string]$Name = "",
        [int]$EngineID = 2,
        [int]$SNMPVersion = 2,
        [string]$Community = ""
    )

    $newNodeProps = @{
        IPAddress     = $IPAddress
        EngineID      = $EngineID
        Caption       = $Name

        # SNMP v2 specific
        ObjectSubType = "SNMP"
        SNMPVersion   = $SNMPVersion
        Community     = $Community

        DNS           = ""
        SysName       = ""
    }

    $newNodeUri = New-SwisObject $Swis -EntityType "Orion.Nodes" -Properties $newNodeProps
    $nodeProps  = Get-SwisObject $Swis -Uri $newNodeUri

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
        New-SwisObject $Swis -EntityType "Orion.Pollers" -Properties $poller | Out-Null
    }

    $nodeProps
}

# --- Read the managed devices from FMC ---
try {
    $fmcCred    = Import-Clixml -Path $FmcCredentialPath
    $fmcSession = Connect-Fmc -Server $FmcServer -Credential $fmcCred -TrustAllCertificates
}
catch {
    Write-Error "Failed to authenticate with FMC: $($_.Exception.Message)"
    return
}

try {
    $devices = Get-FmcDeviceRecords -Session $fmcSession
}
catch {
    Write-Error "Failed to retrieve devices from FMC: $($_.Exception.Message)"
    return
}
finally {
    try {
        Disconnect-Fmc -Session $fmcSession
    }
    catch {
        Write-Warning "Failed to revoke the FMC access token: $($_.Exception.Message)"
    }
}

if (-not $devices) {
    Write-Warning "FMC returned no devices - nothing to add."
    return
}

# --- Connect to SWIS ---
try {
    $swisCred = Import-Clixml -Path $SwisCredentialPath
    $swis     = Connect-Swis -Hostname $SwisHost -Credential $swisCred
    Write-Host "Connected to SolarWinds Information Service (SWIS)." -ForegroundColor Green
}
catch {
    Write-Error "Failed to connect to SWIS: $($_.Exception.Message)"
    return
}

# --- Main Loop: Process each device ---
try {
    foreach ($device in $devices) {
        $ip = Resolve-ManagementAddress -HostName $device.HostName
        if (-not $ip) {
            Write-Warning "Skipping '$($device.Name)' - no usable management address ('$($device.HostName)')."
            continue
        }

        Write-Host "Processing '$($device.Name)' ($ip)..."

        try {
            $existing = Get-SwisData -SwisConnection $swis -Query "SELECT NodeID FROM Orion.Nodes WHERE IPAddress = @ip" -Parameters @{ ip = $ip }

            if ($existing) {
                Write-Host " Node already exists [NodeID $(@($existing)[0])], skipping add." -ForegroundColor DarkBlue
                continue
            }

            $nodeProps = Add-SwisNode -Swis $swis -Name $device.Name -IPAddress $ip -EngineID $EngineID -SNMPVersion $SNMPVersion -Community $SNMPCommunity
            Write-Host " Added node [NodeID $($nodeProps["NodeID"])]." -ForegroundColor Green
        }
        catch {
            Write-Host " Failed to process '$($device.Name)' ($ip): $($_.Exception.Message)" -ForegroundColor Red
        }
    }
}
finally {
    # Connect-Swis returns an InfoServiceProxy, which is IDisposable, so close
    # it explicitly instead of leaving it to the finalizer.
    $swis.Close()
}

Write-Host "Script completed."
