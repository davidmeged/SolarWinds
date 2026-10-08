<#
.SYNOPSIS
    SolarWinds SWIS PowerShell script - add the devices managed by Radware Cyber Controller as nodes and discover their interfaces

.DESCRIPTION
    This script combines the Radware Cyber Controller (formerly APSolute
    Vision) REST API with a building block from the SolarWinds SDK samples:

    o Cyber Controller REST API
        - authenticates with mgmt/system/user/login, keeps the returned
          JSESSIONID for the follow-up calls and reads the managed device
          inventory (Alteon, DefensePro, AppWall) from
          mgmt/system/config/itemlist/alldevices.

    o CRUD.AddNode.ps1
        - adds a node <component> using CRUD operations (New-SwisObject) and
          registers the standard set of pollers for it (Status, Response
          Time, Details, Uptime).

    o NPM.DiscoverAndAddInterfacesOnNode.ps1
        - uses Orion.NPM.Interfaces.DiscoverInterfacesOnNode and
          Orion.NPM.Interfaces.AddInterfacesOnNode (SWISv3 verbs, NPM only)
          to discover and add the interfaces of a node.

    The result is a single script that walks the devices Cyber Controller
    reports, adds every one of them that does not already exist in
    SolarWinds, and then discovers and adds their interfaces for monitoring.
    The interface filter in Add-DiscoveredInterfaces decides which interfaces
    are kept - adjust it to the interfaces you want monitored on the Radware
    devices.

    Cyber Controller registers a device by its management address, which may
    be an IP address or a DNS name. A DNS name is resolved to its first IPv4
    address, because SolarWinds nodes are added by IP address. A device whose
    address cannot be resolved is skipped with a warning.

    Cyber Controller API notes:
      - mgmt/system/user/login takes the credentials as a JSON body and
        returns the session id, both as a jsessionid field and as a
        JSESSIONID cookie. Every follow-up call carries it in the Cookie
        header.
      - The appliance answers HTTP 200 even when the credentials are wrong,
        so the status field of the body is what decides success.
      - Sessions are limited per user and only expire on the idle timeout, so
        the session is closed with mgmt/system/user/logout as soon as the
        device inventory has been read.
      - The API is summarised in Docs/Radware.CyberController.REST-API.md;
        confirm the endpoints against the reference guide of your installed
        version.

    Please update the parameter defaults below to match your environment
    before running.

.PARAMETER CyberControllerServer
    Address of the Cyber Controller (IP or DNS name).

.PARAMETER CyberControllerPort
    HTTPS port of the Cyber Controller management interface.

.PARAMETER CyberControllerCredentialPath
    Path to a PSCredential exported with Export-Clixml for a Cyber Controller
    user with REST API access. A read-only role is enough. Create it once, as
    the account that runs the script:
        Get-Credential | Export-Clixml -Path <path>

.PARAMETER DeviceType
    Keeps only the devices whose type matches this text, so one Cyber
    Controller can feed several runs - for example "Alteon" for the load
    balancers or "DefensePro" for the mitigation devices. Empty takes every
    managed device.

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
    SNMP community configured on the Radware devices (Cyber Controller:
    Configuration > device > Setup > SNMP). Without it the Details/Uptime
    pollers have nothing to poll.

.PARAMETER TrustAllCertificates
    Accept the self-signed certificate the Cyber Controller ships with.
    Import the certificate into the trust store instead for production use.

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
    .\Radware.CyberController.Connect.ps1

    Runs with the defaults set in the param block.

.EXAMPLE
    .\Radware.CyberController.Connect.ps1 -CyberControllerServer cc.example.com -DeviceType Alteon -SwisHost orion.example.com -SNMPCommunity "mycommunity"

.NOTES
    Runs on Windows PowerShell 5.1 and PowerShell 7+: on 5.1 the certificate
    validation callback is relaxed process wide instead of per request, since
    Invoke-RestMethod has no -SkipCertificateCheck switch there. Requires the
    SwisPowerShell module for Connect-Swis.
#>

param(
    # --- Radware Cyber Controller connection ---
    [string]$CyberControllerServer = "1.1.1.1",
    [int]$CyberControllerPort = 443,
    [string]$CyberControllerCredentialPath = "D:\SolarWindsScripts\PowerShell\Credentials\CyberController_Credential.xml",

    # Device family to process: "Alteon", "DefensePro", "AppWall", or empty
    # for every device Cyber Controller manages.
    [string]$DeviceType = "Alteon",

    # --- SolarWinds connection ---
    [string]$SwisHost = "5.5.5.5",
    [string]$SwisCredentialPath = "D:\SolarWindsScripts\PowerShell\Credentials\SolarWindsCredentials.xml",

    # Shared settings applied to every device retrieved from Cyber Controller.
    [int]$EngineID = 2,
    [int]$SNMPVersion = 2,
    [string]$SNMPCommunity = '',

    [switch]$TrustAllCertificates,

    # --- Log ---
    [string]$LogPath = (Join-Path -Path $env:ProgramData -ChildPath 'SolarWinds\cybercontroller-discover-nodes.log'),

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

# --- Function: Accept the self-signed certificate on PowerShell 5.1 ---
function Set-CyberControllerCertificatePolicy {
    # PowerShell 5.1 has no -SkipCertificateCheck on Invoke-RestMethod, so the
    # validation callback has to be relaxed process wide instead.
    if ($PSVersionTable.PSVersion.Major -ge 6) { return }

    if (-not ("RadwareTrustAllCertsPolicy" -as [type])) {
        Add-Type @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class RadwareTrustAllCertsPolicy : ICertificatePolicy {
    public bool CheckValidationResult(ServicePoint sp, X509Certificate cert, WebRequest req, int problem) {
        return true;
    }
}
"@
    }

    [System.Net.ServicePointManager]::CertificatePolicy = New-Object RadwareTrustAllCertsPolicy
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
}

# --- Function: Connect to Cyber Controller (open a session) ---
function Connect-CyberController {
    <#
    .SYNOPSIS
        Log in to the Cyber Controller REST API
    .OUTPUTS
        A session object carrying the base URI and the JSESSIONID that every
        follow-up call has to send in its Cookie header
    #>
    param(
        [Parameter(Mandatory = $true)] [string]$Server,
        [int]$Port = 443,
        [Parameter(Mandatory = $true)] [System.Management.Automation.PSCredential]$Credential,
        [switch]$TrustAllCertificates
    )

    if ($TrustAllCertificates) { Set-CyberControllerCertificatePolicy }

    # PtrToStringBSTR (rather than PtrToStringAuto) decodes the BSTR as UTF-16 on
    # every platform, and the buffer is zeroed again right after it is read.
    $passwordPtr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Credential.Password)
    try {
        $plainPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($passwordPtr)
    }
    finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($passwordPtr)
    }

    $baseUri = "https://${Server}:${Port}"

    $body = @{
        username = $Credential.UserName
        password = $plainPassword
    } | ConvertTo-Json

    $params = @{
        Uri             = "$baseUri/mgmt/system/user/login"
        Method          = "Post"
        Body            = $body
        ContentType     = "application/json"
        SessionVariable = "webSession"
    }
    if ($TrustAllCertificates -and $PSVersionTable.PSVersion.Major -ge 6) {
        $params["SkipCertificateCheck"] = $true
    }

    $response = Invoke-RestMethod @params

    # Cyber Controller answers with HTTP 200 even when the credentials are wrong,
    # so the status field in the body is what decides success.
    if ($response.status -and $response.status -ne "ok") {
        throw "Login to $Server failed: $($response.message)"
    }

    $jsessionId = $response.jsessionid
    if (-not $jsessionId) {
        # Older versions only return the session as a cookie.
        $cookie = $webSession.Cookies.GetCookies($baseUri) |
            Where-Object { $_.Name -eq "JSESSIONID" } |
            Select-Object -First 1
        $jsessionId = $cookie.Value
    }
    if (-not $jsessionId) {
        throw "Login to $Server succeeded but no JSESSIONID was returned."
    }

    [pscustomobject]@{
        Server               = $Server
        Port                 = $Port
        BaseUri              = $baseUri
        JSessionId           = $jsessionId
        TrustAllCertificates = [bool]$TrustAllCertificates
    }
}

# --- Function: Call the Cyber Controller management API ---
function Invoke-CyberControllerApi {
    param(
        [Parameter(Mandatory = $true)] [pscustomobject]$Session,
        [Parameter(Mandatory = $true)] [string]$Path,
        [ValidateSet("Get", "Post", "Put", "Delete")] [string]$Method = "Get",
        $Body
    )

    $params = @{
        Uri     = "$($Session.BaseUri)/$($Path.TrimStart('/'))"
        Method  = $Method
        Headers = @{ "Cookie" = "JSESSIONID=$($Session.JSessionId)" }
    }
    if ($null -ne $Body) {
        $params["Body"] = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 10 }
        $params["ContentType"] = "application/json"
    }
    if ($Session.TrustAllCertificates -and $PSVersionTable.PSVersion.Major -ge 6) {
        $params["SkipCertificateCheck"] = $true
    }

    Invoke-RestMethod @params
}

# --- Function: Disconnect from Cyber Controller (close the session) ---
function Disconnect-CyberController {
    param(
        [Parameter(Mandatory = $true)] [pscustomobject]$Session
    )

    # Sessions are limited per user and only expire on the idle timeout, so a
    # script that does not log out slowly consumes them.
    Invoke-CyberControllerApi -Session $Session -Path "/mgmt/system/user/logout" | Out-Null
}

# --- Function: Get the managed device inventory from Cyber Controller ---
function Get-CyberControllerDevices {
    <#
    .SYNOPSIS
        Read the devices Cyber Controller manages, optionally one family only
    .PARAMETER Session
        The session returned by Connect-CyberController
    .PARAMETER DeviceType
        Keeps only the devices whose type contains this text (for example
        "Alteon"). Empty returns every managed device.
    .OUTPUTS
        One object per device with Name, HostName and Type
    #>
    param(
        [Parameter(Mandatory = $true)] [pscustomobject]$Session,
        [string]$DeviceType = ''
    )

    $response = Invoke-CyberControllerApi -Session $Session -Path "/mgmt/system/config/itemlist/alldevices"

    # The endpoint returns the devices either as a bare array or wrapped in an
    # object that carries them in its only array property, depending on the
    # version, so the list is unwrapped before it is read.
    $devices = if ($response -is [System.Collections.IEnumerable] -and $response -isnot [string]) {
        @($response)
    } else {
        $listProperty = $response.PSObject.Properties |
            Where-Object { $_.Value -is [array] } |
            Select-Object -First 1
        if ($listProperty) { @($listProperty.Value) } else { @($response) }
    }

    foreach ($device in $devices) {
        if (-not $device) { continue }

        # Field names differ between versions and device families: the first
        # management address that is actually filled in is the one used.
        $address = @(
            $device.managementIp,
            $device.managementIpAddr,
            $device.deviceIp,
            $device.ip,
            $device.ipAddress
        ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1

        $type = @(
            $device.deviceType,
            $device.type,
            $device.deviceSetupDeviceType
        ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1

        $name = @(
            $device.name,
            $device.deviceName,
            $device.caption,
            $address
        ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1

        if ($DeviceType -and $type -notlike "*$DeviceType*") {
            continue
        }

        [pscustomobject]@{
            Name     = $name
            HostName = $address
            Type     = $type
        }
    }
}

# --- Function: Resolve a management address to an IPv4 address ---
function Resolve-ManagementAddress {
    <#
    .SYNOPSIS
        Turn the management address Cyber Controller reports into an IPv4 address
    .PARAMETER HostName
        The device's management address - an IP address or a DNS name
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

# --- Function: End the Cyber Controller and SWIS sessions ---
function Stop-Sessions {
    <#
    .SYNOPSIS
        End the Cyber Controller and SWIS sessions opened by this script
    .DESCRIPTION
        Cyber Controller publishes a logout endpoint
        (mgmt/system/user/logout), so the session is closed rather than left
        to the idle timeout - each user has a limited number of concurrent
        sessions.

        SWIS has no Disconnect-Swis cmdlet, but Connect-Swis returns an
        InfoServiceProxy, which is IDisposable, so the connection can be
        closed explicitly instead of being left to the finalizer.

        Safe to call more than once - each session is ended only once.
    #>
    if ($script:ccSession) {
        try {
            Disconnect-CyberController -Session $script:ccSession
            Write-Log "Closed the Cyber Controller session." -Color Green
        } catch {
            Write-Log "Failed to close the Cyber Controller session: $($_.Exception.Message)" -Level WARN
        }
        $script:ccSession = $null
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

Write-Log "===== Run started: Cyber Controller $CyberControllerServer -> SolarWinds $SwisHost ====="

# Call function "Connect-CyberController"
try {
    $ccCredentials = Import-Clixml -Path $CyberControllerCredentialPath
    $ccSession     = Connect-CyberController -Server $CyberControllerServer -Port $CyberControllerPort `
        -Credential $ccCredentials -TrustAllCertificates:$TrustAllCertificates
    Write-Log "Opened a Cyber Controller session on $CyberControllerServer." -Color Green
} catch {
    Write-Log "Failed to authenticate with Cyber Controller: $($_.Exception.Message)" -Level ERROR
    Stop-Sessions
    exit
}

# Call function "Get-CyberControllerDevices"
try {
    $results = Get-CyberControllerDevices -Session $ccSession -DeviceType $DeviceType
} catch {
    Write-Log "Failed to retrieve devices from Cyber Controller: $($_.Exception.Message)" -Level ERROR
    Stop-Sessions
    exit
}

# The device list is all that is needed from Cyber Controller, so close the
# session now instead of holding it while the nodes are added.
Stop-Sessions

$deviceFamily = if ($DeviceType) { "$DeviceType device[s]" } else { "device[s]" }
Write-Log "Cyber Controller returned $(@($results).Count) $deviceFamily."

if (-not $results) {
    Write-Log "Cyber Controller returned no devices - nothing to process." -Level WARN
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

# --- Build the list of components to process ---
# Build $components from the devices returned by Cyber Controller: the
# management address is resolved to an IPv4 address and the device name is
# kept as the node caption. A device without a usable address is skipped with
# a warning.
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

    # Keep only the interfaces that are operationally up (ifOperStatus 1).
    # Radware devices name their ports per family and per model - Alteon
    # reports its data ports and trunks, DefensePro its G ports - so unlike
    # the Cisco script there is no caption allow-list here. Add one on the
    # same line to narrow the set further, for example:
    #   $_.Caption.InnerText -notmatch '^(Port|trunk)' -or $_.ifOperStatus -ne '1'
    #
    # The node list is materialised with @() first: RemoveChild shrinks the
    # live XmlNodeList, and removing from it while the pipeline is still
    # enumerating it skips nodes.
    @($discovered.DiscoveredInterfaces.DiscoveredLiteInterface) | Where-Object {
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

    } catch {
        Write-Log " Failed to process $($component.Caption) ($($component.IPAddress)): $($_.Exception.Message)" -Level ERROR
        $failedCount++
    }
}

# --- End the Cyber Controller and SWIS sessions ---
Stop-Sessions

Write-Log "===== Run completed: $addedCount node[s] added, $existingCount already existed, $skippedCount skipped, $failedCount failed, $interfaceTotal interface[s] added ====="
