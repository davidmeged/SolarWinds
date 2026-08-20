# This sample script demonstrates how to bulk-add nodes to SolarWinds from a
# CSV file of name/IP pairs - e.g. the file produced by
# CheckPoint.GetClusterFirewallAddresses.ps1 when discovering ClusterXL
# firewall member addresses from the Check Point SmartConsole API.
#
# Using a CSV as the handoff point keeps the discovery automation (Check
# Point) and the monitoring automation (SolarWinds) decoupled: each can run,
# be tested, and be reviewed on its own schedule, and the CSV itself acts as
# an audit trail / manual review gate before anything is added to monitoring.
# If you'd rather skip the file and call the discovery function directly,
# see Orchestrator.AddClusterFirewallsToSolarWinds.ps1 instead.
#
# Please update the hostname/credential setup, CSV path, and column names
# below to match your configuration.

param(
    [string]$CsvPath = ".\ClusterFirewalls.csv",
    [string]$NameColumn = "MemberName",
    [string]$IpColumn = "MemberIp"
)

# Connect to SWIS
$hostname = "localhost"
$username = "admin"
$password = New-Object System.Security.SecureString
$cred = New-Object -typename System.Management.Automation.PSCredential -argumentlist $username, $password
$swis = Connect-Swis -host $hostname -cred $cred

$rows = Import-Csv -Path $CsvPath

foreach ($row in $rows) {
    $name = $row.$NameColumn
    $ip   = $row.$IpColumn

    if ([string]::IsNullOrWhiteSpace($ip)) {
        Write-Warning "Skipping row with no IP address (name: '$name')."
        continue
    }

    Write-Host "Adding node '$name' ($ip)..."

    # add a node
    $newNodeProps = @{
        IPAddress = $ip;
        EngineID = 1;
        Caption = $name;

        # SNMP v2 specific
        ObjectSubType = "SNMP";
        SNMPVersion = 2;

        DNS = "";
        SysName = "";
    }

    $newNodeUri = New-SwisObject $swis -EntityType "Orion.Nodes" -Properties $newNodeProps
    $nodeProps = Get-SwisObject $swis -Uri $newNodeUri

    # register default pollers for the node
    $poller = @{
        NetObject="N:"+$nodeProps["NodeID"];
        NetObjectType="N";
        NetObjectID=$nodeProps["NodeID"];
    }

    $poller["PollerType"]="N.Status.ICMP.Native";
    New-SwisObject $swis -EntityType "Orion.Pollers" -Properties $poller | Out-Null

    $poller["PollerType"]="N.ResponseTime.ICMP.Native";
    New-SwisObject $swis -EntityType "Orion.Pollers" -Properties $poller | Out-Null

    $poller["PollerType"]="N.Details.SNMP.Generic";
    New-SwisObject $swis -EntityType "Orion.Pollers" -Properties $poller | Out-Null

    $poller["PollerType"]="N.Uptime.SNMP.Generic";
    New-SwisObject $swis -EntityType "Orion.Pollers" -Properties $poller | Out-Null
}
