<#
    Replace-WordInFiles.ps1

    Searches for text inside files, recursively through subfolders, and replaces it.
    Companion script to Search-FilesForWord.ps1 - use that one first to see what would
    match before running a replacement.

    Supports multiple search/replace pairs in one pass (via $Replacements below),
    a -DryRun mode that reports what would change without touching any file, and an
    optional -Backup switch that copies each modified file's original content aside
    before it is overwritten.

    USAGE EXAMPLES:

        # Preview what would change, no files are modified
        .\Replace-WordInFiles.ps1 -Path "D:\" -DryRun

        # Replace for real, keeping a backup copy of every changed file
        .\Replace-WordInFiles.ps1 -Path "D:\" -Backup

        # Limit to specific file types
        .\Replace-WordInFiles.ps1 -Path "D:\Logs" -Include *.log,*.txt,*.csv -DryRun

        # Choose where backups go (default: a timestamped folder next to -Path)
        .\Replace-WordInFiles.ps1 -Path "D:\" -Backup -BackupFolder "D:\_backup"
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    # Root folder to process. Defaults to the current directory.
    [string]$Path = ".",

    # Optional file name filters (wildcards), e.g. *.txt, *.log, *.csv.
    # Leave empty to process every file.
    [string[]]$Include = @("*"),

    # Report matches and what would change, without modifying any file.
    [switch]$DryRun,

    # Copy each file's original content into -BackupFolder before overwriting it.
    [switch]$Backup,

    # Folder to hold backups when -Backup is used. Defaults to a timestamped
    # folder created next to -Path. Relative structure under -Path is preserved.
    [string]$BackupFolder
)

# Ordered so replacements are applied in a predictable sequence.
$replacements = [ordered]@{
    "ass" = "aaa"
}

if (-not (Test-Path -LiteralPath $Path)) {
    Write-Error "Path not found: $Path"
    return
}

if ($Backup -and -not $BackupFolder) {
    $BackupFolder = Join-Path (Resolve-Path -LiteralPath $Path) "_backup_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
}

$resolvedRoot = (Resolve-Path -LiteralPath $Path).ProviderPath
$allFiles = Get-ChildItem -Path $Path -Include $Include -Recurse -File -ErrorAction SilentlyContinue

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
        foreach ($search in $replacements.Keys) {
            $lineMatches = [regex]::Matches($currentRow, $search).Count
            if ($lineMatches -gt 0) {
                $fileMatchCount += $lineMatches
                $currentRow = $currentRow -replace $search, $replacements[$search]
            }
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
