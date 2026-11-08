param([switch]$Wfp, [switch]$EnrollmentStorage, [switch]$Profiles, [ValidateSet('', 'win-x64', 'win-arm64')][string]$Runtime = '')

# The Windows client's tests, on current .NET and on this machine's own
# architecture, as the service ships: an ARM64 machine runs them as ARM64.
$ErrorActionPreference = 'Stop'
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$output = Join-Path $PSScriptRoot '..\..\build\client-windows'
New-Item -ItemType Directory -Force -Path $output | Out-Null
$dotnet = if ($env:WAYPOINT_DOTNET) { $env:WAYPOINT_DOTNET } else { (Get-Command dotnet -ErrorAction SilentlyContinue).Source }
if (-not $dotnet -or -not (Test-Path $dotnet)) { throw '.NET SDK not found; set WAYPOINT_DOTNET or put dotnet on PATH' }
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'; $env:DOTNET_NOLOGO = '1'
# -Runtime win-x64 on an ARM64 machine runs the x64 build under emulation.
$runtime = if ($Runtime) { $Runtime } elseif ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture -eq 'Arm64') { 'win-arm64' } else { 'win-x64' }
Write-Host "Testing the $runtime build"
$policies = Join-Path $PSScriptRoot '..\fixtures\policies.json'

# Current .NET reads and writes JSON through JsonCompat.cs; it has to give what
# the .NET Framework serializer gives, on the same inputs.
$fixtures = @($policies, (Join-Path $PSScriptRoot '..\fixtures\policy-histories.json'))
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

# The service as it ships, and every test in one program beside it: the
# service tests install that ClientService.exe.
& $dotnet publish (Join-Path $PSScriptRoot 'service\Waypoint.Service.csproj') -c Release -r $runtime -o $output --nologo -v quiet
if ($LASTEXITCODE -ne 0) { throw 'Client service failed to build' }
& $dotnet publish (Join-Path $PSScriptRoot 'tests\Waypoint.Tests.csproj') -c Release -r $runtime -o $output --nologo -v quiet
if ($LASTEXITCODE -ne 0) { throw 'Client tests failed to build' }
$tests = Join-Path $output 'Waypoint.Tests.exe'
function Test([string]$name, [string]$failure) {
    & $tests $name @args
    if ($LASTEXITCODE -ne 0) { throw $failure }
}

Test HostsTests 'Client behavior tests failed' (Join-Path $PSScriptRoot '..\fixtures\hosts.json')
Test RasTunnelTests 'RAS observation tests failed'
Test ClientStatusTests 'Client status tests failed'
Test ProblemReportsTests 'Problem report tests failed'
Test ClientPolicyTests 'Client policy tests failed' $policies
Test PolicyTransportTests 'Policy transport tests failed' $policies
Test EnrollmentTransportTests 'Enrollment transport tests failed' $policies
Test ClientCommandsTests 'Control protocol tests failed'
Test ClientPresentationTests 'Window presentation tests failed'
Test WindowModelTests 'Window model tests failed' (Join-Path $PSScriptRoot '..\fixtures\window')
Test StatusCodesTests 'Status code tests failed' (Join-Path $PSScriptRoot '..\fixtures\status-codes.json')
Test BrowserNamesTests 'Browser names test failed'
Test OwnAddressesTests 'Own address tests failed' (Join-Path $PSScriptRoot '..\fixtures\own-addresses.json')
if ($EnrollmentStorage -or $Wfp) { Test EnrollmentStoreTests 'Enrollment storage tests failed' $policies }

# The WinUI window, built as it ships.
& $dotnet build (Join-Path $PSScriptRoot 'app\Waypoint.App.csproj') -c Release -r $runtime -p:Platform=$(if ($runtime -eq 'win-arm64') { 'ARM64' } else { 'x64' }) --nologo -v quiet
if ($LASTEXITCODE -ne 0) { throw 'WinUI window failed to build' }


if ($Wfp) {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'WFP integration tests require an elevated process'
    }
    Test WfpGuardTests 'WFP behavior tests failed' (Join-Path $PSScriptRoot '..\fixtures')
    Test MaintenanceTests 'Browser settings tests failed'
    # The failure queue lives under HKLM: written as an administrator.
    Test FailureReportsTests 'Failure report tests failed' (Join-Path $PSScriptRoot '..\fixtures\status-codes.json')
    Test UpdaterTests 'Update tests failed' (Join-Path $PSScriptRoot '..\fixtures\update')
}
if ($Profiles) { Test ManagedVpnProfileTests 'Managed profile integration failed' $policies }
# PolicyTransportIntegrationTests, EnrollmentIntegrationTests and
# ProductIntegrationTests are in the same program, run by the integration
# fixture: Waypoint.Tests.exe <name> [arguments].
