# This sample script demonstrates how to authenticate against the Check Point
# SmartConsole / Security Management Server API (the "web_api") and retrieve the
# IP addresses of the firewall members that belong to a ClusterXL ("simple-cluster")
# object. This is useful for feeding discovered firewall addresses into SolarWinds
# (e.g. via CRUD.AddNode.ps1) for monitoring.
#
# Please update the management server details and credential setup below to match
# your environment.
#
# Requires PowerShell 7+ for the -SkipCertificateCheck switch on Invoke-RestMethod.
# If you are on Windows PowerShell 5.1, remove -SkipCertificateCheck and either
# install a trusted certificate on the management server or trust it beforehand.

function Connect-SmartConsole {
    param(
        [Parameter(Mandatory = $true)] [string]$Server,
        [int]$Port = 443,
        [Parameter(Mandatory = $true)] [string]$Username,
        [Parameter(Mandatory = $true)] [System.Security.SecureString]$Password,
        [switch]$TrustAllCertificates
    )

    $plainPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
    )

    $body = @{
        user     = $Username
        password = $plainPassword
    } | ConvertTo-Json

    $uri = "https://${Server}:${Port}/web_api/v1.9/login"

    $params = @{
        Uri         = $uri
        Method      = "Post"
        Body        = $body
        ContentType = "application/json"
    }
    if ($TrustAllCertificates) {
        $params["SkipCertificateCheck"] = $true
    }

    $response = Invoke-RestMethod @params

    [pscustomobject]@{
        Server               = $Server
        Port                 = $Port
        Sid                  = $response.sid
        TrustAllCertificates = [bool]$TrustAllCertificates
    }
}

function Disconnect-SmartConsole {
    param(
        [Parameter(Mandatory = $true)] [pscustomobject]$Session
    )

    $uri = "https://$($Session.Server):$($Session.Port)/web_api/v1.9/logout"
    $params = @{
        Uri         = $uri
        Method      = "Post"
        Headers     = @{ "X-chkp-sid" = $Session.Sid }
        Body        = "{}"
        ContentType = "application/json"
    }
    if ($Session.TrustAllCertificates) {
        $params["SkipCertificateCheck"] = $true
    }

    Invoke-RestMethod @params | Out-Null
}

function Invoke-SmartConsoleApi {
    param(
        [Parameter(Mandatory = $true)] [pscustomobject]$Session,
        [Parameter(Mandatory = $true)] [string]$Command,
        [hashtable]$Body = @{}
    )

    $uri = "https://$($Session.Server):$($Session.Port)/web_api/v1.9/$Command"
    $params = @{
        Uri         = $uri
        Method      = "Post"
        Headers     = @{ "X-chkp-sid" = $Session.Sid }
        Body        = ($Body | ConvertTo-Json -Depth 10)
        ContentType = "application/json"
    }
    if ($Session.TrustAllCertificates) {
        $params["SkipCertificateCheck"] = $true
    }

    Invoke-RestMethod @params
}

function Get-SmartConsoleClusterFirewallAddresses {
    param(
        [Parameter(Mandatory = $true)] [pscustomobject]$Session
    )

    $limit   = 50
    $offset  = 0
    $results = @()

    do {
        $page = Invoke-SmartConsoleApi -Session $Session -Command "show-simple-clusters" -Body @{
            limit  = $limit
            offset = $offset
        }

        foreach ($clusterSummary in $page.objects) {
            $cluster = Invoke-SmartConsoleApi -Session $Session -Command "show-simple-cluster" -Body @{
                uid            = $clusterSummary.uid
                "details-level" = "full"
            }

            foreach ($member in $cluster.'cluster-members') {
                $results += [pscustomobject]@{
                    ClusterName = $cluster.name
                    ClusterVip  = $cluster.'ipv4-address'
                    MemberName  = $member.name
                    MemberIp    = $member.'ip-address'
                }
            }
        }

        $offset += $limit
    } while ($offset -lt $page.total)

    $results
}

# ---------------------------------------------------------------------------
# Example usage
# ---------------------------------------------------------------------------

# $mgmtServer = "smartcenter.example.com"
# $username   = "admin"
# $password   = Read-Host -Prompt "Password" -AsSecureString
#
# $session = Connect-SmartConsole -Server $mgmtServer -Username $username -Password $password
#
# try {
#     $firewalls = Get-SmartConsoleClusterFirewallAddresses -Session $session
#     $firewalls | Format-Table -AutoSize
# }
# finally {
#     Disconnect-SmartConsole -Session $session
# }
