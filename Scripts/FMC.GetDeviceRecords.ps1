# FMC Information
$uri = "https://1.1.1.1/api/fmc_platform/v1/auth/generatetoken"
$cred = Import-Clixml -Path "D:\SolarWindsScripts\PowerShell\Credentials\FMC_Credential.xml"
$user = $cred.UserName
$pass = $cred.GetNetworkCredential().Password
$pair = "${user}:${pass}"
$encode = [convert]::ToBase64String([text.encoding]::ASCII.GetBytes($pair))
$header = @{
    # שינוי מ - Authentication ל - Authorization
    "Authorization" = "Basic $encode"
    "Content-Type"  = "application/json"
}

#SolarWinds Information
$solarCred = Import-Clixml -Path "D:\SolarWindsScripts\PowerShell\Credentials\SolarWindsCredentials.xml"
$swis = Connect-Swis -UserName $solarCred.UserName -Password $solarCred.GetNetworkCredential().Password -Hostname "5.5.5.5"

#ב - FMC POST ל - Auth בדרך כלל לא דורש Body, אבל דורש את הכותרות הנכונות
$response = Invoke-WebRequest -Uri $uri -Headers $header -Method Post -SkipCertificateCheck
$token = $response.Headers["X-auth-access-token"]
$domainUUID = $response.Headers["DOMAIN_UUID"]

$getDevicesUrl = "https://1.1.1.1/api/fmc_config/v1/domain/$domainUUID/devices/devicerecords?expanded=true&limit=1000"
$header = @{
    "X-auth-access-token" = "$token"
    "Content-Type"  = "application/json"
}
