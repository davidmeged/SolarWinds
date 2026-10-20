# This script removes the domain name from the Caption (display name) of nodes in SolarWinds Orion.
#
# Changes only the Caption, e.g. "SRV01.corp.local" -> "SRV01" or "CORP\SRV01" -> "SRV01".
# DNS, SysName and IP address are left untouched. Captions that are IP addresses are skipped.
# Every change (old and new value) is written to a CSV log, which can be used to roll back.
#
# Edit the settings below and run the whole script (F5 in PowerShell ISE / VS Code).
# Keep $DryRun = $true for the first run to see what would change without changing anything.

# === Settings ===
$OrionServer    = "localhost"   # Orion server name (localhost when running on the Orion server itself)
$UseWindowsAuth = $true         # $true = current Windows user, $false = prompt for Orion username/password
$Domain         = ""            # e.g. "corp.local" to strip only this domain. Empty = remove everything after the first dot
$DryRun         = $true         # $true = only show what would change, $false = apply the changes
$LogPath        = "$env:USERPROFILE\Desktop\OrionCaptionChanges_$(Get-Date -Format yyyyMMdd_HHmmss).csv"

# --- Load module ---
if (-not (Get-Module -ListAvailable -Name SwisPowerShell)) {
    Write-Host "Installing SwisPowerShell module..." -ForegroundColor Yellow
    Install-Module -Name SwisPowerShell -Scope CurrentUser -Force
}
Import-Module SwisPowerShell

# --- Connect to SWIS ---
if ($UseWindowsAuth) {
    $swis = Connect-Swis -Hostname $OrionServer -Trusted
}
else {
    $cred = Get-Credential -Message "Orion credentials"
    $swis = Connect-Swis -Hostname $OrionServer -Credential $cred
}
if (-not $swis) { throw "Could not connect to SWIS on '$OrionServer'." }

# --- Get nodes whose Caption contains a dot or a backslash ---
$query = @"
SELECT NodeID, Caption, IPAddress, Uri
FROM Orion.Nodes
WHERE Caption LIKE '%.%' OR Caption LIKE '%\%'
"@
$nodes = Get-SwisData -SwisConnection $swis -Query $query

$ipv4Regex = '^\d{1,3}(\.\d{1,3}){3}$'

$results = foreach ($node in $nodes) {
    $oldCaption = "$($node.Caption)".Trim()
    if (-not $oldCaption) { continue }
    $newCaption = $oldCaption

    # Skip captions that are IP addresses
    if ($oldCaption -match $ipv4Regex -or $oldCaption -match ':') { continue }

    # DOMAIN\Server format
    if ($newCaption.Contains('\')) {
        $newCaption = $newCaption.Split('\')[-1]
    }

    # FQDN format - server.domain.com
    if ($Domain) {
        $suffix = ".$Domain"
        if ($newCaption.EndsWith($suffix, [StringComparison]::OrdinalIgnoreCase)) {
            $newCaption = $newCaption.Substring(0, $newCaption.Length - $suffix.Length)
        }
    }
    else {
        $newCaption = $newCaption.Split('.')[0]
    }

    if ([string]::IsNullOrWhiteSpace($newCaption) -or $newCaption -eq $oldCaption) { continue }

    if ($DryRun) {
        $status = 'DryRun'
        Write-Host "[DRY]  $oldCaption -> $newCaption" -ForegroundColor Yellow
    }
    else {
        try {
            Set-SwisObject -SwisConnection $swis -Uri $node.Uri -Properties @{ Caption = $newCaption }
            $status = 'Updated'
            Write-Host "[OK]   $oldCaption -> $newCaption" -ForegroundColor Green
        }
        catch {
            $status = "Error: $($_.Exception.Message)"
            Write-Host "[FAIL] $oldCaption : $($_.Exception.Message)" -ForegroundColor Red
        }
    }

    [pscustomobject]@{
        NodeID     = $node.NodeID
        IPAddress  = $node.IPAddress
        OldCaption = $oldCaption
        NewCaption = $newCaption
        Status     = $status
    }
}

# --- Summary and log ---
if ($results) {
    $results | Export-Csv -Path $LogPath -NoTypeInformation -Encoding UTF8
    $results | Format-Table -AutoSize
    Write-Host "`nTotal: $(@($results).Count) nodes. Log saved to: $LogPath" -ForegroundColor Cyan
    if ($DryRun) { Write-Host "Dry run - nothing was changed. Set `$DryRun = `$false to apply." -ForegroundColor Yellow }
}
else {
    Write-Host "No nodes found that need changes." -ForegroundColor Cyan
}
