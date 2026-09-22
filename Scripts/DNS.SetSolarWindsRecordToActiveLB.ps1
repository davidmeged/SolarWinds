function dns_ip{
# this function get me the dns ip based on the server's dns

    $networks = get-wmiobject -Class Win32_NetworkAdapterConfiguration

    foreach($n in $networks){

        $network = $n.DNSServerSearchOrder

        foreach($ip in $network){

        try{

            test-connection -ComputerName $ip -Count 1

            $new = $ip

            return [String]$new
            }

        catch{continue}

        }

    }

}
#############
# those are all the details dont touch it if you didnt change the server ip, dns zone or the name
$active_server = $args[0]

$solarwinds_name = "OurSolar"

$SecondaryDC_solar_ip = "10.10.20.1"
$PrimaryDC_solar_ip = "10.10.10.1"

$LB_SecondaryDC = "10.10.20.10"
$LB_PrimaryDC = "10.10.10.10"

$dns_server_ip = dns_ip

$dns_server_ip = $dns_server_ip.IPV4Address.IPAddressToString
$dns_server_ip

$zone = "OurZone"

$OldObj = Get-DnsServerResourceRecord -ComputerName $dns_server_ip -Name $solarwinds_name -ZoneName $zone

$ip = $oldobj.RecordData.IPv4Address.IPAddressToString

#############



if ($active_server -eq $SecondaryDC_solar_ip){
    # if its on PrimaryDC change it to SecondaryDC
    $SNMP = New-Object -ComObject olePrn.oleSNMP
    # Get status of web servers on SecondaryDC
    $SNMP.Open('10.10.20.100', 'public',2,1000)
    $resultServerOne = $SNMP.Get('.1.3.6.1.4.1.1872.2.5.4.2.19.1.10.2.51.57.1.2.51.54')
    $resultServerTwo = $SNMP.Get('.1.3.6.1.4.1.1872.2.5.4.2.19.1.10.2.51.57.1.2.51.55')
    $SNMP.Close()
    # If one web server goes down and LB in PrimaryDC, change to SecondaryDC LB
    if (($resultServerOne -eq 0 -or $resultServerTwo -eq 0) -and $ip -ne $LB_SecondaryDC) {
        Get-DnsServerResourceRecord -ComputerName $dns_server_ip -Name $solarwinds_name -ZoneName $zone
        Write-Host aaaaa
        $NewObj = Get-DnsServerResourceRecord -ComputerName $dns_server_ip -Name "OurSolar" -ZoneName $zone
        $NewObj.RecordData.IPV4Address = [System.Net.IPAddress]::Parse($LB_SecondaryDC)
        Set-DnsServerResourceRecord -ZoneName $zone -ComputerName $dns_server_ip -OldInputObject $oldobj -NewInputObject $NewObj
        Get-DnsServerResourceRecord -ComputerName $dns_server_ip -Name $solarwinds_name -ZoneName $zone
    }
    # If both web servers goes down and LB not in of SecondaryDC, change to PrimaryDC LB
    elseif (($resultServerOne -ne 0 -and $resultServerTwo -ne 0) -and $ip -ne $LB_PrimaryDC) {
        Get-DnsServerResourceRecord -ComputerName $dns_server_ip -Name $solarwinds_name -ZoneName $zone
        Write-Host aaaaa
        $NewObj = Get-DnsServerResourceRecord -ComputerName $dns_server_ip -Name "OurSolar" -ZoneName $zone
        $NewObj.RecordData.IPV4Address = [System.Net.IPAddress]::Parse($LB_PrimaryDC)
        Set-DnsServerResourceRecord -ZoneName $zone -ComputerName $dns_server_ip -OldInputObject $oldobj -NewInputObject $NewObj
        Get-DnsServerResourceRecord -ComputerName $dns_server_ip -Name $solarwinds_name -ZoneName $zone

    }

}

if ($active_server -eq $PrimaryDC_solar_ip){
    # if its on SecondaryDC change it to PrimaryDC
    $SNMP = New-Object -ComObject olePrn.oleSNMP
    # Get status of web servers on PrimaryDC
    $SNMP.Open('10.10.10.100', 'public',2,1000)
    $resultServerOne = $SNMP.Get('.1.3.6.1.4.1.1872.2.5.4.2.19.1.10.2.52.52.1.2.57.51')
    $resultServerTwo = $SNMP.Get('.1.3.6.1.4.1.1872.2.5.4.2.19.1.10.2.52.52.1.2.57.52')
    $SNMP.Close()
    # If both web servers goes down and LB not in SecondaryDC, change to PrimaryDC LB
    if (($resultServerOne -eq 0 -or $resultServerTwo -eq 0) -and $ip -ne $LB_PrimaryDC) {
        Get-DnsServerResourceRecord -ComputerName $dns_server_ip -Name $solarwinds_name -ZoneName $zone
        Write-Host aaaaa
        $NewObj = Get-DnsServerResourceRecord -ComputerName $dns_server_ip -Name "OurSolar" -ZoneName $zone
        $NewObj.RecordData.IPV4Address = [System.Net.IPAddress]::Parse($LB_PrimaryDC)
        Set-DnsServerResourceRecord -ZoneName $zone -ComputerName $dns_server_ip -OldInputObject $oldobj -NewInputObject $NewObj
        Get-DnsServerResourceRecord -ComputerName $dns_server_ip -Name $solarwinds_name -ZoneName $zone
    }
    # If one web server goes down and LB in PrimaryDC, change to SecondaryDC LB
    elseif (($resultServerOne -ne 0 -and $resultServerTwo -ne 0) -and $ip -ne $LB_SecondaryDC) {
    Get-DnsServerResourceRecord -ComputerName $dns_server_ip -Name $solarwinds_name -ZoneName $zone
        Write-Host aaaaa
        $NewObj = Get-DnsServerResourceRecord -ComputerName $dns_server_ip -Name "OurSolar" -ZoneName $zone
        $NewObj.RecordData.IPV4Address = [System.Net.IPAddress]::Parse($LB_SecondaryDC)
        Set-DnsServerResourceRecord -ZoneName $zone -ComputerName $dns_server_ip -OldInputObject $oldobj -NewInputObject $NewObj
        Get-DnsServerResourceRecord -ComputerName $dns_server_ip -Name $solarwinds_name -ZoneName $zone
    }
}
