# This sample script wires CheckPoint.GetClusterFirewallAddresses.ps1 directly
# into SolarWinds node creation, without a CSV file in between: it dot-sources
# the Check Point functions, discovers the cluster firewall addresses, and
# feeds them straight into New-SwisObject in one run.
#
# This trades away the CSV's manual review gate (and the ability to run each
# side on its own schedule/host) for a single unattended run - a good fit for
# a scheduled task where you trust the discovery output. If you want a review
# step before nodes are added to monitoring, use
# CheckPoint.GetClusterFirewallAddresses.ps1 + CRUD.AddNodesFromCsv.ps1
# instead.
#
# Please update the connection details/credentials for both systems below.

# Dot-source the Check Point functions (Connect-SmartConsole,
# Get-SmartConsoleClusterFirewallAddresses, Disconnect-SmartConsole) and the
# SolarWinds node-creation helper (Add-SwisNodeWithDefaultPollers). The
# example-usage blocks at the bottom of those files only run when their
# commented lines are uncommented, so dot-sourcing here just loads the
# functions.
. (Join-Path $PSScriptRoot "CheckPoint.GetClusterFirewallAddresses.ps1")
. (Join-Path $PSScriptRoot "CRUD.AddNodeWithPollers.ps1")

# --- Check Point SmartConsole connection ---
$cpServer   = "smartcenter.example.com"
$cpUsername = "admin"
$cpPassword = Read-Host -Prompt "Check Point password" -AsSecureString

# --- SolarWinds connection ---
$swHostname = "localhost"
$swUsername = "admin"
$swPassword = New-Object System.Security.SecureString
$swCred = New-Object -typename System.Management.Automation.PSCredential -argumentlist $swUsername, $swPassword

$cpSession = Connect-SmartConsole -Server $cpServer -Username $cpUsername -Password $cpPassword

try {
    $firewalls = Get-SmartConsoleClusterFirewallAddresses -Session $cpSession
}
finally {
    Disconnect-SmartConsole -Session $cpSession
}

if (-not $firewalls) {
    Write-Warning "No cluster firewall addresses were discovered - nothing to add."
    return
}

$swis = Connect-Swis -host $swHostname -cred $swCred

foreach ($fw in $firewalls) {
    if ([string]::IsNullOrWhiteSpace($fw.MemberIp)) {
        Write-Warning "Skipping '$($fw.MemberName)' - no IP address returned."
        continue
    }

    Write-Host "Adding node '$($fw.MemberName)' ($($fw.MemberIp)) from cluster '$($fw.ClusterName)'..."
    Add-SwisNodeWithDefaultPollers -Swis $swis -Name $fw.MemberName -IPAddress $fw.MemberIp | Out-Null
}
