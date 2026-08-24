<#
    Redact-FileContent.ps1

    Unified replacement/redaction engine for files, recursively through subfolders.
    Combines two modes that share the same file-processing, dry-run and backup logic:

      1. Literal/regex replacements ($Replacements below) - always applied.
         Each key is a regex pattern, each value is what to replace it with.
         (Companion to Search-FilesForWord.ps1 - use that one first to preview matches.)

      2. Switch/device name anonymization (-Anonymize) - optional, applied in the
         same pass. Finds whitespace-delimited tokens that start with "S"/"s" and end
         with "nn" (letters, digits, and special characters allowed in between, e.g.
         S-DC1-01nn) and replaces each one with a sequential generic placeholder
         (SWITCH001, SWITCH002, ...). The same original name always maps to the same
         placeholder within a single run, but the mapping is NOT persisted between
         runs - running the script again assigns fresh numbers.

    Both modes support -DryRun (report what would change, touch nothing) and -Backup
    (copy each modified file's original content aside before overwriting it).

    USAGE EXAMPLES:

        # Preview the literal replacements only, no files modified
        .\Redact-FileContent.ps1 -Path "D:\" -DryRun

        # Apply literal replacements for real, keeping backups
        .\Redact-FileContent.ps1 -Path "D:\" -Backup

        # Also anonymize switch names in the same pass
        .\Redact-FileContent.ps1 -Path "D:\" -Anonymize -Backup

        # Anonymize only - skip the literal $Replacements table
        .\Redact-FileContent.ps1 -Path "D:\" -Anonymize -Replacements @{} -DryRun

        # Limit to specific file types
        .\Redact-FileContent.ps1 -Path "D:\Logs" -Include *.log,*.txt -Anonymize -DryRun
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    # Root folder to process. Defaults to the current directory.
    [string]$Path = ".",

    # Optional file name filters (wildcards), e.g. *.txt, *.log, *.csv.
    # Leave empty to process every file.
    [string[]]$Include = @("*"),

    # Ordered map of regex pattern -> replacement text, applied on every line.
    [System.Collections.Specialized.OrderedDictionary]$Replacements = [ordered]@{
        "ass" = "aaa"
    },

    # Also anonymize switch/device name tokens matching -AnonymizePattern.
    [switch]$Anonymize,

    # Regex matching one switch/device name token (used only with -Anonymize).
    [string]$AnonymizePattern = '(?<!\S)[Ss][^\s]*nn(?!\S)',

    # Prefix used for the generic anonymized names (SWITCH001, SWITCH002, ...).
    [string]$AnonymizeNamePrefix = "SWITCH",

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
$anonymizeRegex = [regex]::new($AnonymizePattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)

# Original switch name (as first encountered) -> generic placeholder. Consistent for this run only.
$nameMap = [ordered]@{}
$nextIndex = 1

function Get-PlaceholderName {
    param([string]$OriginalName)

    if (-not $nameMap.Contains($OriginalName)) {
        $nameMap[$OriginalName] = "{0}{1:D3}" -f $AnonymizeNamePrefix, $script:nextIndex
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
        $currentRow = $row

        foreach ($search in $Replacements.Keys) {
            $lineMatches = [regex]::Matches($currentRow, $search).Count
            if ($lineMatches -gt 0) {
                $fileMatchCount += $lineMatches
                $currentRow = $currentRow -replace $search, $Replacements[$search]
            }
        }

        if ($Anonymize) {
            $currentRow = $anonymizeRegex.Replace($currentRow, {
                param($match)
                $script:fileMatchCount++
                Get-PlaceholderName -OriginalName $match.Value
            })
        }

        $currentRow
    }

    if ($fileMatchCount -eq 0) {
        continue
    }

    $changedCount++

    if ($DryRun) {
        Write-Host "[DryRun] Would update: $($fileItem.FullName) ($fileMatchCount match(es))" -ForegroundColor DarkYellow
        continue
    }

    if (-not $PSCmdlet.ShouldProcess($fileItem.FullName, "Replace $fileMatchCount match(es)")) {
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

if ($Anonymize -and $nameMap.Count -gt 0) {
    Write-Host "`nSwitch name mapping for this run:" -ForegroundColor Cyan
    $nameMap.GetEnumerator() | ForEach-Object {
        Write-Host ("  {0}  ->  {1}" -f $_.Key, $_.Value)
    }
}
