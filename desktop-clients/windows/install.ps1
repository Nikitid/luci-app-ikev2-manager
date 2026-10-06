# Install or update the guard service without deleting enrolled state or filters.
$ErrorActionPreference = 'Stop'
if (-not [Environment]::Is64BitProcess) { throw 'Run the installer in 64-bit Windows PowerShell' }
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not (New-Object Security.Principal.WindowsPrincipal $identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this installer as administrator'
}
$name = 'IKEv2ManagerClient'
$programFiles = [Environment]::GetFolderPath('ProgramFiles')
$systemDirectory = [Environment]::GetFolderPath('System')
$permissionsTool = Join-Path $systemDirectory 'icacls.exe'
$destination = Join-Path $programFiles 'IKEv2 Manager Client'
$servicePath = Join-Path $destination 'ClientService.exe'
$expectedCommand = '"' + $servicePath + '"'
foreach ($binary in @('ClientService.exe','IKEv2ManagerClient.exe')) {
    $source = Join-Path $PSScriptRoot $binary
    if (-not (Test-Path -LiteralPath $source -PathType Leaf) -or
        ((Get-Item -LiteralPath $source).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Client distribution is incomplete' }
}
foreach ($path in @($programFiles,$destination,$servicePath,(Join-Path $destination 'IKEv2ManagerClient.exe'))) {
    if ((Test-Path -LiteralPath $path) -and ((Get-Item -LiteralPath $path).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'Client installation contains a redirected path'
    }
}
$existing = Get-CimInstance Win32_Service -Filter "Name='$name'"
if ($existing -and ($existing.PathName -ne $expectedCommand -or $existing.StartName -ne 'LocalSystem')) {
    throw 'An unrelated service owns the client service name'
}
$security = New-Object Security.AccessControl.DirectorySecurity
$security.SetAccessRuleProtection($true,$false)
$security.SetOwner((New-Object Security.Principal.SecurityIdentifier 'S-1-5-32-544'))
foreach ($sid in @('S-1-5-32-544','S-1-5-18','S-1-5-32-545')) {
    $rights = if ($sid -eq 'S-1-5-32-545') { 'ReadAndExecute' } else { 'FullControl' }
    $security.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(
        (New-Object Security.Principal.SecurityIdentifier $sid),$rights,'ContainerInherit,ObjectInherit','None','Allow')))
}
if ($existing) { Stop-Service $name; (Get-Service $name).WaitForStatus('Stopped',[TimeSpan]::FromSeconds(40)) }
New-Item -ItemType Directory -Force $destination | Out-Null
Set-Acl -LiteralPath $destination -AclObject $security
foreach ($binary in @('ClientService.exe','IKEv2ManagerClient.exe')) {
    if (Test-Path -LiteralPath (Join-Path $destination $binary)) {
        & $permissionsTool (Join-Path $destination $binary) /reset | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Existing client binary permissions could not be secured' }
    }
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $binary) -Destination (Join-Path $destination $binary) -Force
    # Existing files may carry explicit ACLs; reset them to the protected parent.
    & $permissionsTool (Join-Path $destination $binary) /reset | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Client binary permissions could not be secured' }
}
if (-not $existing) {
    New-Service -Name $name -DisplayName 'IKEv2 Manager Client' -BinaryPathName $expectedCommand -StartupType Automatic | Out-Null
} else { Set-Service $name -StartupType Automatic }
& (Join-Path $systemDirectory 'sc.exe') failure $name reset= 86400 actions= restart/5000/restart/15000/restart/60000 | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Client service recovery could not be configured' }
Start-Service $name
(Get-Service $name).WaitForStatus('Running',[TimeSpan]::FromSeconds(15))
$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut((Join-Path ([Environment]::GetFolderPath('CommonPrograms')) 'IKEv2 Manager Client.lnk'))
$shortcut.TargetPath = Join-Path $destination 'IKEv2ManagerClient.exe'
$shortcut.WorkingDirectory = $destination
$shortcut.Save()
Write-Output 'Client service installed. Open IKEv2 Manager Client to register this device.'
