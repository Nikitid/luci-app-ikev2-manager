param([string]$Output = (Join-Path $PSScriptRoot '..\..\build\client-windows'), [string]$Version = '0.0.0')
# Waypoint for Windows: for each processor the service and the window on
# current .NET, an installer of the two, and WaypointSetup.exe, which picks the
# installer for the machine it runs on and checks it against the digests
# written into it here.
$ErrorActionPreference = 'Stop'
if ($Version -notmatch '^\d{1,4}\.\d{1,4}\.\d{1,4}$') { throw 'Version must be X.Y.Z' }
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$dotnet = if ($env:WAYPOINT_DOTNET) { $env:WAYPOINT_DOTNET } else { (Get-Command dotnet -ErrorAction SilentlyContinue).Source }
if (-not $dotnet -or -not (Test-Path $dotnet)) { throw '.NET SDK not found; set WAYPOINT_DOTNET or put dotnet on PATH' }
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'; $env:DOTNET_NOLOGO = '1'
New-Item -ItemType Directory -Force -Path $Output | Out-Null
$work = Join-Path $Output 'parts'
if (Test-Path $work) { Remove-Item -Recurse -Force $work }

$digests = @{}
foreach ($target in @(@('win-x64', 'x64', 'x64'), @('win-arm64', 'ARM64', 'arm64'))) {
    $runtime = $target[0]; $platform = $target[1]; $name = $target[2]
    # The service is the one program that dials, and on Windows on ARM it has
    # to be an ARM64 process: under x64 emulation Windows refuses to load the
    # EAP method into it and every dial ends with error 691.
    $service = Join-Path $work "service-$name"
    & $dotnet publish (Join-Path $PSScriptRoot 'service\Waypoint.Service.csproj') -c Release -r $runtime -o $service "-p:AppVersion=$Version" --nologo -v quiet
    if ($LASTEXITCODE -ne 0) { throw "Client service build failed for $name" }
    $window = Join-Path $work "window-$name"
    & $dotnet publish (Join-Path $PSScriptRoot 'app\Waypoint.App.csproj') -c Release -r $runtime "-p:Platform=$platform" -o $window "-p:AppVersion=$Version" --nologo -v quiet
    if ($LASTEXITCODE -ne 0) { throw "Window build failed for $name" }
    # The service's own debugging symbols do not ship.
    Get-ChildItem $service -Filter *.pdb | Remove-Item
    & $dotnet build (Join-Path $PSScriptRoot 'installer\Waypoint.Installer.wixproj') -c Release "-p:Platform=$platform" `
        "-p:AppVersion=$Version" "-p:ServiceDir=$service" "-p:WindowDir=$window" -o $Output --nologo -v quiet
    if ($LASTEXITCODE -ne 0) { throw "Installer build failed for $name" }
    $msi = Join-Path $Output "Waypoint-$Version-$name.msi"
    if (-not (Test-Path $msi)) { throw "Installer missing: $msi" }
    $digests[$name] = (Get-FileHash -Algorithm SHA256 $msi).Hash.ToLowerInvariant()
}

$stamp = Join-Path $work 'Release.cs'
Set-Content -LiteralPath $stamp -Encoding ASCII -Value @(
    "[assembly: System.Reflection.AssemblyVersion(`"$Version.0`")]",
    "[assembly: System.Reflection.AssemblyFileVersion(`"$Version.0`")]",
    '[assembly: System.Reflection.AssemblyProduct("Waypoint")]',
    'internal static class Release {',
    "    internal const string X64 = `"$($digests['x64'])`";",
    "    internal const string Arm64 = `"$($digests['arm64'])`";",
    '}')
& $compiler /nologo /platform:anycpu /optimize+ /target:winexe "/out:$(Join-Path $Output 'WaypointSetup.exe')" `
    "/win32manifest:$(Join-Path $PSScriptRoot 'Setup.manifest')" "/win32icon:$(Join-Path $PSScriptRoot '..\assets\Waypoint.ico')" `
    /r:System.ServiceProcess.dll /r:System.Windows.Forms.dll /r:System.Drawing.dll $stamp (Join-Path $PSScriptRoot 'Setup.cs')
if ($LASTEXITCODE -ne 0) { throw 'Setup build failed' }
Remove-Item -Recurse -Force $work
Get-ChildItem $Output -Filter *.wixpdb | Remove-Item
Get-ChildItem $Output | Where-Object { $_.Extension -in '.msi', '.exe' } | ForEach-Object { '{0} {1} {2}' -f $_.Name, $_.Length, (Get-FileHash -Algorithm SHA256 $_.FullName).Hash.ToLowerInvariant() }
