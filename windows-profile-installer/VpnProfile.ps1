param(
    [Parameter(Mandatory)] [ValidateSet('install', 'remove', 'status')] [string]$Operation,
    [Parameter(Mandatory)] [string]$Profile,
    [string]$Name
)
# The VPN connection a VPNv2 XML profile describes, made for the user who runs
# this, with Windows' own VPN commands: no administrator, no MDM bridge, and
# nothing that stays in force while the connection is down. Prints one line
# of JSON: ok, what was done, and whether the connection takes all names.
$ErrorActionPreference = 'Stop'
Import-Module VpnClient

function Answer([bool]$ok, [string]$message, [hashtable]$extra = @{}) {
    $extra.ok = $ok; $extra.message = $message
    [Console]::Out.WriteLine(($extra | ConvertTo-Json -Compress))
    exit ([int](-not $ok))
}

try {
    $document = New-Object System.Xml.XmlDocument
    $document.XmlResolver = $null
    $document.Load($Profile)
    $root = $document.DocumentElement
    if ($root.Name -ne 'VPNProfile') { Answer $false 'Файл не является VPNv2-профилем Windows.' }
    if (-not $Name) { $Name = $root.ProfileName.Trim() }
    if (-not $Name -or $Name.Length -gt 128 -or $Name -match '[\\/:*?"<>|;\p{C}]') { Answer $false 'Имя VPN-профиля содержит недопустимые символы.' }

    $existing = Get-VpnConnection -Name $Name -ErrorAction SilentlyContinue
    if ($Operation -eq 'status') { Answer $true $(if ($existing) { 'installed' } else { 'absent' }) @{ installed = [bool]$existing } }
    if ($Operation -eq 'remove') {
        if ($existing) { Remove-VpnConnection -Name $Name -Force }
        Answer $true 'Профиль удалён.'
    }

    $server = $root.NativeProfile.Servers.Trim()
    if (-not $server -or $server.Length -gt 253 -or $server -match '[/\\@\s]') { Answer $false 'Некорректное имя VPN-сервера.' }
    $split = $root.NativeProfile.RoutingPolicyType -ne 'ForceTunnel'
    $dns = @(($root.DomainNameInformation.DnsServers -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    foreach ($address in $dns) { if (-not ($address -as [ipaddress])) { Answer $false 'Некорректный адрес DNS в VPN-профиле.' } }
    $routes = @($root.SelectNodes('/VPNProfile/Route') | ForEach-Object { '{0}/{1}' -f $_.Address.Trim(), $_.PrefixSize.Trim() })
    $eapNode = $root.SelectSingleNode('/VPNProfile/NativeProfile/Authentication/Eap/Configuration/*')
    if (-not $eapNode) { Answer $false 'В профиле отсутствует настройка EAP.' }
    $eap = New-Object System.Xml.XmlDocument
    $eap.AppendChild($eap.ImportNode($eapNode, $true)) | Out-Null
    $suite = $root.NativeProfile.CryptographySuite

    # A profile of the same name is replaced whole, whoever made it.
    if ($existing) { Remove-VpnConnection -Name $Name -Force }
    Add-VpnConnection -Name $Name -ServerAddress $server -TunnelType Ikev2 -EncryptionLevel Maximum `
        -AuthenticationMethod Eap -EapConfigXmlStream $eap -SplitTunneling:$split -RememberCredential -Force
    if ($suite) {
        Set-VpnConnectionIPsecConfiguration -ConnectionName $Name -AuthenticationTransformConstants $suite.AuthenticationTransformConstants `
            -CipherTransformConstants $suite.CipherTransformConstants -EncryptionMethod ($suite.EncryptionMethod -replace '_', '' -replace 'AESGCM', 'GCMAES') `
            -IntegrityCheckMethod $suite.IntegrityCheckMethod -DHGroup $suite.DHGroup -PfsGroup $suite.PfsGroup -Force
    }
    # Split: only the networks the server serves go through the tunnel.
    if ($split) { foreach ($route in $routes) { Add-VpnConnectionRoute -ConnectionName $Name -DestinationPrefix $route } }
    # Names go to the server's resolver while connected, and only then: the
    # connection's interface comes first. The rule that takes all names (".")
    # cannot be given to a connection without an administrator, and a rule of
    # the machine would outlive the connection.
    $book = Join-Path $env:APPDATA 'Microsoft\Network\Connections\Pbk\rasphone.pbk'
    $names = $false
    if (Test-Path -LiteralPath $book) {
        # The book is kept in the encoding Windows wrote it in.
        $raw = [IO.File]::ReadAllBytes($book)
        $encoding = if ($raw.Length -ge 2 -and $raw[0] -eq 0xFF -and $raw[1] -eq 0xFE) { 'Unicode' } elseif ($raw.Length -ge 3 -and $raw[0] -eq 0xEF -and $raw[1] -eq 0xBB) { 'UTF8' } else { 'Default' }
        $lines = [Collections.Generic.List[string]]@(Get-Content -LiteralPath $book -Encoding $encoding)
        $start = $lines.IndexOf('[' + $Name + ']')
        if ($start -ge 0) {
            $end = $start + 1
            while ($end -lt $lines.Count -and -not $lines[$end].StartsWith('[')) { $end++ }
            $at = -1
            for ($index = $start + 1; $index -lt $end; $index++) { if ($lines[$index] -like 'IpInterfaceMetric=*') { $at = $index } }
            if ($at -ge 0) { $lines[$at] = 'IpInterfaceMetric=1' } else { $lines.Insert($end, 'IpInterfaceMetric=1') }
            Set-Content -LiteralPath $book -Value $lines -Encoding $encoding
            $names = $true
        }
    }

    $made = Get-VpnConnection -Name $Name
    if (-not $made -or $made.TunnelType -ne 'Ikev2' -or $made.ServerAddress -ne $server -or $made.SplitTunneling -ne $split -or
        $made.AuthenticationMethod -notcontains 'Eap') { Answer $false 'Windows не вернула установленный профиль при проверке.' }
    $madeRoutes = @($made.Routes | ForEach-Object { $_.DestinationPrefix })
    if ($split -and @($routes | Where-Object { $madeRoutes -notcontains $_ }).Count -gt 0) { Answer $false 'Маршруты профиля не установлены.' }
    Answer $true 'Профиль установлен и проверен. Откройте VPN и подключитесь.' @{ names = $names; namesError = $namesError; split = $split; routes = $routes.Count }
}
catch { Answer $false ('Windows отказала: ' + $_.Exception.Message) }
