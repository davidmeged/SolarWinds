<#
    פתרונות לתרגילים בקובץ Exercises.md
    הקובץ לא נועד לרוץ מתחילה עד סוף – הריצו כל פתרון בנפרד (בחירה + F8 ב-VS Code / ISE).
    כל הפתרונות מניחים שאתם בתיקיית העבודה C:\PSLab
#>

return   # הגנה מהרצה בטעות של כל הקובץ

Set-Location C:\PSLab

#region ===================== פרק 1 – פקודות בסיסיות ופרמטרים =====================

#region 1.1 Verb-Noun
(Get-Verb).Count
Get-Command -Noun Service
Get-Command -Verb Get -Noun *Process*
#endregion

#region 1.2 Help
Get-Help Get-ChildItem
Get-Help Get-ChildItem -Examples
Get-Help Get-ChildItem -Parameter Filter
Get-Help about_Parameters          # בפעם הראשונה אולי צריך: Update-Help
Get-Help about_* | Where-Object Name -like '*Parameters*'
#endregion

#region 1.3 Aliases
Get-Alias ls, dir, cd, cat, '?', '%'
Get-Alias -Definition Get-ChildItem
Set-Alias -Name np -Value notepad.exe
np
#endregion

#region 1.4 סוגי פרמטרים
# Named
Get-ChildItem -Path C:\Windows
Get-WinEvent -LogName System -MaxEvents 5
Get-EventLog -LogName System -Newest 5        # Windows PowerShell 5.1 בלבד
# Positional
Get-ChildItem C:\Windows
Get-EventLog System -Newest 5                  # LogName הוא Position 0

# Switch
Get-ChildItem C:\Windows -Directory
Get-ChildItem C:\Windows -File -Force          # Force מציג גם מוסתרים

Get-Help Get-ChildItem -Parameter Path
# Required? false | Position? 0 | Accept pipeline input? true (ByValue, ByPropertyName)
#endregion

#region 1.5 Common Parameters
'a.txt', 'b.txt', 'c.txt' | ForEach-Object { New-Item -Path $_ -ItemType File -Force }

Remove-Item *.txt -WhatIf                       # רק מדפיס מה היה קורה – שום דבר לא נמחק
Remove-Item a.txt -Confirm

Get-Content nothing.txt -ErrorAction SilentlyContinue
Get-Content nothing.txt -ErrorAction SilentlyContinue -ErrorVariable myErr
$myErr
$myErr[0].Exception.Message

Copy-Item b.txt b2.txt -Verbose
#endregion

#region 1.6 Parameter Sets
Get-Command Get-Process -Syntax                 # כל שורה = Parameter Set
(Get-Command Get-Process).ParameterSets.Count

Get-Process -Name explorer -Id 4
# נכשל: Name ו-Id שייכים ל-Parameter Sets שונים – אי אפשר לשלב ביניהם

Get-Process -Id $PID
#endregion

#region 1.7 Splatting
$params = @{
    Path   = 'C:\Windows'
    Filter = '*.exe'
    File   = $true
}
Get-ChildItem @params

$params.ErrorAction = 'SilentlyContinue'
$params.Recurse     = $true
Get-ChildItem @params
#endregion

#region 1.8 תרגיל מסכם – Get-BigFile
function Get-BigFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateScript({ Test-Path -Path $_ -PathType Container })]
        [string]$Path,

        [ValidateRange(1, 10000)]
        [int]$MinSizeMB = 10,

        [ValidateSet('.log', '.txt', '.zip', '.iso')]
        [string]$Extension,

        [switch]$Recurse
    )

    $gciParams = @{
        Path        = $Path
        File        = $true
        Recurse     = $Recurse
        ErrorAction = 'SilentlyContinue'
    }
    if ($Extension) { $gciParams.Filter = "*$Extension" }

    $files = Get-ChildItem @gciParams | Where-Object Length -ge ($MinSizeMB * 1MB)
    Write-Verbose "נמצאו $(@($files).Count) קבצים גדולים מ-$MinSizeMB MB"

    $files |
        Sort-Object Length -Descending |
        Select-Object Name, FullName, @{ Name = 'SizeMB'; Expression = { [math]::Round($_.Length / 1MB, 2) } }
}

Get-BigFile C:\Windows -MinSizeMB 50 -Recurse -Verbose
Get-BigFile -Path C:\Windows -Extension .log -MinSizeMB 1 -Recurse
#endregion

#endregion

#region ===================== פרק 2 – אובייקטים =====================

#region 2.1 הכל אובייקט
$now = Get-Date
$now.Year
$now.DayOfWeek
$now.ToString('HH:mm')

$now | Get-Member            # TypeName: System.DateTime
$now.AddDays(100)

$sinceNewYear = $now - (Get-Date -Year $now.Year -Month 1 -Day 1)
$sinceNewYear.Days
#endregion

#region 2.2 Properties מול Methods
$me = Get-Process -Id $PID
$me | Select-Object ProcessName, Id, StartTime, @{ n = 'MemoryMB'; e = { [math]::Round($_.WorkingSet64 / 1MB, 1) } }

$me | Get-Member -MemberType Method    # Kill()

$s = 'PowerShell Is Great'
$s.ToUpper()
$s.Replace('Great', 'Awesome')
$words = $s.Split(' ')
$words.Count                            # 3
#endregion

#region 2.3 Select-Object
Get-Process | Sort-Object CPU -Descending | Select-Object -First 5 Name, Id, CPU

Get-Process | Sort-Object CPU -Descending | Select-Object -First 5 Name, Id, CPU,
    @{ Name = 'MemoryMB'; Expression = { [math]::Round($_.WorkingSet64 / 1MB, 1) } }

Get-Service | Select-Object Name | Get-Member                   # Selected.System.ServiceProcess.ServiceController
Get-Service | Select-Object -ExpandProperty Name | Get-Member   # System.String

Get-Process -Id $PID | Select-Object *
#endregion

#region 2.4 אובייקטים משלכם
$server = [PSCustomObject]@{ Name = 'SRV01'; IP = '10.0.0.1'; OS = 'Windows Server 2022'; IsOnline = $true }

$servers = @(
    [PSCustomObject]@{ Name = 'SRV01'; IP = '10.0.0.1'; OS = 'Windows Server 2022'; IsOnline = $true  }
    [PSCustomObject]@{ Name = 'SRV02'; IP = '10.0.0.2'; OS = 'Windows Server 2019'; IsOnline = $false }
    [PSCustomObject]@{ Name = 'SRV03'; IP = '10.0.0.3'; OS = 'Ubuntu 24.04';        IsOnline = $true  }
    [PSCustomObject]@{ Name = 'SRV04'; IP = '10.0.0.4'; OS = 'Windows Server 2016'; IsOnline = $false }
)

$servers | Where-Object { -not $_.IsOnline }

$servers | Add-Member -MemberType NoteProperty -Name Checked -Value (Get-Date) -Force
$servers | Format-Table

$servers[0] | Add-Member -MemberType ScriptMethod -Name Describe -Value {
    $state = if ($this.IsOnline) { 'Online' } else { 'Offline' }
    "$($this.Name) ($($this.IP)) - $state"
}
$servers[0].Describe()
#endregion

#region 2.5 מערכים ו-Hashtables
$numbers = 1..20
$numbers | Where-Object { $_ % 2 -eq 0 }
$numbers | Measure-Object -Sum -Average -Maximum -Minimum

$users = @{ david = 'IT'; dana = 'HR'; yossi = 'IT'; rina = 'Finance' }
$users['moshe'] = 'Sales'        # הוספה
$users.Remove('dana')            # מחיקה
$users.ContainsKey('yossi')      # בדיקה

$usersObj = [PSCustomObject]$users
$users    | Get-Member           # System.Collections.Hashtable – המפתחות לא מופיעים כ-Properties
$usersObj | Get-Member           # PSCustomObject – כל מפתח הפך ל-NoteProperty
#endregion

#region 2.6 Group-Object ו-Sort-Object
Get-Service | Group-Object Status

$sys32 = Get-ChildItem C:\Windows\System32 -File -ErrorAction SilentlyContinue
$sys32 | Group-Object Extension | Sort-Object Count -Descending | Select-Object -First 10 Name, Count

$sys32 | Group-Object Extension | Sort-Object Count -Descending | Select-Object -First 10 Name, Count,
    @{ n = 'TotalMB'; e = { [math]::Round(($_.Group | Measure-Object Length -Sum).Sum / 1MB, 2) } }

Get-Process | Sort-Object Company, @{ Expression = 'CPU'; Descending = $true } |
    Select-Object Company, Name, CPU
#endregion

#region 2.7 תרגיל מסכם – דוח מערכת
$os = Get-CimInstance Win32_OperatingSystem
$cs = Get-CimInstance Win32_ComputerSystem

$report = [PSCustomObject]@{
    ComputerName        = $env:COMPUTERNAME
    OS                  = $os.Caption
    UptimeHours         = [math]::Round(((Get-Date) - $os.LastBootUpTime).TotalHours)
    CPUCount            = $cs.NumberOfLogicalProcessors
    TotalRamGB          = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
    FreeRamGB           = [math]::Round($os.FreePhysicalMemory * 1KB / 1GB, 1)   # FreePhysicalMemory ב-KB
    TopProcesses        = Get-Process | Sort-Object WorkingSet64 -Descending | Select-Object -First 3 Name,
                              @{ n = 'MemoryMB'; e = { [math]::Round($_.WorkingSet64 / 1MB) } }
    StoppedAutoServices = Get-Service | Where-Object { $_.StartType -eq 'Automatic' -and $_.Status -ne 'Running' } |
                              Select-Object -ExpandProperty Name
}

$report | Format-List
$report.TopProcesses | Format-Table -AutoSize
#endregion

#endregion

#region ===================== פרק 3 – Input, Output ו-Pipeline =====================

#region 3.1 קלט מהמשתמש
$name = Read-Host 'מה השם שלך?'
"שלום $name, השעה עכשיו $(Get-Date -Format 'HH:mm')"

$pass = Read-Host 'סיסמה' -AsSecureString
$pass.GetType().FullName          # System.Security.SecureString

$a = Read-Host 'מספר ראשון'
$b = Read-Host 'מספר שני'
$a + $b                           # "2" + "3" = "23" – חיבור מחרוזות!
[int]$a + [int]$b                 # 5
#endregion

#region 3.2 פקודות הפלט
# Verbose ו-Information לא מוצגים כברירת מחדל
$VerbosePreference = 'Continue';  Write-Verbose 'verbose'; $VerbosePreference = 'SilentlyContinue'
Write-Information 'info' -InformationAction Continue

$x = Write-Output 'a'   # $x = 'a' – Write-Output כותב ל-Pipeline (Success stream)
$y = Write-Host 'b'     # $y ריק – Write-Host כותב ישר למסך (Information stream), לא ל-Pipeline
#endregion

#region 3.3 פורמט הפלט
Get-Service | Format-Table Name, Status, StartType -AutoSize
Get-Process -Id $PID | Format-List *
Get-Service | Format-Wide Name -Column 4
Get-Process | Out-GridView -PassThru | Stop-Process -WhatIf

# Format-* מחזירים אובייקטי עיצוב ולא את האובייקטים המקוריים,
# ולכן אחריהם אי אפשר למיין/לסנן. הכלל: Format-* תמיד בסוף ה-Pipeline.
Get-Service | Sort-Object Name | Format-Table
#endregion

#region 3.4 Pipeline – סינון ועיבוד
Get-Service | Where-Object { $_.Status -eq 'Running' -and $_.Name -like 'W*' }
Get-Service W* | Where-Object Status -eq Running

Get-ChildItem -File | ForEach-Object { "$($_.Name) - $($_.Length) bytes" }

$total = Get-ChildItem C:\Windows -Filter *.log -Recurse -File -ErrorAction SilentlyContinue |
    Measure-Object Length -Sum
[math]::Round($total.Sum / 1MB, 2)

Get-ChildItem -File | ForEach-Object -Begin { $count = 0 } -Process { $count++ } -End { "עברו $count קבצים" }
#endregion

#region 3.5 Parameter Binding
Get-Help Stop-Service -Parameter Name          # ByPropertyName, ByValue
Get-Help Stop-Service -Parameter InputObject   # ByValue (ServiceController)

'Spooler', 'W32Time' | Set-Content names.txt
Get-Content names.txt | Get-Service           # מחרוזות נקשרות ל-Name – ByValue

[PSCustomObject]@{ Name = 'Spooler' }, [PSCustomObject]@{ Name = 'W32Time' } | Get-Service   # ByPropertyName

Trace-Command -Name ParameterBinding -Expression { 'Spooler' | Get-Service } -PSHost
#endregion

#region 3.6 Redirection
Get-Process > procs.txt                        # 5.1: UTF-16 LE | 7+: UTF-8
Get-Process | Out-File procs.txt -Encoding utf8
Get-Date >> procs.txt

Get-ChildItem C:\Windows, C:\NoSuchFolder 2> errors.txt
Get-ChildItem C:\Windows, C:\NoSuchFolder *> all.txt

Get-Service | Tee-Object -FilePath services.txt
#endregion

#region 3.7 Test-Port
function Test-Port {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [string[]]$ComputerName,

        [ValidateRange(1, 65535)]
        [int]$Port = 443,

        [int]$TimeoutMs = 1000
    )

    begin   { Write-Verbose "בודק פורט $Port" }

    process {
        foreach ($computer in $ComputerName) {
            $client = [System.Net.Sockets.TcpClient]::new()
            try {
                $open = $client.ConnectAsync($computer, $Port).Wait($TimeoutMs)
            }
            catch {
                $open = $false
            }
            finally {
                $client.Dispose()
            }

            [PSCustomObject]@{
                ComputerName = $computer
                Port         = $Port
                Open         = $open
            }
        }
    }

    end     { Write-Verbose 'סיום' }
}

Test-Port -ComputerName google.com, localhost
'google.com', 'localhost' | Test-Port -Port 80

@'
ComputerName
google.com
localhost
'@ | Set-Content servers.csv
Import-Csv servers.csv | Test-Port
#endregion

#endregion

#region ===================== פרק 4 – עבודה עם קבצים =====================

#region 4.1 טקסט
'SRV01', 'SRV02', 'SRV03', 'SRV04', 'SRV05' | Set-Content servers.txt
Add-Content servers.txt 'SRV06'

(Get-Content servers.txt).Count
Get-Content servers.txt -TotalCount 1
Get-Content servers.txt -Tail 2

(Get-Content servers.txt).GetType().Name        # Object[] – מערך שורות
(Get-Content servers.txt -Raw).GetType().Name   # String – מחרוזת אחת

Select-String -Path servers.txt -Pattern 'SRV' | Select-Object LineNumber, Line
#endregion

#region 4.2 עיבוד לוג
@'
2026-09-01 10:00:01 INFO  User david logged in
2026-09-01 10:02:15 ERROR Database timeout on SRV-DB01
2026-09-01 10:05:40 WARN  Disk C: 85% on SRV-APP02
2026-09-01 10:07:12 ERROR Database timeout on SRV-DB01
2026-09-01 10:09:55 INFO  User dana logged out
2026-09-01 10:11:30 ERROR Service crashed on SRV-APP01
'@ | Set-Content app.log

$log = Get-Content app.log

# 1. ספירה לפי רמה
$log | ForEach-Object { ($_ -split '\s+')[2] } | Group-Object -NoElement

# 2. שם השרת מכל שורת ERROR
$log | Where-Object { $_ -match 'ERROR.*on (?<Server>SRV-\S+)' } | ForEach-Object { $Matches.Server }
# או בקצרה:
Select-String -Path app.log -Pattern 'ERROR.*on (SRV-\S+)' | ForEach-Object { $_.Matches[0].Groups[1].Value }

# 3. המרה לאובייקטים
$entries = foreach ($line in $log) {
    if ($line -match '^(?<Date>\S+ \S+)\s+(?<Level>\w+)\s+(?<Message>.+)$') {
        [PSCustomObject]@{
            Date    = [datetime]$Matches.Date
            Level   = $Matches.Level
            Message = $Matches.Message
        }
    }
}
$entries | Format-Table

# 4. רק ERROR לקובץ
$log | Where-Object { $_ -match '\bERROR\b' } | Set-Content errors_only.log
#endregion

#region 4.3 CSV
Get-Service | Select-Object Name, DisplayName, Status, StartType |
    Export-Csv services.csv -NoTypeInformation -Encoding UTF8

$svc = Import-Csv services.csv
$svc | Where-Object Status -eq 'Stopped'
$svc[0].Status.GetType().Name     # String – CSV תמיד מחזיר מחרוזות

@'
Name,Department,Salary
David,IT,18000
Dana,HR,15000
Yossi,IT,21000
Rina,Finance,17500
'@ | Set-Content users.csv

$usersCsv = Import-Csv users.csv
$usersCsv | Group-Object Department | Select-Object Name,
    @{ n = 'AvgSalary'; e = { ($_.Group | ForEach-Object { [int]$_.Salary } | Measure-Object -Average).Average } }

$usersCsv |
    Select-Object *, @{ n = 'Email'; e = { "$($_.Name.ToLower())@company.local" } } |
    Export-Csv users_with_email.csv -NoTypeInformation -Encoding UTF8

$usersCsv | Export-Csv users_semicolon.csv -Delimiter ';' -NoTypeInformation
Import-Csv users_semicolon.csv -Delimiter ';'
#endregion

#region 4.4 JSON
Get-Process | Select-Object -First 3 Name, Id, CPU | ConvertTo-Json

$servers | ConvertTo-Json | Set-Content servers.json          # $servers מתרגיל 2.4
$fromJson = Get-Content servers.json -Raw | ConvertFrom-Json
$fromJson | Where-Object IsOnline

@'
{
  "AppName": "Monitor",
  "Version": "1.2",
  "Servers": [
    { "Name": "SRV01", "Port": 443 },
    { "Name": "SRV02", "Port": 8080 }
  ],
  "Settings": { "Retries": 3, "TimeoutSec": 30 }
}
'@ | Set-Content config.json

$config = Get-Content config.json -Raw | ConvertFrom-Json
$config.Settings.Retries = 5
$config.Servers += [PSCustomObject]@{ Name = 'SRV03'; Port = 22 }
$config | ConvertTo-Json -Depth 5 | Set-Content config.json

# -Depth: ברירת המחדל היא 2. אובייקט מקונן עמוק יותר הופך למחרוזת:
$deep = @{ L1 = @{ L2 = @{ L3 = @{ L4 = 'value' } } } }
$deep | ConvertTo-Json               # L3 מוצג כ-"System.Collections.Hashtable"
$deep | ConvertTo-Json -Depth 10     # הכל נשמר
#endregion

#region 4.5 XML
Get-Process | Export-Clixml procs.xml
$procs = Import-Clixml procs.xml
$procs | Get-Member     # TypeName: Deserialized.System.Diagnostics.Process – Properties בלבד, בלי Methods

@'
<Inventory>
  <Server name="SRV01" role="Web"  ram="16" />
  <Server name="SRV02" role="DB"   ram="64" />
  <Server name="SRV03" role="Web"  ram="8"  />
</Inventory>
'@ | Set-Content inventory.xml

$xmlPath = (Resolve-Path inventory.xml).Path
[xml]$inv = Get-Content $xmlPath -Raw
$inv.Inventory.Server | Where-Object role -eq 'Web'

Select-Xml -Path $xmlPath -XPath '//Server[@ram > 10]' | ForEach-Object { $_.Node }

$new = $inv.CreateElement('Server')
$new.SetAttribute('name', 'SRV04')
$new.SetAttribute('role', 'App')
$new.SetAttribute('ram',  '32')
[void]$inv.Inventory.AppendChild($new)
$inv.Save($xmlPath)     # Save() דורש נתיב מלא

Get-Credential | Export-Clixml cred.xml
$cred = Import-Clixml cred.xml
# מוצפן עם DPAPI – ניתן לפענוח רק על אותו מחשב ובאותו משתמש שיצר אותו
#endregion

#region 4.6 HTML ועוד
$css = @'
<style>
  body  { font-family: Segoe UI, Arial; }
  table { border-collapse: collapse; }
  th    { background: #2b579a; color: white; padding: 4px 8px; }
  td    { border: 1px solid #ccc; padding: 4px 8px; }
</style>
'@

Get-Process | Sort-Object WorkingSet64 -Descending | Select-Object -First 10 Name, Id,
    @{ n = 'MemoryMB'; e = { [math]::Round($_.WorkingSet64 / 1MB) } } |
    ConvertTo-Html -Title 'Top Processes' -Head $css -PreContent '<h1>Top 10 Processes</h1>' |
    Set-Content top.html
Invoke-Item top.html

$f1 = Get-Process | Sort-Object CPU -Descending | Select-Object -First 10 Name, CPU |
    ConvertTo-Html -Fragment -PreContent '<h2>Processes</h2>'
$f2 = Get-Service | Where-Object Status -eq Stopped | Select-Object Name, DisplayName |
    ConvertTo-Html -Fragment -PreContent '<h2>Stopped Services</h2>'
ConvertTo-Html -Head $css -Body ($f1 + $f2) -Title 'System Report' | Set-Content report.html

Compress-Archive -Path C:\PSLab\* -DestinationPath C:\lab.zip -Force
Expand-Archive  -Path C:\lab.zip -DestinationPath C:\PSLab_Restored -Force

$before = Get-FileHash C:\lab.zip
Copy-Item C:\lab.zip C:\lab_copy.zip
$after  = Get-FileHash C:\lab_copy.zip
$before.Hash -eq $after.Hash     # True
#endregion

#region 4.7 Convert-DataFile
function Convert-DataFile {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
        [Alias('FullName')]
        [ValidateScript({ Test-Path $_ -PathType Leaf })]
        [string]$Path,

        [Parameter(Mandatory)]
        [ValidateSet('Csv', 'Json', 'Xml', 'Html')]
        [string]$To
    )

    process {
        $file = Get-Item $Path
        $from = $file.Extension.TrimStart('.')

        if ($from -eq $To) {
            throw "הקובץ '$($file.Name)' כבר בפורמט $To"
        }

        $data = switch ($from) {
            'csv'   { Import-Csv $file.FullName }
            'json'  { Get-Content $file.FullName -Raw | ConvertFrom-Json }
            'xml'   { Import-Clixml $file.FullName }
            default { throw "פורמט קלט לא נתמך: $($file.Extension)" }
        }

        $target = Join-Path $file.DirectoryName ($file.BaseName + '.' + $To.ToLower())

        if ($PSCmdlet.ShouldProcess($target, "Convert $from -> $To")) {
            switch ($To) {
                'Csv'  { $data | Export-Csv $target -NoTypeInformation -Encoding UTF8 }
                'Json' { $data | ConvertTo-Json -Depth 5 | Set-Content $target -Encoding UTF8 }
                'Xml'  { $data | Export-Clixml $target }
                'Html' { $data | ConvertTo-Html | Set-Content $target -Encoding UTF8 }
            }
            Get-Item $target
        }
    }
}

Copy-Item users.csv users_orig.csv
Convert-DataFile users.csv  -To Json
Convert-DataFile users.json -To Xml
Remove-Item users.csv
Convert-DataFile users.xml  -To Csv
Convert-DataFile users.xml  -To Csv -WhatIf

# השוואה – אין הבדלים אם הפלט ריק
Compare-Object (Import-Csv users_orig.csv) (Import-Csv users.csv) -Property Name, Department, Salary
#endregion

#endregion

#region ===================== בונוס – Get-FolderReport =====================
function Get-FolderReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('FullName')]
        [ValidateScript({ Test-Path $_ -PathType Container })]
        [string]$Path,

        [string]$OutputFolder = (Get-Location).Path,

        [switch]$Recurse
    )

    process {
        $folder = Get-Item $Path
        $prefix = Join-Path $OutputFolder $folder.Name
        Write-Verbose "סורק את $($folder.FullName)"

        $errors = $null
        $files = Get-ChildItem $folder.FullName -File -Recurse:$Recurse -ErrorAction SilentlyContinue -ErrorVariable errors
        if ($errors) { Write-Warning "$($errors.Count) פריטים לא נקראו (הרשאות)" }

        try {
            Write-Verbose 'כותב CSV'
            $rows = $files | Select-Object Name, Extension,
                @{ n = 'SizeKB'; e = { [math]::Round($_.Length / 1KB, 1) } }, LastWriteTime
            $rows | Export-Csv "$prefix-report.csv" -NoTypeInformation -Encoding UTF8

            Write-Verbose 'כותב JSON'
            $byExt = $files | Group-Object Extension | ForEach-Object {
                [PSCustomObject]@{
                    Extension = if ($_.Name) { $_.Name } else { '(none)' }
                    Count     = $_.Count
                    TotalMB   = [math]::Round(($_.Group | Measure-Object Length -Sum).Sum / 1MB, 2)
                }
            } | Sort-Object TotalMB -Descending
            $top5 = $rows | Sort-Object SizeKB -Descending | Select-Object -First 5

            [PSCustomObject]@{ Folder = $folder.FullName; ByExtension = $byExt; Largest = $top5 } |
                ConvertTo-Json -Depth 4 | Set-Content "$prefix-summary.json" -Encoding UTF8

            Write-Verbose 'כותב HTML'
            $body  = $byExt | ConvertTo-Html -Fragment -PreContent "<h1>$($folder.FullName)</h1><h2>By extension</h2>"
            $body += $top5  | ConvertTo-Html -Fragment -PreContent '<h2>Largest files</h2>'
            ConvertTo-Html -Body $body -Title "Folder report – $($folder.Name)" |
                Set-Content "$prefix-report.html" -Encoding UTF8

            Get-Item "$prefix-report.csv", "$prefix-summary.json", "$prefix-report.html"
        }
        catch {
            Write-Error "נכשל ביצירת הדוח עבור $($folder.FullName): $_"
        }
    }
}

Get-FolderReport C:\Windows\Logs -Recurse -Verbose
Get-ChildItem C:\PSLab -Directory | Get-FolderReport
#endregion
