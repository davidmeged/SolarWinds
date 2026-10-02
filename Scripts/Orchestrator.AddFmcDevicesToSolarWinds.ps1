# This sample script wires FMC.GetDeviceRecords.ps1 directly into SolarWinds
# node creation: it dot-sources the FMC functions, reads the managed devices
# of the FMC Global domain, and adds every device that is not already
# monitored as a SolarWinds node with the default pollers, in one run.
#
# FMC registers a device by its management address, which may be an IP
# address or a DNS name. A DNS name is resolved to its first IPv4 address,
# because SolarWinds nodes are added by IP address.
#
# The devices must have SNMP enabled (FMC: Devices > Platform Settings > SNMP)
# with the community passed in -SNMPCommunity, or the Details/Uptime pollers
# will have nothing to poll.
#
# Please update the connection details/credentials for both systems below.

param(
    # --- Cisco FMC connection ---
    [string]$FmcServer = "1.1.1.1",
    [string]$FmcCredentialPath = "D:\SolarWindsScripts\PowerShell\Credentials\FMC_Credential.xml",

    # --- SolarWinds connection ---
    [string]$SwisHost = "5.5.5.5",
    [string]$SwisCredentialPath = "D:\SolarWindsScripts\PowerShell\Credentials\SolarWindsCredentials.xml",

    # SNMP community configured on the FTD devices.
    [string]$SNMPCommunity = "public"
)

# Dot-source the FMC functions (Connect-Fmc, Get-FmcDeviceRecords,
# Disconnect-Fmc) and the SolarWinds node-creation helper
# (Add-SwisNodeWithDefaultPollers). The example-usage blocks at the bottom of
# those files are commented out, so dot-sourcing here just loads the
# functions.
. (Join-Path $PSScriptRoot "FMC.GetDeviceRecords.ps1")
. (Join-Path $PSScriptRoot "CRUD.AddNodeWithPollers.ps1")

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

# --- Add the devices to SolarWinds ---
try {
    $swisCred = Import-Clixml -Path $SwisCredentialPath
    $swis     = Connect-Swis -Hostname $SwisHost -Credential $swisCred
    Write-Host "Connected to SolarWinds Information Service (SWIS)." -ForegroundColor Green
}
catch {
    Write-Error "Failed to connect to SWIS: $($_.Exception.Message)"
    return
}

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

            $nodeProps = Add-SwisNodeWithDefaultPollers -Swis $swis -Name $device.Name -IPAddress $ip -Community $SNMPCommunity
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
