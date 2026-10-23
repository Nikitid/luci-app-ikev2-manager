param([switch]$Wfp, [switch]$EnrollmentStorage, [switch]$Profiles)

$ErrorActionPreference = 'Stop'
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$output = Join-Path $PSScriptRoot '..\..\build\client-windows'
New-Item -ItemType Directory -Force -Path $output | Out-Null
$executable = Join-Path $output 'HostsTests.exe'
& $compiler /nologo "/out:$executable" /r:System.Web.Extensions.dll `
    (Join-Path $PSScriptRoot 'ManagedHosts.cs') (Join-Path $PSScriptRoot 'HostsTests.cs')
if ($LASTEXITCODE -ne 0) { throw 'Client tests failed to compile' }
& $executable (Join-Path $PSScriptRoot '..\fixtures\hosts.json')
if ($LASTEXITCODE -ne 0) { throw 'Client behavior tests failed' }

# The builds on current .NET read and write JSON through JsonCompat.cs; it has
# to give what the .NET Framework serializer gives, on the same inputs.
$dotnet = if ($env:WAYPOINT_DOTNET) { $env:WAYPOINT_DOTNET } else { (Get-Command dotnet -ErrorAction SilentlyContinue).Source }
if (-not $dotnet -or -not (Test-Path $dotnet)) { throw '.NET SDK not found; set WAYPOINT_DOTNET or put dotnet on PATH' }
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'; $env:DOTNET_NOLOGO = '1'
$fixtures = @((Join-Path $PSScriptRoot '..\fixtures\policies.json'), (Join-Path $PSScriptRoot '..\fixtures\policy-histories.json'))
$compatExecutable = Join-Path $output 'JsonCompatTests.exe'
& $compiler /nologo "/out:$compatExecutable" /r:System.Web.Extensions.dll (Join-Path $PSScriptRoot 'JsonCompatTests.cs')
if ($LASTEXITCODE -ne 0) { throw 'JSON compatibility tests failed to compile' }
& $compatExecutable @fixtures (Join-Path $output 'json-framework.txt')
if ($LASTEXITCODE -ne 0) { throw 'JSON compatibility tests failed on .NET Framework' }
& $dotnet build (Join-Path $PSScriptRoot 'compat\JsonCompatTests.csproj') -c Release -o (Join-Path $output 'compat') --nologo -v quiet
if ($LASTEXITCODE -ne 0) { throw 'JSON compatibility tests failed to build on current .NET' }
& $dotnet (Join-Path $output 'compat\JsonCompatTests.dll') @fixtures (Join-Path $output 'json-current.txt')
if ($LASTEXITCODE -ne 0) { throw 'JSON compatibility tests failed on current .NET' }
$framework = Get-Content (Join-Path $output 'json-framework.txt'); $current = Get-Content (Join-Path $output 'json-current.txt')
$differences = Compare-Object $framework $current -SyncWindow 0
if ($differences) { $differences | Select-Object -First 80 | Format-Table -AutoSize | Out-String -Width 400 | Write-Host; throw 'JSON on current .NET differs from .NET Framework' }
Write-Host "JSON compatibility checks passed: $($framework.Count) lines the same on both"

# Compile native enforcement on every run; execute only when explicitly selected.
$guardExecutable = Join-Path $output 'WfpGuardTests.exe'
& $compiler /nologo "/resource:$(Join-Path $PSScriptRoot 'ManagedVpnProfile.ps1'),ManagedVpnProfile.ps1" /platform:x64 "/out:$guardExecutable" /r:System.Web.Extensions.dll /r:System.ServiceProcess.dll /r:System.Security.dll `
    (Join-Path $PSScriptRoot 'ClientPolicy.cs') (Join-Path $PSScriptRoot 'ManagedHosts.cs') (Join-Path $PSScriptRoot 'ProblemReports.cs') `
    (Join-Path $PSScriptRoot 'WfpGuard.cs') (Join-Path $PSScriptRoot 'GuardStore.cs') (Join-Path $PSScriptRoot 'GuardRuntime.cs') (Join-Path $PSScriptRoot 'SystemHosts.cs') (Join-Path $PSScriptRoot 'OwnedRasConnection.cs') (Join-Path $PSScriptRoot 'OwnedTunnelRoutes.cs') (Join-Path $PSScriptRoot 'ManagedVpnProfile.cs') (Join-Path $PSScriptRoot 'PolicyTransport.cs') `
    (Join-Path $PSScriptRoot 'EnrollmentRegistration.cs') (Join-Path $PSScriptRoot 'EnrollmentTransport.cs') `
    (Join-Path $PSScriptRoot 'ClientCommands.cs') (Join-Path $PSScriptRoot 'ServiceIntegrationTests.cs') (Join-Path $PSScriptRoot 'RestrictedAccessTests.cs') `
    (Join-Path $PSScriptRoot 'ClientStatusReader.cs') `
    (Join-Path $PSScriptRoot 'RasTunnel.cs') (Join-Path $PSScriptRoot 'RouteObservation.cs') `
    (Join-Path $PSScriptRoot 'PolicyJournalTests.cs') (Join-Path $PSScriptRoot 'EnrollmentGuardTests.cs') (Join-Path $PSScriptRoot 'NetworkGuardTests.cs') `
    (Join-Path $PSScriptRoot 'WfpGuardTests.cs')
if ($LASTEXITCODE -ne 0) { throw 'WFP tests failed to compile' }
$serviceExecutable = Join-Path $output 'ClientService.exe'
& $compiler /nologo "/resource:$(Join-Path $PSScriptRoot 'ManagedVpnProfile.ps1'),ManagedVpnProfile.ps1" /platform:x64 "/out:$serviceExecutable" /r:System.Web.Extensions.dll /r:System.ServiceProcess.dll /r:System.Security.dll `
    (Join-Path $PSScriptRoot 'ClientPolicy.cs') (Join-Path $PSScriptRoot 'ManagedHosts.cs') (Join-Path $PSScriptRoot 'ProblemReports.cs') `
    (Join-Path $PSScriptRoot 'WfpGuard.cs') (Join-Path $PSScriptRoot 'GuardStore.cs') `
    (Join-Path $PSScriptRoot 'GuardRuntime.cs') (Join-Path $PSScriptRoot 'SystemHosts.cs') (Join-Path $PSScriptRoot 'OwnedRasConnection.cs') (Join-Path $PSScriptRoot 'OwnedTunnelRoutes.cs') (Join-Path $PSScriptRoot 'RasTunnel.cs') (Join-Path $PSScriptRoot 'RouteObservation.cs') (Join-Path $PSScriptRoot 'ManagedVpnProfile.cs') (Join-Path $PSScriptRoot 'PolicyTransport.cs') `
    (Join-Path $PSScriptRoot 'EnrollmentRegistration.cs') (Join-Path $PSScriptRoot 'EnrollmentTransport.cs') (Join-Path $PSScriptRoot 'ClientCommands.cs') (Join-Path $PSScriptRoot 'ClientCommandServer.cs') `
    (Join-Path $PSScriptRoot 'ClientService.cs')
if ($LASTEXITCODE -ne 0) { throw 'Client service failed to compile' }
$rasExecutable = Join-Path $output 'RasTunnelTests.exe'
& $compiler /nologo /platform:x64 "/out:$rasExecutable" `
    (Join-Path $PSScriptRoot 'WfpGuard.cs') (Join-Path $PSScriptRoot 'RasTunnel.cs') (Join-Path $PSScriptRoot 'RouteObservation.cs') `
    (Join-Path $PSScriptRoot 'RasTunnelTests.cs')
if ($LASTEXITCODE -ne 0) { throw 'RAS observation tests failed to compile' }
& $rasExecutable
if ($LASTEXITCODE -ne 0) { throw 'RAS observation tests failed' }
$statusExecutable = Join-Path $output 'ClientStatusTests.exe'
& $compiler /nologo /platform:x64 "/out:$statusExecutable" /r:System.Web.Extensions.dll `
    (Join-Path $PSScriptRoot 'ClientStatusReader.cs') (Join-Path $PSScriptRoot 'ClientStatusTests.cs')
if ($LASTEXITCODE -ne 0) { throw 'Status tests failed to compile' }
& $statusExecutable
if ($LASTEXITCODE -ne 0) { throw 'Client status tests failed' }
$reportsExecutable = Join-Path $output 'ProblemReportsTests.exe'
& $compiler /nologo /platform:x64 "/out:$reportsExecutable" /r:System.Web.Extensions.dll `
    (Join-Path $PSScriptRoot 'ProblemReports.cs') (Join-Path $PSScriptRoot 'ProblemReportsTests.cs')
if ($LASTEXITCODE -ne 0) { throw 'Problem report tests failed to compile' }
& $reportsExecutable
if ($LASTEXITCODE -ne 0) { throw 'Problem report tests failed' }
$policyExecutable = Join-Path $output 'ClientPolicyTests.exe'
& $compiler /nologo /platform:x64 "/out:$policyExecutable" /r:System.Web.Extensions.dll `
    (Join-Path $PSScriptRoot 'ManagedHosts.cs') `
    (Join-Path $PSScriptRoot 'ClientPolicy.cs') (Join-Path $PSScriptRoot 'ClientPolicyTests.cs')
if ($LASTEXITCODE -ne 0) { throw 'Policy tests failed to compile' }
& $policyExecutable (Join-Path $PSScriptRoot '..\fixtures\policies.json')
if ($LASTEXITCODE -ne 0) { throw 'Client policy tests failed' }
$transportExecutable = Join-Path $output 'PolicyTransportTests.exe'
& $compiler /nologo /platform:x64 "/out:$transportExecutable" /r:System.Web.Extensions.dll `
    (Join-Path $PSScriptRoot 'ManagedHosts.cs') (Join-Path $PSScriptRoot 'ClientPolicy.cs') `
    (Join-Path $PSScriptRoot 'PolicyTransport.cs') (Join-Path $PSScriptRoot 'PolicyTransportTests.cs')
if ($LASTEXITCODE -ne 0) { throw 'Policy transport tests failed to compile' }
& $transportExecutable (Join-Path $PSScriptRoot '..\fixtures\policies.json')
if ($LASTEXITCODE -ne 0) { throw 'Policy transport tests failed' }
$enrollmentExecutable = Join-Path $output 'EnrollmentTransportTests.exe'
& $compiler /nologo /platform:x64 "/out:$enrollmentExecutable" /r:System.Web.Extensions.dll `
    (Join-Path $PSScriptRoot 'ManagedHosts.cs') (Join-Path $PSScriptRoot 'ClientPolicy.cs') `
    (Join-Path $PSScriptRoot 'EnrollmentTransport.cs') (Join-Path $PSScriptRoot 'EnrollmentTransportTests.cs')
if ($LASTEXITCODE -ne 0) { throw 'Enrollment transport tests failed to compile' }
& $enrollmentExecutable (Join-Path $PSScriptRoot '..\fixtures\policies.json')
if ($LASTEXITCODE -ne 0) { throw 'Enrollment transport tests failed' }
$commandsExecutable = Join-Path $output 'ClientCommandsTests.exe'
& $compiler /nologo /platform:x64 "/out:$commandsExecutable" /r:System.Web.Extensions.dll `
    (Join-Path $PSScriptRoot 'ClientPolicy.cs') (Join-Path $PSScriptRoot 'ManagedHosts.cs') (Join-Path $PSScriptRoot 'ProblemReports.cs') `
    (Join-Path $PSScriptRoot 'EnrollmentTransport.cs') (Join-Path $PSScriptRoot 'ClientCommands.cs') `
    (Join-Path $PSScriptRoot 'ClientCommandsTests.cs')
if ($LASTEXITCODE -ne 0) { throw 'Control protocol tests failed to compile' }
& $commandsExecutable
if ($LASTEXITCODE -ne 0) { throw 'Control protocol tests failed' }
$integrationExecutable = Join-Path $output 'PolicyTransportIntegrationTests.exe'
& $compiler /nologo "/resource:$(Join-Path $PSScriptRoot 'ManagedVpnProfile.ps1'),ManagedVpnProfile.ps1" /platform:x64 "/out:$integrationExecutable" /r:System.Web.Extensions.dll /r:System.Security.dll `
    (Join-Path $PSScriptRoot 'ManagedHosts.cs') (Join-Path $PSScriptRoot 'ClientPolicy.cs') `
    (Join-Path $PSScriptRoot 'PolicyTransport.cs') (Join-Path $PSScriptRoot 'WfpGuard.cs') `
    (Join-Path $PSScriptRoot 'GuardStore.cs') (Join-Path $PSScriptRoot 'GuardRuntime.cs') (Join-Path $PSScriptRoot 'SystemHosts.cs') (Join-Path $PSScriptRoot 'OwnedRasConnection.cs') (Join-Path $PSScriptRoot 'OwnedTunnelRoutes.cs') (Join-Path $PSScriptRoot 'ManagedVpnProfile.cs') `
    (Join-Path $PSScriptRoot 'EnrollmentRegistration.cs') (Join-Path $PSScriptRoot 'EnrollmentTransport.cs') `
    (Join-Path $PSScriptRoot 'RasTunnel.cs') (Join-Path $PSScriptRoot 'RouteObservation.cs') `
    (Join-Path $PSScriptRoot 'PolicyTransportIntegrationTests.cs')
if ($LASTEXITCODE -ne 0) { throw 'Policy integration executable failed to compile' }
$enrollmentIntegration = Join-Path $output 'EnrollmentIntegrationTests.exe'
& $compiler /nologo "/resource:$(Join-Path $PSScriptRoot 'ManagedVpnProfile.ps1'),ManagedVpnProfile.ps1" /platform:x64 "/out:$enrollmentIntegration" /r:System.Web.Extensions.dll /r:System.ServiceProcess.dll /r:System.Security.dll `
    (Join-Path $PSScriptRoot 'ManagedHosts.cs') (Join-Path $PSScriptRoot 'ClientPolicy.cs') `
    (Join-Path $PSScriptRoot 'EnrollmentTransport.cs') (Join-Path $PSScriptRoot 'EnrollmentRegistration.cs') `
    (Join-Path $PSScriptRoot 'ClientCommands.cs') (Join-Path $PSScriptRoot 'ClientStatusReader.cs') `
    (Join-Path $PSScriptRoot 'GuardRuntime.cs') (Join-Path $PSScriptRoot 'SystemHosts.cs') (Join-Path $PSScriptRoot 'OwnedRasConnection.cs') (Join-Path $PSScriptRoot 'OwnedTunnelRoutes.cs') (Join-Path $PSScriptRoot 'RasTunnel.cs') (Join-Path $PSScriptRoot 'RouteObservation.cs') (Join-Path $PSScriptRoot 'ManagedVpnProfile.cs') (Join-Path $PSScriptRoot 'PolicyTransport.cs') (Join-Path $PSScriptRoot 'GuardStore.cs') (Join-Path $PSScriptRoot 'WfpGuard.cs') `
    (Join-Path $PSScriptRoot 'EnrollmentIntegrationTests.cs')
if ($LASTEXITCODE -ne 0) { throw 'Enrollment integration executable failed to compile' }
$enrollmentStoreExecutable = Join-Path $output 'EnrollmentStoreTests.exe'
& $compiler /nologo "/resource:$(Join-Path $PSScriptRoot 'ManagedVpnProfile.ps1'),ManagedVpnProfile.ps1" /platform:x64 "/out:$enrollmentStoreExecutable" /r:System.Web.Extensions.dll /r:System.Security.dll `
    (Join-Path $PSScriptRoot 'ManagedHosts.cs') (Join-Path $PSScriptRoot 'ClientPolicy.cs') `
    (Join-Path $PSScriptRoot 'GuardStore.cs') (Join-Path $PSScriptRoot 'WfpGuard.cs') `
    (Join-Path $PSScriptRoot 'GuardRuntime.cs') (Join-Path $PSScriptRoot 'SystemHosts.cs') (Join-Path $PSScriptRoot 'OwnedRasConnection.cs') (Join-Path $PSScriptRoot 'OwnedTunnelRoutes.cs') (Join-Path $PSScriptRoot 'RasTunnel.cs') (Join-Path $PSScriptRoot 'RouteObservation.cs') (Join-Path $PSScriptRoot 'ManagedVpnProfile.cs') (Join-Path $PSScriptRoot 'PolicyTransport.cs') `
    (Join-Path $PSScriptRoot 'EnrollmentRegistration.cs') (Join-Path $PSScriptRoot 'EnrollmentTransport.cs') (Join-Path $PSScriptRoot 'RestrictedAccessTests.cs') `
    (Join-Path $PSScriptRoot 'EnrollmentStoreTests.cs')
if ($LASTEXITCODE -ne 0) { throw 'Enrollment storage tests failed to compile' }
if ($EnrollmentStorage -or $Wfp) {
    & $enrollmentStoreExecutable (Join-Path $PSScriptRoot '..\fixtures\policies.json')
    if ($LASTEXITCODE -ne 0) { throw 'Enrollment storage tests failed' }
}
$appExecutable = Join-Path $output 'IKEv2ManagerClient.exe'
& $compiler /nologo /platform:x64 /target:winexe "/out:$appExecutable" /r:System.Web.Extensions.dll `
    /r:System.Windows.Forms.dll /r:System.Drawing.dll `
    (Join-Path $PSScriptRoot 'ClientStatusReader.cs') (Join-Path $PSScriptRoot 'ClientApp.cs') `
    (Join-Path $PSScriptRoot 'ClientCommands.cs') (Join-Path $PSScriptRoot 'EnrollmentTransport.cs') `
    (Join-Path $PSScriptRoot 'ClientPolicy.cs') (Join-Path $PSScriptRoot 'ManagedHosts.cs') (Join-Path $PSScriptRoot 'ProblemReports.cs')
if ($LASTEXITCODE -ne 0) { throw 'Client application failed to compile' }
$browserExecutable = Join-Path $output 'BrowserNamesTests.exe'
& $compiler /nologo /platform:x64 /main:BrowserNamesTests "/out:$browserExecutable" /r:System.Web.Extensions.dll `
    /r:System.Windows.Forms.dll /r:System.Drawing.dll `
    (Join-Path $PSScriptRoot 'ClientStatusReader.cs') (Join-Path $PSScriptRoot 'ClientApp.cs') `
    (Join-Path $PSScriptRoot 'ClientCommands.cs') (Join-Path $PSScriptRoot 'EnrollmentTransport.cs') `
    (Join-Path $PSScriptRoot 'ClientPolicy.cs') (Join-Path $PSScriptRoot 'ManagedHosts.cs') (Join-Path $PSScriptRoot 'ProblemReports.cs') (Join-Path $PSScriptRoot 'BrowserNamesTests.cs')
if ($LASTEXITCODE -ne 0) { throw 'Browser names test failed to compile' }
& $browserExecutable
if ($LASTEXITCODE -ne 0) { throw 'Browser names test failed' }
# Drives an installed product; compiled here, run only by the integration fixture.
& $compiler /nologo /platform:x64 "/out:$(Join-Path $output 'ProductIntegrationTests.exe')" /r:System.Web.Extensions.dll /r:System.ServiceProcess.dll `
    (Join-Path $PSScriptRoot 'ClientStatusReader.cs') (Join-Path $PSScriptRoot 'ClientCommands.cs') (Join-Path $PSScriptRoot 'EnrollmentTransport.cs') `
    (Join-Path $PSScriptRoot 'ClientPolicy.cs') (Join-Path $PSScriptRoot 'ManagedHosts.cs') (Join-Path $PSScriptRoot 'ProblemReports.cs') (Join-Path $PSScriptRoot 'ProductIntegrationTests.cs')
if ($LASTEXITCODE -ne 0) { throw 'Installed product check failed to compile' }
if ($Wfp) {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'WFP integration tests require an elevated process'
    }
    & $guardExecutable (Join-Path $PSScriptRoot '..\fixtures')
    if ($LASTEXITCODE -ne 0) { throw 'WFP behavior tests failed' }
}

$profileExecutable = Join-Path $output 'ManagedVpnProfileTests.exe'
& $compiler /nologo /platform:x64 "/out:$profileExecutable" /r:System.Web.Extensions.dll `
    "/resource:$(Join-Path $PSScriptRoot 'ManagedVpnProfile.ps1'),ManagedVpnProfile.ps1" `
    (Join-Path $PSScriptRoot 'ManagedHosts.cs') (Join-Path $PSScriptRoot 'ClientPolicy.cs') `
    (Join-Path $PSScriptRoot 'ManagedVpnProfile.cs') (Join-Path $PSScriptRoot 'ManagedVpnProfileTests.cs')
if ($LASTEXITCODE -ne 0) { throw 'Managed profile test failed to compile' }
if ($Profiles) {
    & $profileExecutable (Join-Path $PSScriptRoot '..\fixtures\policies.json')
    if ($LASTEXITCODE -ne 0) { throw 'Managed profile integration failed' }
}
