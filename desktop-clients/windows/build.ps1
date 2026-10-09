param([string]$Output = (Join-Path $PSScriptRoot '..\..\build\client-windows'), [string]$Version = '0.0.0')
$ErrorActionPreference = 'Stop'
if ($Version -notmatch '^\d{1,4}\.\d{1,4}\.\d{1,4}$') { throw 'Version must be X.Y.Z' }
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
New-Item -ItemType Directory -Force -Path $Output | Out-Null
$stamp = Join-Path $Output 'Version.cs'
Set-Content -LiteralPath $stamp -Encoding ASCII -Value @(
    "[assembly: System.Reflection.AssemblyVersion(`"$Version.0`")]",
    "[assembly: System.Reflection.AssemblyFileVersion(`"$Version.0`")]",
    '[assembly: System.Reflection.AssemblyProduct("Waypoint")]')
$common = @('ManagedHosts.cs', 'ClientPolicy.cs', 'EnrollmentTransport.cs', 'ClientCommands.cs', 'ClientStatusReader.cs') |
    ForEach-Object { Join-Path $PSScriptRoot $_ }
$service = @('EnrollmentRegistration.cs', 'GuardStore.cs', 'WfpGuard.cs', 'GuardRuntime.cs', 'SystemHosts.cs', 'PolicyTransport.cs', 'ManagedVpnProfile.cs', 'OwnedRasConnection.cs', 'OwnedTunnelRoutes.cs', 'RasTunnel.cs', 'RouteObservation.cs', 'ClientCommandServer.cs', 'ClientService.cs') |
    ForEach-Object { Join-Path $PSScriptRoot $_ }
$serviceBinary = Join-Path $Output 'ClientService.exe'
$appBinary = Join-Path $Output 'IKEv2ManagerClient.exe'
$icon = Join-Path $PSScriptRoot '..\assets\Waypoint.ico'
& $compiler /nologo /platform:x64 /optimize+ "/out:$serviceBinary" `
    "/resource:$(Join-Path $PSScriptRoot 'ManagedVpnProfile.ps1'),ManagedVpnProfile.ps1" `
    /r:System.Web.Extensions.dll /r:System.ServiceProcess.dll /r:System.Security.dll $stamp $common $service
if ($LASTEXITCODE -ne 0) { throw 'Client service build failed' }
# The service is the one program that dials, and on Windows on ARM it has to
# be an ARM64 image. Started as x64 under emulation, or as a program built for
# any processor, it is given the connection but Windows refuses to load the
# EAP method into it and every dial ends with error 691; an ARM64 image
# connects. The service holds no machine code, only what the runtime compiles,
# so its ARM64 image is the same file with the processor named in its header -
# what a compiler asked for ARM64 writes. This compiler cannot be asked.
$serviceArm = Join-Path $Output 'ClientService.arm64.exe'
$image = [IO.File]::ReadAllBytes($serviceBinary)
$header = [BitConverter]::ToInt32($image, 0x3c)
if ([BitConverter]::ToUInt32($image, $header) -ne 0x4550 -or [BitConverter]::ToUInt16($image, $header + 4) -ne 0x8664 -or
    [BitConverter]::ToUInt16($image, $header + 24) -ne 0x20b) { throw 'Client service image is not what an x64 build writes' }
# That holds only while the image is nothing but managed code. Its runtime
# header says so; anything else must not be relabelled.
$sections = [BitConverter]::ToUInt16($image, $header + 6)
$table = $header + 24 + [BitConverter]::ToUInt16($image, $header + 20)
$runtime = [BitConverter]::ToUInt32($image, $header + 24 + 112 + 14 * 8)
$flags = $null
for ($index = 0; $index -lt $sections; $index++) {
    $entry = $table + 40 * $index
    $start = [BitConverter]::ToUInt32($image, $entry + 12); $size = [BitConverter]::ToUInt32($image, $entry + 8)
    if ($runtime -ge $start -and $runtime -lt $start + $size) {
        $flags = [BitConverter]::ToUInt32($image, [BitConverter]::ToUInt32($image, $entry + 20) + ($runtime - $start) + 16)
    }
}
if ($runtime -eq 0 -or $flags -eq $null -or ($flags -band 0x1) -eq 0 -or ($flags -band 0x12) -ne 0) {
    throw 'Client service image is not managed code alone; it cannot be relabelled for ARM64'
}
$image[$header + 4] = 0x64; $image[$header + 5] = 0xAA
[IO.File]::WriteAllBytes($serviceArm, $image)
& $compiler /nologo /platform:x64 /optimize+ /target:winexe "/out:$appBinary" "/win32icon:$icon" `
    /r:System.Web.Extensions.dll /r:System.Windows.Forms.dll /r:System.Drawing.dll $stamp $common (Join-Path $PSScriptRoot 'ClientApp.cs')
if ($LASTEXITCODE -ne 0) { throw 'Client application build failed' }
# The one file a user receives: both binaries travel inside it.
& $compiler /nologo /platform:x64 /optimize+ /target:winexe "/out:$(Join-Path $Output 'WaypointSetup.exe')" `
    "/win32manifest:$(Join-Path $PSScriptRoot 'Setup.manifest')" "/win32icon:$icon" `
    "/resource:$serviceBinary,ClientService.exe" "/resource:$serviceArm,ClientService.arm64.exe" "/resource:$appBinary,IKEv2ManagerClient.exe" `
    /r:System.ServiceProcess.dll /r:System.Windows.Forms.dll /r:System.Drawing.dll $stamp (Join-Path $PSScriptRoot 'Setup.cs')
if ($LASTEXITCODE -ne 0) { throw 'Client installer build failed' }
Remove-Item -LiteralPath $stamp
