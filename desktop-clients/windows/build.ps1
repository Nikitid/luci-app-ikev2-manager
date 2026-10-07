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
& $compiler /nologo /platform:x64 /optimize+ /target:winexe "/out:$appBinary" "/win32icon:$icon" `
    /r:System.Web.Extensions.dll /r:System.Windows.Forms.dll /r:System.Drawing.dll $stamp $common (Join-Path $PSScriptRoot 'ClientApp.cs')
if ($LASTEXITCODE -ne 0) { throw 'Client application build failed' }
# The one file a user receives: both binaries travel inside it.
& $compiler /nologo /platform:x64 /optimize+ /target:winexe "/out:$(Join-Path $Output 'WaypointSetup.exe')" `
    "/win32manifest:$(Join-Path $PSScriptRoot 'Setup.manifest')" "/win32icon:$icon" `
    "/resource:$serviceBinary,ClientService.exe" "/resource:$appBinary,IKEv2ManagerClient.exe" `
    /r:System.ServiceProcess.dll /r:System.Windows.Forms.dll /r:System.Drawing.dll $stamp (Join-Path $PSScriptRoot 'Setup.cs')
if ($LASTEXITCODE -ne 0) { throw 'Client installer build failed' }
Remove-Item -LiteralPath $stamp
