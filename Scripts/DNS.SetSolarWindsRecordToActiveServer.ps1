#Requires -Version 5.1

<#
.SYNOPSIS
    Points the SolarWinds DNS record at whichever SolarWinds server is currently
    the active one. No load balancer and no web servers are involved.

.DESCRIPTION
    This is the Alteon-free variant of DNS.SetSolarWindsRecordToActiveLB.v2.ps1.
    Where that script asks a Radware load balancer over SNMP how the web servers
    behind it are doing, this one asks a simpler question: which SolarWinds
    server is active right now? The record then follows that answer.

    The active server is found in one of three ways, chosen with
    -DetectionMethod:

      Ha      Ask SolarWinds itself, over SWIS, which member of the High
              Availability pool is active. This is the only method that can tell
              an active server from a standby one that is merely switched on.

      Probe   Open a TCP connection to each SolarWinds server in turn and treat
              the first one that accepts as active, -PreferredDc first. Needs no
              credentials and no SWIS, but it reports reachability, not role: in
              an HA pair where both servers answer, it always names the
              preferred one.

      Manual  Use the address passed in -ActiveServer, the way the alert action
              already calls the original script.

    Nothing is written when the record already holds the wanted address, so the
    script is safe to run on a schedule.

.PARAMETER DetectionMethod
    How to find the active server: Ha, Probe or Manual. See the description.

.PARAMETER HaQuery
    The SWQL the Ha method runs. It has to return one row per ACTIVE member,
    with a column named IPAddress. The default is written against the HA pool
    entities, but SWIS schemas differ between Orion versions, so verify it with
    SolarWinds' own SWQL Studio before relying on it. A query that returns no
    rows, several rows, or no IPAddress column stops the run with an error that
    says which of the three happened.

.PARAMETER PrimaryDcTargetIp
    The address written to the record when PrimaryDC is the active side. It
    defaults to the PrimaryDC SolarWinds server itself, so out of the box the
    record points straight at the server and no load balancer is in the path.
    If a load balancer does still front SolarWinds, pass its VIP here instead;
    the script neither knows nor cares what kind of device answers.

.PARAMETER ProbePort
    The TCP port the Probe method opens. The default, 17778, is the SolarWinds
    Information Service port.

.EXAMPLE
    .\DNS.SetSolarWindsRecordToActiveServer.ps1 -DetectionMethod Probe -WhatIf

    Shows which server would be picked, and what would change, without touching
    DNS and without needing SWIS credentials.

.EXAMPLE
    .\DNS.SetSolarWindsRecordToActiveServer.ps1 -SwisHost 10.10.10.1 -SwisCredential $cred

    Asks the SolarWinds HA pool which member is active and repoints the record.

.EXAMPLE
    .\DNS.SetSolarWindsRecordToActiveServer.ps1 -DetectionMethod Manual -ActiveServer 10.10.20.1

.NOTES
    Exit codes: 0 done (changed or nothing to change), 1 failed, 2 the active
    server could not be determined and the record was left alone.

    Call it with -File, not -Command:

        powershell.exe -NoProfile -File DNS.SetSolarWindsRecordToActiveServer.ps1 -DetectionMethod Probe

    A parameter that fails validation stops the script before it runs, and only
    -File turns that into exit code 1. Under -Command the caller reads a stale
    $LASTEXITCODE instead, so a typo in the arguments looks like a clean run.

    The Ha method needs the SwisPowerShell module, the same one the other
    scripts in this repository use.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet('Ha', 'Probe', 'Manual')]
    [string] $DetectionMethod = 'Ha',

    [string] $ActiveServer,

    [string] $SwisHost,

    [pscredential] $SwisCredential,

    [ValidateNotNullOrEmpty()]
    [string] $HaQuery = @'
SELECT m.IPAddress AS IPAddress
FROM Orion.HA.PoolMembers m
WHERE m.IsActive = 1
'@,

    [ValidateRange(1, 65535)]
    [int] $ProbePort = 17778,

    [ValidateRange(100, 30000)]
    [int] $ProbeTimeoutMs = 3000,

    [ValidateSet('PrimaryDC', 'SecondaryDC')]
    [string] $PreferredDc = 'PrimaryDC',

    [ValidateNotNullOrEmpty()]
    [string] $PrimaryDcSolarWindsIp = '10.10.10.1',

    [ValidateNotNullOrEmpty()]
    [string] $SecondaryDcSolarWindsIp = '10.10.20.1',

    [ValidateNotNullOrEmpty()]
    [string] $PrimaryDcTargetIp = $PrimaryDcSolarWindsIp,

    [ValidateNotNullOrEmpty()]
    [string] $SecondaryDcTargetIp = $SecondaryDcSolarWindsIp,

    [ValidateNotNullOrEmpty()]
    [string] $RecordName = 'OurSolar',

    [ValidateNotNullOrEmpty()]
    [string] $ZoneName = 'OurZone',

    [string] $DnsServer,

    [ValidateRange(1, 10)]
    [int] $AttemptCount = 3,

    [ValidateRange(0, 60)]
    [int] $AttemptDelaySeconds = 5,

    [ValidateRange(0, 86400)]
    [int] $RecordTtlSeconds = 0,

    [string] $LogPath = (Join-Path -Path $env:ProgramData -ChildPath 'SolarWinds\dns-active-server.log')
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

function Test-TcpPort {
    # A plain TCP connect with a timeout. Test-NetConnection would do the same
    # job but takes seconds per call and cannot be told to give up early.
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string] $ComputerName,
        [Parameter(Mandatory)][int] $Port,
        [Parameter(Mandatory)][int] $TimeoutMs
    )

    $client = $null
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $async = $client.BeginConnect($ComputerName, $Port, $null, $null)

        if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) {
            return $false
        }

        $client.EndConnect($async)
        return $true
    }
    catch {
        return $false
    }
    finally {
        if ($client) {
            try { $client.Close() } catch { }
        }
    }
}

function Get-ActiveServerByProbe {
    # Reports which SolarWinds server is REACHABLE, which is not the same as
    # which one is active. In an HA pair both members usually accept
    # connections, so the preferred side always wins here. Use the Ha method
    # when the difference matters.
    [OutputType([string])]
    param()

    $order = if ($PreferredDc -eq 'PrimaryDC') {
        @(@{ Name = 'PrimaryDC'; Ip = $PrimaryDcSolarWindsIp },
          @{ Name = 'SecondaryDC'; Ip = $SecondaryDcSolarWindsIp })
    }
    else {
        @(@{ Name = 'SecondaryDC'; Ip = $SecondaryDcSolarWindsIp },
          @{ Name = 'PrimaryDC'; Ip = $PrimaryDcSolarWindsIp })
    }

    foreach ($candidate in $order) {
        Write-Log "Probing the $($candidate.Name) SolarWinds server at $($candidate.Ip) on TCP $ProbePort."

        if (Test-TcpPort -ComputerName $candidate.Ip -Port $ProbePort -TimeoutMs $ProbeTimeoutMs) {
            Write-Log "$($candidate.Name) at $($candidate.Ip) accepted the connection."
            return [string]$candidate.Ip
        }

        Write-Log "$($candidate.Name) at $($candidate.Ip) did not accept a connection." -Level WARN
    }

    return $null
}

function Get-ActiveServerFromHa {
    # Asks SolarWinds which HA pool member is active. The query is a parameter
    # because the HA entities differ between Orion versions; every way it can
    # come back wrong is reported as its own message rather than as a crash.
    [OutputType([string])]
    param()

    if (-not (Get-Module -ListAvailable -Name SwisPowerShell)) {
        throw 'The SwisPowerShell module is not installed, so -DetectionMethod Ha cannot run. Install it, or use -DetectionMethod Probe.'
    }

    Import-Module SwisPowerShell -ErrorAction Stop

    $target = if ($SwisHost) { $SwisHost } else { $PrimaryDcSolarWindsIp }
    Write-Log "Asking SolarWinds at $target which HA pool member is active."

    $connection = if ($SwisCredential) {
        Connect-Swis -Host $target -Credential $SwisCredential
    }
    else {
        Connect-Swis -Host $target -Trusted
    }

    $rows = @(Get-SwisData -SwisConnection $connection -Query $HaQuery)

    if ($rows.Count -eq 0) {
        throw "The HA query returned no active pool member. Either no HA pool is active, or -HaQuery does not match this Orion version's schema."
    }

    if ($rows.Count -gt 1) {
        throw "The HA query returned $($rows.Count) active pool members. Exactly one was expected, so -HaQuery needs narrowing before it can decide anything."
    }

    $row = $rows[0]

    if ($row.PSObject.Properties.Name -notcontains 'IPAddress') {
        $columns = ($row.PSObject.Properties.Name) -join ', '
        throw "The HA query returned no IPAddress column. It returned: $columns. Alias the address column AS IPAddress in -HaQuery."
    }

    $address = [string]$row.IPAddress

    if ([string]::IsNullOrWhiteSpace($address)) {
        throw 'The HA query returned an active pool member whose IPAddress is empty.'
    }

    Write-Log "SolarWinds reports the active HA pool member as $address."
    return $address
}

function Get-ActiveServer {
    # Retries the detection, so one bad moment on the network cannot move a DNS
    # record on its own. Manual needs no retry: the answer was passed in.
    [OutputType([string])]
    param()

    if ($DetectionMethod -eq 'Manual') {
        if ([string]::IsNullOrWhiteSpace($ActiveServer)) {
            throw '-DetectionMethod Manual needs -ActiveServer to name the active SolarWinds server.'
        }

        Write-Log "Using the active server passed in: $ActiveServer."
        return $ActiveServer
    }

    for ($attempt = 1; $attempt -le $AttemptCount; $attempt++) {
        Write-Log "Detecting the active SolarWinds server with the $DetectionMethod method, attempt $attempt of $AttemptCount."

        try {
            $found = if ($DetectionMethod -eq 'Ha') { Get-ActiveServerFromHa } else { Get-ActiveServerByProbe }
            if ($found) { return $found }
        }
        catch {
            Write-Log "Attempt $attempt failed: $($_.Exception.Message)" -Level WARN
        }

        if ($attempt -lt $AttemptCount -and $AttemptDelaySeconds -gt 0) {
            Start-Sleep -Seconds $AttemptDelaySeconds
        }
    }

    return $null
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
    Write-Log "===== Run started, detection method $DetectionMethod ====="

    $activeIp = Get-ActiveServer

    if (-not $activeIp) {
        Write-Log "The active SolarWinds server could not be determined after $AttemptCount attempt(s). The record is left as it is." -Level ERROR
        exit 2
    }

    if ($activeIp -eq $PrimaryDcSolarWindsIp) {
        $activeName = 'PrimaryDC'
        $targetIp = $PrimaryDcTargetIp
    }
    elseif ($activeIp -eq $SecondaryDcSolarWindsIp) {
        $activeName = 'SecondaryDC'
        $targetIp = $SecondaryDcTargetIp
    }
    else {
        throw "The active server was found to be $activeIp, which is neither the PrimaryDC SolarWinds server ($PrimaryDcSolarWindsIp) nor the SecondaryDC one ($SecondaryDcSolarWindsIp)."
    }

    Write-Log "$activeName is active, so the record should point at $targetIp."

    $dnsServerAddress = if ($DnsServer) { $DnsServer } else { Resolve-DnsServerAddress }

    $record = Get-SolarWindsRecord -Server $dnsServerAddress
    $currentIp = $record.RecordData.IPv4Address.IPAddressToString
    Write-Log "$RecordName.$ZoneName currently points at $currentIp with a TTL of $($record.TimeToLive)."

    if ($currentIp -eq $targetIp) {
        Write-Log "Nothing to do, the record already points at the $activeName target ($targetIp)."
        exit 0
    }

    $target = "$RecordName.$ZoneName on $dnsServerAddress"
    $action = "Repoint from $currentIp to $targetIp, the $activeName target"

    if (-not $PSCmdlet.ShouldProcess($target, $action)) {
        Write-Log "WhatIf: would have repointed $RecordName.$ZoneName from $currentIp to $targetIp ($activeName target)."
        exit 0
    }

    Set-SolarWindsRecord -Server $dnsServerAddress -TargetIp $targetIp
    Write-Log "Repointed $RecordName.$ZoneName from $currentIp to $targetIp, the $activeName target."
    exit 0
}
catch {
    Write-Log "Run failed: $($_.Exception.Message)" -Level ERROR
    Write-Log $_.ScriptStackTrace -Level ERROR
    Write-Error -Message $_.Exception.Message -ErrorAction Continue
    exit 1
}
