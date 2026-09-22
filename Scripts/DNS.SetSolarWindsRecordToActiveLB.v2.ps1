#Requires -Version 5.1

<#
.SYNOPSIS
    Points the SolarWinds DNS A record at the load balancer of the data centre
    that is currently able to serve it.

.DESCRIPTION
    The script is meant to run as an alert action on the SolarWinds server that
    has just become active. It is told which SolarWinds server it is running
    for, polls that data centre's web servers through the local load balancer
    over SNMP, and repoints the A record at the local load balancer while the
    data centre is serving, or at the other data centre's load balancer once
    every web server there has stopped answering.

    Nothing is written when the record already holds the wanted address, so the
    script is safe to run on a schedule.

.PARAMETER ActiveServer
    The address of the SolarWinds server this run is for. It has to match either
    PrimaryDcSolarWindsIp or SecondaryDcSolarWindsIp, otherwise the script fails
    instead of quietly doing nothing.

.PARAMETER DnsServer
    The DNS server to read the record from and write it back to. It has to hold
    a writable copy of the zone. When it is left out the script walks the DNS
    servers configured on this host and takes the first one that answers a ping.

.PARAMETER HealthyValue
    The SNMP value that means "this web server is up". Everything else counts as
    down. See the note at the bottom of this help before changing it.

.PARAMETER PollCount
    How many times a data centre is polled before it is declared down. This is
    what keeps a single bad reading from moving the record.

.PARAMETER SnmpFailureMode
    What to do when none of the polls get an answer at all. 'Down' treats an
    unreachable load balancer as a dead data centre and fails over, which is the
    behaviour the original script had. 'Unknown' leaves the record alone and
    exits with code 2, which is the safer choice if SNMP is flaky.

.PARAMETER RecordTtlSeconds
    When greater than zero, the TTL written onto the record. A failover only
    takes effect once the old TTL has expired everywhere, so a low value (30-60)
    is worth setting here.

.EXAMPLE
    .\DNS.SetSolarWindsRecordToActiveLB.v2.ps1 -ActiveServer 10.10.10.1 -WhatIf

    Shows what would change without touching DNS.

.EXAMPLE
    .\DNS.SetSolarWindsRecordToActiveLB.v2.ps1 -ActiveServer 10.10.20.1 -Verbose

.NOTES
    Exit codes: 0 done (changed or nothing to change), 1 failed, 2 the state of
    the data centre could not be determined and the record was left alone.

    Call it with -File, not -Command:

        powershell.exe -NoProfile -File DNS.SetSolarWindsRecordToActiveLB.v2.ps1 -ActiveServer 10.10.10.1

    A parameter that fails validation stops the script before it runs, and only
    -File turns that into exit code 1. Under -Command the caller reads a stale
    $LASTEXITCODE instead, so a typo in the arguments looks like a clean run.

    HealthyValue defaults to 0 because that is what the original script compared
    against. Confirm it against the devices before relying on this in
    production: if 0 does not in fact mean "up" on your load balancers, every
    decision the script makes is inverted.
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

    [ValidateNotNullOrEmpty()]
    [string] $PrimaryDcLoadBalancerIp = '10.10.10.10',

    [ValidateNotNullOrEmpty()]
    [string] $SecondaryDcLoadBalancerIp = '10.10.20.10',

    [ValidateNotNullOrEmpty()]
    [string] $PrimaryDcSnmpHost = '10.10.10.100',

    [ValidateNotNullOrEmpty()]
    [string] $SecondaryDcSnmpHost = '10.10.20.100',

    [string[]] $PrimaryDcWebServerOid = @(
        '.1.3.6.1.4.1.1872.2.5.4.2.19.1.10.2.52.52.1.2.57.51',
        '.1.3.6.1.4.1.1872.2.5.4.2.19.1.10.2.52.52.1.2.57.52'
    ),

    [string[]] $SecondaryDcWebServerOid = @(
        '.1.3.6.1.4.1.1872.2.5.4.2.19.1.10.2.51.57.1.2.51.54',
        '.1.3.6.1.4.1.1872.2.5.4.2.19.1.10.2.51.57.1.2.51.55'
    ),

    [ValidateNotNullOrEmpty()]
    [string] $SnmpCommunity = 'public',

    [int] $HealthyValue = 0,

    [ValidateRange(1, 10)]
    [int] $PollCount = 3,

    [ValidateRange(0, 60)]
    [int] $PollDelaySeconds = 5,

    [ValidateSet('Down', 'Unknown')]
    [string] $SnmpFailureMode = 'Down',

    [ValidateRange(0, 86400)]
    [int] $RecordTtlSeconds = 0,

    [string] $LogPath = (Join-Path -Path $env:ProgramData -ChildPath 'SolarWinds\dns-failover.log')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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

function Get-WebServerHealth {
    # Reads every OID once and reports how many web servers came back healthy.
    # Answered is false only when the load balancer gave us nothing at all,
    # which is what tells a dead data centre apart from a dead SNMP path.
    param(
        [Parameter(Mandatory)][string] $SnmpHost,
        [Parameter(Mandatory)][string[]] $Oid,
        [Parameter(Mandatory)][string] $Label
    )

    $snmp = $null
    $answered = 0
    $healthy = 0

    try {
        $snmp = New-Object -ComObject olePrn.oleSNMP
        $snmp.Open($SnmpHost, $SnmpCommunity, 2, 1000)

        foreach ($singleOid in $Oid) {
            try {
                $raw = ([string]$snmp.Get($singleOid)).Trim()
            }
            catch {
                Write-Log "$Label $singleOid could not be read: $($_.Exception.Message)" -Level WARN
                continue
            }

            $answered++

            $value = 0
            if (-not [int]::TryParse($raw, [ref]$value)) {
                Write-Log "$Label $singleOid returned '$raw', which is not a number. Counting it as down." -Level WARN
                continue
            }

            if ($value -eq $HealthyValue) {
                $healthy++
                Write-Log "$Label $singleOid = $value (up)."
            }
            else {
                Write-Log "$Label $singleOid = $value (down)." -Level WARN
            }
        }
    }
    catch {
        Write-Log "SNMP session to $Label ($SnmpHost) failed: $($_.Exception.Message)" -Level WARN
    }
    finally {
        if ($snmp) {
            try {
                $snmp.Close()
                [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($snmp)
            }
            catch {
                Write-Log "Releasing the SNMP session to $SnmpHost failed: $($_.Exception.Message)" -Level WARN
            }
        }
    }

    return [pscustomobject]@{
        Answered = ($answered -gt 0)
        Healthy  = $healthy
    }
}

function Get-DataCentreState {
    # Serving as soon as one poll finds a web server up, so a single bad reading
    # cannot move the record. Unknown when no poll got an answer at all.
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string] $SnmpHost,
        [Parameter(Mandatory)][string[]] $Oid,
        [Parameter(Mandatory)][string] $Label
    )

    $everAnswered = $false

    for ($attempt = 1; $attempt -le $PollCount; $attempt++) {
        Write-Log "Polling $Label on $SnmpHost, attempt $attempt of $PollCount."
        $health = Get-WebServerHealth -SnmpHost $SnmpHost -Oid $Oid -Label $Label

        if ($health.Answered) {
            $everAnswered = $true

            if ($health.Healthy -gt 0) {
                Write-Log "$Label has $($health.Healthy) web server(s) up."
                return 'Serving'
            }
        }

        if ($attempt -lt $PollCount -and $PollDelaySeconds -gt 0) {
            Start-Sleep -Seconds $PollDelaySeconds
        }
    }

    if (-not $everAnswered) {
        Write-Log "$Label did not answer any of the $PollCount SNMP polls." -Level WARN
        return 'Unknown'
    }

    Write-Log "$Label answered, and every web server is down." -Level WARN
    return 'Down'
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

    if ($ActiveServer -eq $PrimaryDcSolarWindsIp) {
        $localName      = 'PrimaryDC'
        $remoteName     = 'SecondaryDC'
        $snmpHost       = $PrimaryDcSnmpHost
        $oids           = $PrimaryDcWebServerOid
        $localLbIp      = $PrimaryDcLoadBalancerIp
        $remoteLbIp     = $SecondaryDcLoadBalancerIp
    }
    elseif ($ActiveServer -eq $SecondaryDcSolarWindsIp) {
        $localName      = 'SecondaryDC'
        $remoteName     = 'PrimaryDC'
        $snmpHost       = $SecondaryDcSnmpHost
        $oids           = $SecondaryDcWebServerOid
        $localLbIp      = $SecondaryDcLoadBalancerIp
        $remoteLbIp     = $PrimaryDcLoadBalancerIp
    }
    else {
        throw "ActiveServer '$ActiveServer' is neither the PrimaryDC SolarWinds server ($PrimaryDcSolarWindsIp) nor the SecondaryDC one ($SecondaryDcSolarWindsIp)."
    }

    Write-Log "Running for $localName."

    $dnsServerAddress = if ($DnsServer) { $DnsServer } else { Resolve-DnsServerAddress }

    $record = Get-SolarWindsRecord -Server $dnsServerAddress
    $currentIp = $record.RecordData.IPv4Address.IPAddressToString
    Write-Log "$RecordName.$ZoneName currently points at $currentIp with a TTL of $($record.TimeToLive)."

    $state = Get-DataCentreState -SnmpHost $snmpHost -Oid $oids -Label $localName

    if ($state -eq 'Unknown') {
        if ($SnmpFailureMode -eq 'Unknown') {
            Write-Log "$localName could not be reached over SNMP and SnmpFailureMode is 'Unknown', so the record is left at $currentIp." -Level ERROR
            exit 2
        }

        Write-Log "$localName could not be reached over SNMP. SnmpFailureMode is 'Down', so it is treated as a dead data centre." -Level WARN
        $state = 'Down'
    }

    if ($state -eq 'Serving') {
        $targetIp = $localLbIp
        $targetName = $localName
    }
    else {
        $targetIp = $remoteLbIp
        $targetName = $remoteName
    }

    if ($currentIp -eq $targetIp) {
        Write-Log "Nothing to do, the record already points at the $targetName load balancer ($targetIp)."
        exit 0
    }

    $target = "$RecordName.$ZoneName on $dnsServerAddress"
    $action = "Repoint from $currentIp to $targetIp, the $targetName load balancer"

    if (-not $PSCmdlet.ShouldProcess($target, $action)) {
        Write-Log "WhatIf: would have repointed $RecordName.$ZoneName from $currentIp to $targetIp ($targetName load balancer)."
        exit 0
    }

    Set-SolarWindsRecord -Server $dnsServerAddress -TargetIp $targetIp
    Write-Log "Repointed $RecordName.$ZoneName from $currentIp to $targetIp, the $targetName load balancer."
    exit 0
}
catch {
    Write-Log "Run failed: $($_.Exception.Message)" -Level ERROR
    Write-Log $_.ScriptStackTrace -Level ERROR
    Write-Error -Message $_.Exception.Message -ErrorAction Continue
    exit 1
}
