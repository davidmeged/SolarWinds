#Requires -Version 5.1

<#
.SYNOPSIS
    Points the SolarWinds DNS record at the SolarWinds server that has just
    become active. No load balancer, no web servers, no SNMP.

.DESCRIPTION
    This is the Alteon-free variant of DNS.SetSolarWindsRecordToActiveLB.v2.ps1.
    That script asks a Radware load balancer over SNMP how the web servers
    behind it are doing, and picks a load balancer accordingly. This one does
    not ask anything: it is told which SolarWinds server is now active, and
    points the record straight at it.

    Being told is the point. SolarWinds decided which server is active, so
    SolarWinds is the authority on it. Anything the script worked out for
    itself would at best reproduce that answer and at worst contradict it.

    It is meant to run as an alert action on the server that has just become
    active, with that server's address passed in -ActiveServer. Nothing is
    written when the record already holds the wanted address, so it is also
    safe to run on a schedule.

.PARAMETER ActiveServer
    The address of the SolarWinds server that is now active, and the address
    the record will be pointed at. It has to match either PrimaryDcSolarWindsIp
    or SecondaryDcSolarWindsIp, otherwise the script fails instead of quietly
    doing nothing.

.PARAMETER DnsServer
    The DNS server to read the record from and write it back to. It has to hold
    a writable copy of the zone. When it is left out the script walks the DNS
    servers configured on this host and takes the first one that answers a ping.

.PARAMETER LogMaxBytes
    The size at which the log is rotated. Rotation keeps LogKeep older
    generations beside it, so the space the logging can occupy is bounded at
    roughly LogMaxBytes times LogKeep plus one.

.PARAMETER LogKeep
    How many rotated logs to keep. Zero keeps none: the log starts over
    instead.

.PARAMETER RecordTtlSeconds
    When greater than zero, the TTL written onto the record. A failover only
    takes effect once the old TTL has expired everywhere, so a low value (30-60)
    is worth setting here.

.EXAMPLE
    .\DNS.SetSolarWindsRecordToActiveServer.ps1 -ActiveServer 10.10.10.1 -WhatIf

    Shows what would change without touching DNS.

.EXAMPLE
    .\DNS.SetSolarWindsRecordToActiveServer.ps1 -ActiveServer 10.10.20.1

.NOTES
    Exit codes: 0 done (changed or nothing to change), 1 failed.

    Call it with -File, not -Command:

        powershell.exe -NoProfile -File DNS.SetSolarWindsRecordToActiveServer.ps1 -ActiveServer 10.10.10.1

    A parameter that fails validation stops the script before it runs, and only
    -File turns that into exit code 1. Under -Command the caller reads a stale
    $LASTEXITCODE instead, so a typo in the arguments looks like a clean run.

    The record points at the SolarWinds server itself. If a load balancer sits
    in front of SolarWinds in your environment, this is the wrong script for it:
    use DNS.SetSolarWindsRecordToActiveLB.v2.ps1, which picks between the two
    load balancers on the health of the web servers behind them.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateNotNullOrEmpty()]
    [string] $ActiveServer,

    [ValidateNotNullOrEmpty()]
    [string] $RecordName = 'OurSolar',

    [ValidateNotNullOrEmpty()]
    [string] $ZoneName = 'OurZone',

    [string] $DnsServer,

    [ValidateNotNullOrEmpty()]
    [string] $PrimaryDcSolarWindsIp = '10.10.10.1',

    [ValidateNotNullOrEmpty()]
    [string] $SecondaryDcSolarWindsIp = '10.10.20.1',

    [ValidateRange(0, 86400)]
    [int] $RecordTtlSeconds = 0,

    [string] $LogPath = (Join-Path -Path $env:ProgramData -ChildPath 'SolarWinds\dns-active-server.log'),

    [ValidateRange(4KB, 100MB)]
    [int] $LogMaxBytes = 1MB,

    [ValidateRange(0, 20)]
    [int] $LogKeep = 3
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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
        Remove-Item -LiteralPath $Path -Force -WhatIf:$false -Confirm:$false
        return
    }

    # Oldest generation falls off the end.
    $oldest = "$Path.$($script:LogKeep)"
    if (Test-Path -LiteralPath $oldest) {
        Remove-Item -LiteralPath $oldest -Force -WhatIf:$false -Confirm:$false
    }

    # Shift the rest down, highest first so nothing is overwritten on the way.
    for ($i = $script:LogKeep - 1; $i -ge 1; $i--) {
        $from = "$Path.$i"
        if (Test-Path -LiteralPath $from) {
            Move-Item -LiteralPath $from -Destination "$Path.$($i + 1)" -Force -WhatIf:$false -Confirm:$false
        }
    }

    Move-Item -LiteralPath $Path -Destination "$Path.1" -Force -WhatIf:$false -Confirm:$false
}

function Write-Log {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Message,

        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string] $Level = 'INFO'
    )

    $line = '{0:yyyy-MM-dd HH:mm:ss} [{1,-5}] {2}' -f (Get-Date), $Level, $Message
    Write-Information -MessageData $line -InformationAction Continue

    # -WhatIf:$false so that a -WhatIf run still leaves a trace of what it
    # decided; the log is a record, never one of the changes being previewed.
    try {
        $directory = Split-Path -Path $script:LogPath -Parent
        if ($directory -and -not (Test-Path -LiteralPath $directory)) {
            New-Item -Path $directory -ItemType Directory -Force -WhatIf:$false -Confirm:$false | Out-Null
        }
        Invoke-LogRotation -Path $script:LogPath
        Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8 -WhatIf:$false -Confirm:$false
    }
    catch {
        Write-Warning "Could not write to the log file '$script:LogPath': $($_.Exception.Message)"
    }
}

function Resolve-DnsServerAddress {
    # Walks the DNS servers configured on this host and returns the first one
    # that answers a ping. Only adapters with IP enabled are looked at, so
    # disconnected or disabled NICs cannot contribute a stale address.
    [OutputType([string])]
    param()

    $adapters = Get-CimInstance -ClassName Win32_NetworkAdapterConfiguration -Filter 'IPEnabled = True'

    foreach ($adapter in $adapters) {
        foreach ($address in $adapter.DNSServerSearchOrder) {
            if (Test-Connection -ComputerName $address -Count 1 -Quiet -ErrorAction SilentlyContinue) {
                Write-Log "Using DNS server $address, configured on '$($adapter.Description)'."
                return [string]$address
            }

            Write-Log "DNS server $address did not answer a ping, trying the next one." -Level WARN
        }
    }

    throw 'None of the DNS servers configured on this host answered a ping. Pass -DnsServer to name one explicitly.'
}

function Get-SolarWindsRecord {
    param(
        [Parameter(Mandatory)][string] $Server
    )

    $records = @(Get-DnsServerResourceRecord -ComputerName $Server -ZoneName $ZoneName -Name $RecordName -RRType A)

    if ($records.Count -eq 0) {
        throw "Zone '$ZoneName' on $Server holds no A record named '$RecordName'."
    }

    if ($records.Count -gt 1) {
        throw "Zone '$ZoneName' on $Server holds $($records.Count) A records named '$RecordName'. This script handles a single A record, so the duplicates have to be resolved first."
    }

    return $records[0]
}

function Set-SolarWindsRecord {
    # Set-DnsServerResourceRecord needs the untouched record and the edited copy
    # as two separate objects, hence the Clone.
    param(
        [Parameter(Mandatory)][string] $Server,
        [Parameter(Mandatory)][string] $TargetIp
    )

    $current = Get-SolarWindsRecord -Server $Server
    $updated = $current.Clone()
    $updated.RecordData.IPv4Address = [System.Net.IPAddress]::Parse($TargetIp)

    if ($RecordTtlSeconds -gt 0) {
        $updated.TimeToLive = [System.TimeSpan]::FromSeconds($RecordTtlSeconds)
    }

    Set-DnsServerResourceRecord -ComputerName $Server -ZoneName $ZoneName -OldInputObject $current -NewInputObject $updated

    $after = Get-SolarWindsRecord -Server $Server
    $afterIp = $after.RecordData.IPv4Address.IPAddressToString

    if ($afterIp -ne $TargetIp) {
        throw "The record was written but still reads $afterIp instead of $TargetIp."
    }
}

try {
    Write-Log "===== Run started for active server $ActiveServer ====="

    # A SolarWinds alert action fills this in from a macro, and a macro can
    # hand over its value padded with whitespace. Trimming here means a stray
    # space cannot stop a failover; without it the address matches neither
    # server and the run fails for no good reason.
    $ActiveServer = $ActiveServer.Trim()

    # The address is checked against the two servers the script knows rather
    # than used as given, so a typo in the alert action cannot point the record
    # at something that was never a SolarWinds server.
    if ($ActiveServer -eq $PrimaryDcSolarWindsIp) {
        $activeName = 'PrimaryDC'
    }
    elseif ($ActiveServer -eq $SecondaryDcSolarWindsIp) {
        $activeName = 'SecondaryDC'
    }
    else {
        throw "ActiveServer '$ActiveServer' is neither the PrimaryDC SolarWinds server ($PrimaryDcSolarWindsIp) nor the SecondaryDC one ($SecondaryDcSolarWindsIp)."
    }

    Write-Log "$activeName is active, so the record should point at $ActiveServer."

    $dnsServerAddress = if ($DnsServer) { $DnsServer } else { Resolve-DnsServerAddress }

    $record = Get-SolarWindsRecord -Server $dnsServerAddress
    $currentIp = $record.RecordData.IPv4Address.IPAddressToString
    Write-Log "$RecordName.$ZoneName currently points at $currentIp with a TTL of $($record.TimeToLive)."

    if ($currentIp -eq $ActiveServer) {
        Write-Log "Nothing to do, the record already points at the $activeName server ($ActiveServer)."
        exit 0
    }

    $target = "$RecordName.$ZoneName on $dnsServerAddress"
    $action = "Repoint from $currentIp to $ActiveServer, the $activeName server"

    if (-not $PSCmdlet.ShouldProcess($target, $action)) {
        Write-Log "WhatIf: would have repointed $RecordName.$ZoneName from $currentIp to $ActiveServer ($activeName server)."
        exit 0
    }

    Set-SolarWindsRecord -Server $dnsServerAddress -TargetIp $ActiveServer
    Write-Log "Repointed $RecordName.$ZoneName from $currentIp to $ActiveServer, the $activeName server."
    exit 0
}
catch {
    Write-Log "Run failed: $($_.Exception.Message)" -Level ERROR
    Write-Log $_.ScriptStackTrace -Level ERROR
    Write-Error -Message $_.Exception.Message -ErrorAction Continue
    exit 1
}
