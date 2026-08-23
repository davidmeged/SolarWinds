<#
    Search-FilesForWord.ps1

    Searches for a word/text fragment inside files, recursively through subfolders.
    The search is a plain substring match (not "whole word"), so it will also match
    the term when it appears inside another word or combined with hyphens/underscores,
    e.g. searching for "server" will also match "fileserver", "server-01", "my_server", etc.

    USAGE EXAMPLES:

        # Search for "server-01" under the current folder, in all files
        .\Search-FilesForWord.ps1 -SearchTerm "server-01"

        # Search under a specific folder
        .\Search-FilesForWord.ps1 -SearchTerm "server-01" -Path "C:\Logs"

        # Limit the search to specific file types
        .\Search-FilesForWord.ps1 -SearchTerm "server-01" -Path "C:\Logs" -Include *.log,*.txt,*.csv

        # Case-sensitive search
        .\Search-FilesForWord.ps1 -SearchTerm "Server-01" -CaseSensitive
#>

[CmdletBinding()]
param(
    # The word / text fragment to search for. Matches as a substring, so hyphens and
    # partial-word matches (e.g. inside "fileserver-01") are found as-is.
    [Parameter(Mandatory = $true)]
    [string]$SearchTerm,

    # Root folder to search from. Defaults to the current directory.
    [string]$Path = ".",

    # Optional file name filters (wildcards), e.g. *.txt, *.log, *.csv.
    # Leave empty to search every file.
    [string[]]$Include = @("*"),

    # Perform a case-sensitive search. By default the search is case-insensitive.
    [switch]$CaseSensitive
)

if (-not (Test-Path -LiteralPath $Path)) {
    Write-Error "Path not found: $Path"
    return
}

$files = Get-ChildItem -Path $Path -Include $Include -Recurse -File -ErrorAction SilentlyContinue

$results = foreach ($file in $files) {
    $selectStringParams = @{
        Path        = $file.FullName
        Pattern     = $SearchTerm
        SimpleMatch = $true
        ErrorAction = "SilentlyContinue"
    }
    if ($CaseSensitive) {
        $selectStringParams["CaseSensitive"] = $true
    }

    Select-String @selectStringParams
}

if (-not $results) {
    Write-Host "No matches found for '$SearchTerm' under '$Path'."
    return
}

$results |
    Select-Object @{Name = "File"; Expression = { $_.Path } },
                   @{Name = "Line"; Expression = { $_.LineNumber } },
                   @{Name = "Text"; Expression = { $_.Line.Trim() } } |
    Format-Table -AutoSize -Wrap

Write-Host "`nTotal matches: $($results.Count)"
