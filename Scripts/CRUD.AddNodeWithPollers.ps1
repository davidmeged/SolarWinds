# Shared helper function for adding a single node to SolarWinds with the
# standard set of default pollers (Status, Response Time, Details, Uptime).
# Dot-source this file to load the function - see CRUD.AddNodesFromCsv.ps1
# and Orchestrator.AddClusterFirewallsToSolarWinds.ps1 for callers.

function Add-SwisNodeWithDefaultPollers {
    param(
        [Parameter(Mandatory = $true)] $Swis,
        [Parameter(Mandatory = $true)] [string]$IPAddress,
        [string]$Name = "",
        [string]$Community = "public",
        [string]$RWCommunity = ""
    )

    $newNodeProps = @{
        IPAddress = $IPAddress;
        EngineID = 1;
        Caption = $Name;

        # SNMP v2 specific
        ObjectSubType = "SNMP";
        SNMPVersion = 2;
        Community = $Community;
        RWCommunity = $RWCommunity;

        DNS = "";
        SysName = "";
    }

    $newNodeUri = New-SwisObject $Swis -EntityType "Orion.Nodes" -Properties $newNodeProps
    $nodeProps = Get-SwisObject $Swis -Uri $newNodeUri

    $poller = @{
        NetObject="N:"+$nodeProps["NodeID"];
        NetObjectType="N";
        NetObjectID=$nodeProps["NodeID"];
    }

    foreach ($pollerType in @(
        "N.Status.ICMP.Native",
        "N.ResponseTime.ICMP.Native",
        "N.Details.SNMP.Generic",
        "N.Uptime.SNMP.Generic"
    )) {
        $poller["PollerType"] = $pollerType
        New-SwisObject $Swis -EntityType "Orion.Pollers" -Properties $poller | Out-Null
    }

    $nodeProps
}

# ---------------------------------------------------------------------------
# Example usage
# ---------------------------------------------------------------------------

# $hostname = "localhost"
# $username = "admin"
# $password = New-Object System.Security.SecureString
# $cred = New-Object -typename System.Management.Automation.PSCredential -argumentlist $username, $password
# $swis = Connect-Swis -host $hostname -cred $cred
#
# Add-SwisNodeWithDefaultPollers -Swis $swis -Name "fw-member-1" -IPAddress "10.0.0.1" -Community "public"
