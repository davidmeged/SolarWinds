<#
.SYNOPSIS
    Removes the domain name from the Caption (display name) of nodes in SolarWinds Orion.

.DESCRIPTION
    Changes only the Caption, e.g. "SRV01.corp.local" -> "SRV01" or "CORP\SRV01" -> "SRV01".
    DNS, SysName and IP address are left untouched. Captions that are IP addresses are skipped.
    Every change (old and new value) is written to a CSV log, which can be used to roll back.

.EXAMPLE
    # Dry run - shows what would change without changing anything
    .\CRUD.RemoveDomainFromNodeCaption.ps1 -OrionServer orion01 -WhatIf

.EXAMPLE
    # Strip only a specific domain, connecting as the current Windows user
    .\CRUD.RemoveDomainFromNodeCaption.ps1 -OrionServer orion01 -Domain corp.local -Trusted
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string]$OrionServer,

    # Optional: strip only this domain (e.g. corp.local). Without it, everything after the first dot is removed
    [string]$Domain,

    [pscredential]$Credential,

    # Connect as the current Windows user
    [switch]$Trusted,

    [string]$LogPath = ".\OrionCaptionChanges_$(Get-Date -Format yyyyMMdd_HHmmss).csv"
)

# --- Load module ---
if (-not (Get-Module -ListAvailable -Name SwisPowerShell)) {
    Write-Host "Installing SwisPowerShell module..." -ForegroundColor Yellow
    Install-Module -Name SwisPowerShell -Scope CurrentUser -Force
}
Import-Module SwisPowerShell

# --- Connect to SWIS ---
if ($Trusted) {
    $swis = Connect-Swis -Hostname $OrionServer -Trusted
}
else {
    if (-not $Credential) { $Credential = Get-Credential -Message "Orion credentials" }
    $swis = Connect-Swis -Hostname $OrionServer -Credential $Credential
}

# --- Get nodes whose Caption contains a dot or a backslash ---
$query = @"
SELECT NodeID, Caption, IPAddress, Uri
FROM Orion.Nodes
WHERE Caption LIKE '%.%' OR Caption LIKE '%\%'
"@
$nodes = Get-SwisData -SwisConnection $swis -Query $query

$ipv4Regex = '^\d{1,3}(\.\d{1,3}){3}$'

$results = foreach ($node in $nodes) {
    $oldCaption = $node.Caption.Trim()
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

    $status = 'Skipped (WhatIf)'
    if ($PSCmdlet.ShouldProcess("NodeID $($node.NodeID)", "Rename '$oldCaption' -> '$newCaption'")) {
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
}
else {
    Write-Host "No nodes found that need changes." -ForegroundColor Cyan
}
