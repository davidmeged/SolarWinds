<#
    Anonymize-SwitchNames.ps1

    Finds switch/device names inside files (recursively) and replaces each one with a
    generic, sequential placeholder name (SWITCH001, SWITCH002, ...). The same original
    name always maps to the same placeholder within a single run of this script, so
    relationships between mentions of the same switch are preserved in the output.

    NOTE: the mapping is NOT persisted between runs - running the script again (even on
    the same files) will assign fresh SWITCH### numbers. If you need the same name to
    always get the same placeholder across separate runs, that requires saving the
    mapping to a file; ask for that if you need it.

    Default naming pattern matched: a whitespace-delimited token that starts with
    "S"/"s" and ends with "nn" (letters, digits, and special characters allowed in
    between), e.g. S-DC1-01nn, sBuilding_07nn.

    USAGE EXAMPLES:

        # Preview what would be replaced, no files are modified
        .\Anonymize-SwitchNames.ps1 -Path "D:\" -DryRun

        # Replace for real, keeping a backup copy of every changed file
        .\Anonymize-SwitchNames.ps1 -Path "D:\" -Backup

        # Limit to specific file types, use a custom pattern
        .\Anonymize-SwitchNames.ps1 -Path "D:\Logs" -Include *.log,*.txt -Pattern '(?<!\S)[Ss][^\s]*nn(?!\S)'
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    # Root folder to process. Defaults to the current directory.
    [string]$Path = ".",

    # Optional file name filters (wildcards), e.g. *.txt, *.log, *.csv.
    # Leave empty to process every file.
    [string[]]$Include = @("*"),

    # Regex matching one switch/device name token. Must be a single capture-free
    # pattern; matches are whitespace-delimited by default.
    [string]$Pattern = '(?<!\S)[Ss][^\s]*nn(?!\S)',

    # Prefix used for the generic replacement names (SWITCH001, SWITCH002, ...).
    [string]$NamePrefix = "SWITCH",

    # Report matches and what would change, without modifying any file.
    [switch]$DryRun,

    # Copy each file's original content into -BackupFolder before overwriting it.
    [switch]$Backup,

    # Folder to hold backups when -Backup is used. Defaults to a timestamped
    # folder created next to -Path. Relative structure under -Path is preserved.
    [string]$BackupFolder
)

if (-not (Test-Path -LiteralPath $Path)) {
    Write-Error "Path not found: $Path"
    return
}

if ($Backup -and -not $BackupFolder) {
    $BackupFolder = Join-Path (Resolve-Path -LiteralPath $Path) "_backup_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
}

$resolvedRoot = (Resolve-Path -LiteralPath $Path).ProviderPath
$allFiles = Get-ChildItem -Path $Path -Include $Include -Recurse -File -ErrorAction SilentlyContinue
$regex = [regex]::new($Pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)

# Original name (as first encountered) -> generic placeholder. Consistent for this run only.
$nameMap = [ordered]@{}
$nextIndex = 1

function Get-PlaceholderName {
    param([string]$OriginalName)

    if (-not $nameMap.Contains($OriginalName)) {
        $nameMap[$OriginalName] = "{0}{1:D3}" -f $NamePrefix, $script:nextIndex
        $script:nextIndex++
    }
    return $nameMap[$OriginalName]
}

$changedCount = 0
$scannedCount = 0

foreach ($fileItem in $allFiles) {
    $scannedCount++

    $content = Get-Content -LiteralPath $fileItem.FullName -ErrorAction SilentlyContinue
    if ($null -eq $content) {
        continue
    }

    $fileMatchCount = 0
    $updatedContent = foreach ($row in $content) {
        $regex.Replace($row, {
            param($match)
            $script:fileMatchCount++
            Get-PlaceholderName -OriginalName $match.Value
        })
    }

    if ($fileMatchCount -eq 0) {
        continue
    }

    $changedCount++

    if ($DryRun) {
        Write-Host "[DryRun] Would update: $($fileItem.FullName) ($fileMatchCount match(es))" -ForegroundColor DarkYellow
        continue
    }

    if (-not $PSCmdlet.ShouldProcess($fileItem.FullName, "Anonymize $fileMatchCount switch name(s)")) {
        continue
    }

    if ($Backup) {
        $relativePath = $fileItem.FullName.Substring($resolvedRoot.Length).TrimStart('\', '/')
        $backupPath = Join-Path $BackupFolder $relativePath
        $backupDir = Split-Path -Path $backupPath -Parent
        if (-not (Test-Path -LiteralPath $backupDir)) {
            New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
        }
        Copy-Item -LiteralPath $fileItem.FullName -Destination $backupPath -Force
    }

    Write-Host "Working on: $($fileItem.FullName) ($fileMatchCount match(es))" -ForegroundColor DarkYellow
    $updatedContent | Set-Content -LiteralPath $fileItem.FullName
}

Write-Host ""
if ($DryRun) {
    Write-Host "Dry run complete. $changedCount of $scannedCount file(s) would be updated." -ForegroundColor Green
} else {
    Write-Host "Complete successfully! $changedCount of $scannedCount file(s) updated." -ForegroundColor Green
    if ($Backup) {
        Write-Host "Backups saved under: $BackupFolder" -ForegroundColor Green
    }
}

if ($nameMap.Count -gt 0) {
    Write-Host "`nName mapping for this run:" -ForegroundColor Cyan
    $nameMap.GetEnumerator() | ForEach-Object {
        Write-Host ("  {0}  ->  {1}" -f $_.Key, $_.Value)
    }
}
