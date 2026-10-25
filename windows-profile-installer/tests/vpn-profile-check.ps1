# VpnProfile.ps1 against Windows itself, run as an ordinary signed-in user:
# a split profile with routes and names installed and read back, installed
# again over itself, a full-tunnel one, and removal.
$ErrorActionPreference = 'Stop'
$script = Join-Path $PSScriptRoot '..\VpnProfile.ps1'
$name = 'Waypoint Profile Check ' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$eap = '<EapHostConfig xmlns="http://www.microsoft.com/provisioning/EapHostConfig"><EapMethod><Type xmlns="http://www.microsoft.com/provisioning/EapCommon">26</Type><VendorId xmlns="http://www.microsoft.com/provisioning/EapCommon">0</VendorId><VendorType xmlns="http://www.microsoft.com/provisioning/EapCommon">0</VendorType><AuthorId xmlns="http://www.microsoft.com/provisioning/EapCommon">0</AuthorId></EapMethod><Config xmlns="http://www.microsoft.com/provisioning/EapHostConfig"><Eap xmlns="http://www.microsoft.com/provisioning/BaseEapConnectionPropertiesV1"><Type>26</Type><EapType xmlns="http://www.microsoft.com/provisioning/MsChapV2ConnectionPropertiesV1"><UseWinLogonCredentials>false</UseWinLogonCredentials></EapType></Eap></Config></EapHostConfig>'
function Profile([string]$routing, [string]$routes) {
    $file = Join-Path $env:TEMP ($name + '-' + $routing + '.vpnv2.xml')
    Set-Content -LiteralPath $file -Encoding UTF8 -Value ("<VPNProfile><ProfileName>$name</ProfileName><RememberCredentials>true</RememberCredentials><AlwaysOn>false</AlwaysOn>" +
        "<DomainNameInformation><DomainName>.</DomainName><DnsServers>192.0.2.1</DnsServers><AutoTrigger>false</AutoTrigger><Persistent>false</Persistent></DomainNameInformation>" +
        "<NativeProfile><Servers>vpn.example.com</Servers><RoutingPolicyType>$routing</RoutingPolicyType><NativeProtocolType>IKEv2</NativeProtocolType>" +
        "<CryptographySuite><AuthenticationTransformConstants>GCMAES256</AuthenticationTransformConstants><CipherTransformConstants>GCMAES256</CipherTransformConstants><PfsGroup>ECP384</PfsGroup><DHGroup>ECP384</DHGroup><IntegrityCheckMethod>SHA384</IntegrityCheckMethod><EncryptionMethod>AES_GCM_256</EncryptionMethod></CryptographySuite>" +
        "<Authentication><UserMethod>Eap</UserMethod><Eap><Configuration>$eap</Configuration></Eap></Authentication></NativeProfile>$routes</VPNProfile>")
    $file
}
function Run([string]$operation, [string]$file) {
    $line = & powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $script -Operation $operation -Profile $file | Select-Object -Last 1
    $line | ConvertFrom-Json
}
function Check([bool]$ok, [string]$what) { if (-not $ok) { throw "FAIL $what" }; Write-Host "PASS $what" }

"user: $(whoami); administrator: " + ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$split = Profile 'SplitTunnel' '<Route><Address>192.168.2.0</Address><PrefixSize>24</PrefixSize></Route><Route><Address>10.10.0.0</Address><PrefixSize>16</PrefixSize></Route>'
try {
    $answer = Run 'install' $split
    Check $answer.ok ("a split profile installs: " + $answer.message)
    $made = Get-VpnConnection -Name $name
    Check ($made.TunnelType -eq 'Ikev2' -and $made.SplitTunneling -and $made.RememberCredential -and $made.AuthenticationMethod -contains 'Eap') 'the connection is IKEv2 with EAP, split, remembering the password'
    $policy = $made.IPsecCustomPolicy
    Check ($policy.CipherTransformConstants -eq 'GCMAES256' -and $policy.DHGroup -eq 'ECP384' -and $policy.IntegrityCheckMethod -eq 'SHA384') 'the ciphers are the profile''s'
    Check ((@($made.Routes | ForEach-Object DestinationPrefix) | Sort-Object) -join ',' -eq '10.10.0.0/16,192.168.2.0/24') 'the routes of a split profile are in place'
    $book = Join-Path $env:APPDATA 'Microsoft\Network\Connections\Pbk\rasphone.pbk'
    $section = ((Get-Content -LiteralPath $book -Raw) -split '(?m)^\[') | Where-Object { $_.StartsWith($name + ']') }
    Check ($answer.names -and $section -match '(?m)^IpInterfaceMetric=1\s*$') 'names go to the server first while connected'
    Check (@(Get-DnsClientNrptRule -ErrorAction SilentlyContinue).Count -eq 0) 'nothing is left in force for the whole machine'
    Check ((Run 'install' $split).ok -and @(Get-VpnConnection | Where-Object Name -EQ $name).Count -eq 1) 'installing again replaces the connection'
    $full = Profile 'ForceTunnel' ''
    Check ((Run 'install' $full).ok -and -not (Get-VpnConnection -Name $name).SplitTunneling) 'a full-tunnel profile takes everything'
    Check ((Run 'status' $full).installed) 'status sees the connection'
    Check ((Run 'remove' $full).ok -and -not (Get-VpnConnection -Name $name -ErrorAction SilentlyContinue)) 'removal takes the connection away'
    Write-Host 'Profile checks passed'
}
finally {
    Remove-VpnConnection -Name $name -Force -ErrorAction SilentlyContinue
    Get-ChildItem $env:TEMP -Filter ($name + '*') | Remove-Item -Force
}
