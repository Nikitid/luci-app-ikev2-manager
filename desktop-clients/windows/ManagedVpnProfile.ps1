# Embedded in the service binary. Input contains policy metadata, never EAP secrets.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
try {
    $inputDocument = [Console]::In.ReadToEnd() | ConvertFrom-Json
    $owner = [Guid]::ParseExact($inputDocument.owner, 'N')
    if ($owner -eq [Guid]::Empty) { throw 'Invalid owner' }
    $name = 'Private Lane ' + $owner.ToString('N')
    Import-Module (Join-Path $PSHOME 'Modules\VpnClient') -ErrorAction Stop
    if ($inputDocument.operation -eq 'remove') {
        $entry = [Guid]::Parse($inputDocument.entry_id)
        if ($entry -eq [Guid]::Empty) { throw 'Invalid entry' }
        $owned = @(Get-VpnConnection -AllUserConnection | Where-Object Name -CEQ $name)
        if ($owned.Count -ne 1 -or [Guid]$owned[0].Guid -ne $entry) { throw 'Owned entry mismatch' }
        Remove-VpnConnection -Name $name -AllUserConnection -Force
        [Console]::Out.Write($entry.ToString('D'))
        exit 0
    }
    if ($inputDocument.operation -eq 'names') {
        # One owned set of name resolution rules, replaced whole. Each domain is
        # listed as itself and as a suffix, so it and everything under it ask
        # the resolver that exists only inside the tunnel.
        Import-Module (Join-Path $PSHOME 'Modules\DnsClient') -ErrorAction Stop
        $domains = @($inputDocument.domains)
        if ($domains.Count -gt 4096) { throw 'Too many names' }
        foreach ($domain in $domains) {
            if ($domain -cnotmatch '^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$' -or $domain.Length -gt 253) { throw 'Invalid name' }
        }
        $wanted = @()
        if ($domains.Count) {
            $resolver = [Net.IPAddress]::Parse([string]$inputDocument.resolver)
            $bytes = $resolver.GetAddressBytes()
            if ($resolver.ToString() -cne $inputDocument.resolver -or $bytes.Length -ne 4 -or
                -not ($bytes[0] -eq 10 -or ($bytes[0] -eq 172 -and $bytes[1] -ge 16 -and $bytes[1] -le 31) -or ($bytes[0] -eq 192 -and $bytes[1] -eq 168))) { throw 'Invalid resolver' }
            $wanted = @($domains | ForEach-Object { $_; '.' + $_ } | Sort-Object -Unique)
        }
        $owned = @(Get-DnsClientNrptRule | Where-Object Comment -CEQ $name)
        $current = @($owned | ForEach-Object { $_.Namespace } | Sort-Object -Unique)
        $servers = @($owned | ForEach-Object { $_.NameServers } | Sort-Object -Unique)
        if (($current -join ' ') -cne ($wanted -join ' ') -or ($wanted.Count -and ($servers -join ' ') -cne [string]$inputDocument.resolver)) {
            foreach ($rule in $owned) { Remove-DnsClientNrptRule -Name $rule.Name -Force }
            for ($index = 0; $index -lt $wanted.Count; $index += 200) {
                $last = [Math]::Min($index + 199, $wanted.Count - 1)
                Add-DnsClientNrptRule -Namespace $wanted[$index..$last] -NameServers ([string]$inputDocument.resolver) -Comment $name | Out-Null
            }
            Clear-DnsClientCache
        }
        $applied = @(Get-DnsClientNrptRule | Where-Object Comment -CEQ $name | ForEach-Object { $_.Namespace } | Sort-Object -Unique)
        if (($applied -join ' ') -cne ($wanted -join ' ')) { throw 'Name policy incomplete' }
        [Console]::Out.Write('names-applied')
        exit 0
    }
    if ($inputDocument.operation -ne 'ensure') { throw 'Invalid operation' }
    $server = [string]$inputDocument.server
    if ($server -cnotmatch '^[a-z0-9][a-z0-9.-]{1,251}[a-z0-9]$' -or $server -notmatch '\.' -or $server -match '^[0-9.]+$') { throw 'Invalid server' }
    $prefixes = @($inputDocument.addresses | ForEach-Object {
        # One address, or a network written at its base as a.b.c.d/len.
        $parts = ([string]$_).Split('/')
        if ($parts.Count -gt 2) { throw 'Invalid route' }
        $address = [Net.IPAddress]::Parse($parts[0])
        if ($address.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or $address.ToString() -cne $parts[0]) { throw 'Invalid route' }
        $bytes = $address.GetAddressBytes()
        if (-not ($bytes[0] -eq 10 -or ($bytes[0] -eq 172 -and $bytes[1] -ge 16 -and $bytes[1] -le 31) -or ($bytes[0] -eq 192 -and $bytes[1] -eq 168))) { throw 'Non-private route' }
        if ($parts.Count -eq 1) { $_ + '/32' }
        elseif ($parts[1] -cmatch '^(1[6-9]|2[0-9]|3[01])$') { [string]$_ }
        else { throw 'Invalid route' }
    })
    if ($prefixes.Count -lt 1 -or $prefixes.Count -gt 4096 -or @($prefixes | Select-Object -Unique).Count -ne $prefixes.Count) { throw 'Invalid routes' }
    $existing = @(Get-VpnConnection -AllUserConnection | Where-Object Name -CEQ $name)
    if ($existing.Count -gt 1) { throw 'Ambiguous owner' }
    if ($existing.Count -eq 0) {
        if ($inputDocument.entry_id) { throw 'Owned profile missing' }
        $eap = New-EapConfiguration
        Add-VpnConnection -Name $name -ServerAddress $server -TunnelType Ikev2 -EncryptionLevel Maximum `
            -AuthenticationMethod Eap -EapConfigXmlStream $eap.EapConfigXmlStream -SplitTunneling `
            -AllUserConnection -RememberCredential:$false -Force | Out-Null
        $existing = @(Get-VpnConnection -AllUserConnection | Where-Object Name -CEQ $name)
    }
    $profile = $existing[0]
    if (-not $inputDocument.entry_id -and $profile.EncryptionLevel -eq 'Maximum' -and
        $profile.ServerAddress -ceq $server -and $profile.TunnelType -eq 'Ikev2' -and $profile.SplitTunneling) {
        # Recover an interrupted first creation before the GUID was journaled.
        Set-VpnConnectionIPsecConfiguration -ConnectionName $name -AllUserConnection `
            -AuthenticationTransformConstants SHA256128 -CipherTransformConstants AES256 `
            -EncryptionMethod AES256 -IntegrityCheckMethod SHA256 -DHGroup Group14 -PfsGroup PFS2048 -Force | Out-Null
        $profile = Get-VpnConnection -Name $name -AllUserConnection
    }
    if ($profile.ServerAddress -cne $server -or $profile.TunnelType -ne 'Ikev2' -or -not $profile.SplitTunneling -or
        $profile.EncryptionLevel -ne 'Custom' -or $profile.UseWinlogonCredential -or $profile.RememberCredential -or
        @($profile.AuthenticationMethod).Count -ne 1 -or $profile.AuthenticationMethod[0] -ne 'Eap' -or
        ($inputDocument.entry_id -and [Guid]$profile.Guid -ne [Guid]::Parse($inputDocument.entry_id))) { throw 'Owned profile changed' }
    $suite = @($profile.IPSecCustomPolicy)
    if ($suite.Count -ne 1 -or $suite[0].AuthenticationTransformConstants -ne 'SHA256128' -or
        $suite[0].CipherTransformConstants -ne 'AES256' -or $suite[0].EncryptionMethod -ne 'AES256' -or
        $suite[0].IntegrityCheckMethod -ne 'SHA256' -or $suite[0].DHGroup -ne 'Group14' -or $suite[0].PfsGroup -ne 'PFS2048') { throw 'Owned crypto policy changed' }
    $routes = @($profile.Routes)
    foreach ($route in $routes) {
        if ($route.DestinationPrefix -notin $prefixes) {
            Remove-VpnConnectionRoute -ConnectionName $name -AllUserConnection -DestinationPrefix $route.DestinationPrefix -Confirm:$false | Out-Null
        }
    }
    foreach ($prefix in $prefixes) {
        if (-not ($routes | Where-Object DestinationPrefix -EQ $prefix)) {
            Add-VpnConnectionRoute -ConnectionName $name -AllUserConnection -DestinationPrefix $prefix -RouteMetric 1 | Out-Null
        }
    }
    $profile = Get-VpnConnection -Name $name -AllUserConnection
    if (@($profile.Routes).Count -ne $prefixes.Count -or @($profile.Routes | Where-Object DestinationPrefix -NotIn $prefixes).Count) { throw 'Route update incomplete' }
    [Console]::Out.Write(([Guid]$profile.Guid).ToString('D'))
    exit 0
} catch {
    # Provider diagnostics can contain private metadata. Only fixed errors escape.
    [Console]::Error.Write('Managed VPN profile unavailable')
    exit 1
}
