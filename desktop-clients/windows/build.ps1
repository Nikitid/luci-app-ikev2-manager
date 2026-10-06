param([string]$Output = (Join-Path $PSScriptRoot '..\..\build\client-windows'))
$ErrorActionPreference = 'Stop'
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
New-Item -ItemType Directory -Force -Path $Output | Out-Null
$common = @('ManagedHosts.cs', 'ClientPolicy.cs', 'EnrollmentTransport.cs', 'ClientCommands.cs', 'ClientStatusReader.cs') |
    ForEach-Object { Join-Path $PSScriptRoot $_ }
$service = @('EnrollmentRegistration.cs', 'GuardStore.cs', 'WfpGuard.cs', 'GuardRuntime.cs', 'SystemHosts.cs', 'PolicyTransport.cs', 'ManagedVpnProfile.cs', 'OwnedRasConnection.cs', 'OwnedTunnelRoutes.cs', 'RasTunnel.cs', 'RouteObservation.cs', 'ClientCommandServer.cs', 'ClientService.cs') |
    ForEach-Object { Join-Path $PSScriptRoot $_ }
& $compiler /nologo /platform:x64 /optimize+ "/out:$(Join-Path $Output 'ClientService.exe')" `
    "/resource:$(Join-Path $PSScriptRoot 'ManagedVpnProfile.ps1'),ManagedVpnProfile.ps1" `
    /r:System.Web.Extensions.dll /r:System.ServiceProcess.dll /r:System.Security.dll $common $service
if ($LASTEXITCODE -ne 0) { throw 'Client service build failed' }
& $compiler /nologo /platform:x64 /optimize+ /target:winexe "/out:$(Join-Path $Output 'IKEv2ManagerClient.exe')" `
    /r:System.Web.Extensions.dll /r:System.Windows.Forms.dll /r:System.Drawing.dll $common (Join-Path $PSScriptRoot 'ClientApp.cs')
if ($LASTEXITCODE -ne 0) { throw 'Client application build failed' }
Copy-Item (Join-Path $PSScriptRoot 'install.ps1') $Output -Force
