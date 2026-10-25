# Builds the installer with the .NET Framework compiler of this Windows and
# runs its store against Windows itself, as whoever runs this script.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
$work = Join-Path $env:TEMP ('nikitid-store-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $work | Out-Null
try {
    $compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    $exe = Join-Path $work 'store-check.exe'
    & $compiler /nologo /target:exe /main:Nikitid.IkeV2ProfileInstaller.StoreCheck "/out:$exe" "/resource:$(Join-Path $root 'VpnProfile.ps1'),VpnProfile.ps1" `
        /r:System.Management.dll /r:System.Windows.Forms.dll /r:System.Drawing.dll /r:System.Xml.dll (Join-Path $root 'Program.cs') (Join-Path $root 'tests\StoreCheck.cs')
    if ($LASTEXITCODE -ne 0) { throw 'The installer failed to build' }
    $eap = '<EapHostConfig xmlns="http://www.microsoft.com/provisioning/EapHostConfig"><EapMethod><Type xmlns="http://www.microsoft.com/provisioning/EapCommon">26</Type><VendorId xmlns="http://www.microsoft.com/provisioning/EapCommon">0</VendorId><VendorType xmlns="http://www.microsoft.com/provisioning/EapCommon">0</VendorType><AuthorId xmlns="http://www.microsoft.com/provisioning/EapCommon">0</AuthorId></EapMethod><Config xmlns="http://www.microsoft.com/provisioning/EapHostConfig"><Eap xmlns="http://www.microsoft.com/provisioning/BaseEapConnectionPropertiesV1"><Type>26</Type><EapType xmlns="http://www.microsoft.com/provisioning/MsChapV2ConnectionPropertiesV1"><UseWinLogonCredentials>false</UseWinLogonCredentials></EapType></Eap></Config></EapHostConfig>'
    $xml = Join-Path $work 'test.vpnv2.xml'
    Set-Content -LiteralPath $xml -Encoding UTF8 -Value ('<VPNProfile><ProfileName>vpn.example.com</ProfileName><RememberCredentials>true</RememberCredentials><AlwaysOn>false</AlwaysOn>' +
        '<DomainNameInformation><DomainName>.</DomainName><DnsServers>10.20.30.1</DnsServers><AutoTrigger>false</AutoTrigger><Persistent>false</Persistent></DomainNameInformation>' +
        '<NativeProfile><Servers>vpn.example.com</Servers><RoutingPolicyType>ForceTunnel</RoutingPolicyType><NativeProtocolType>IKEv2</NativeProtocolType>' +
        '<CryptographySuite><AuthenticationTransformConstants>GCMAES256</AuthenticationTransformConstants><CipherTransformConstants>GCMAES256</CipherTransformConstants><PfsGroup>ECP384</PfsGroup><DHGroup>ECP384</DHGroup><IntegrityCheckMethod>SHA384</IntegrityCheckMethod><EncryptionMethod>AES_GCM_256</EncryptionMethod></CryptographySuite>' +
        "<Authentication><UserMethod>Eap</UserMethod><Eap><Configuration>$eap</Configuration></Eap></Authentication></NativeProfile></VPNProfile>")
    & $exe $xml
    exit $LASTEXITCODE
}
finally { Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue }
