param([Parameter(Mandatory)] [string]$Files, [string]$Base)
# The installation as a person meets it, on a disposable Windows: the setup of
# an earlier release installed, then this release's setup run over it, then
# removal from the list of installed programs. The earlier registration is
# stood in for by a file in the state directory the update must keep.
# $Files holds WaypointSetup.exe and the two installers of this build, and
# earlier\WaypointSetup.exe of the release being updated from.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
# Given an address, the files are fetched from it first, as its index lists them.
if ($Base) {
    New-Item -ItemType Directory -Force (Join-Path $Files 'earlier') | Out-Null
    $index = Join-Path $Files 'index.txt'
    Invoke-WebRequest -UseBasicParsing "$Base/index.txt" -OutFile $index
    foreach ($file in Get-Content $index | Where-Object { $_ -match '\S' -and $_ -ne 'index.txt' }) {
        Invoke-WebRequest -UseBasicParsing "$Base/$($file.Trim())" -OutFile (Join-Path $Files $file.Trim())
    }
}
$name = 'IKEv2ManagerClient'
$state = Join-Path $env:ProgramData $name
$folder = Join-Path $env:ProgramFiles 'Waypoint'
$earlierKey = "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\$name"

function Check([bool]$ok, [string]$what) {
    if (-not $ok) { throw "FAIL $what" }
    Write-Host "PASS $what"
}
function Until([scriptblock]$condition, [int]$seconds) {
    $deadline = (Get-Date).AddSeconds($seconds)
    while ((Get-Date) -lt $deadline) { if (& $condition) { return $true }; Start-Sleep -Milliseconds 500 }
    return $false
}
function Image() { (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\$name" -ErrorAction SilentlyContinue).ImagePath }
function Installed() { @(Get-ItemProperty 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -eq 'Waypoint' -and $_.WindowsInstaller -eq 1 }) }
# What Windows lists under the name, both registry views, for a failure to show.
function Listed() {
    foreach ($view in 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*') {
        Get-ItemProperty $view -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like '*Waypoint*' } |
            ForEach-Object { Write-Host ('  listed: {0} {1} installer={2}' -f $_.PSChildName, $_.DisplayName, $_.WindowsInstaller) }
    }
}
function Machine([string]$path) {
    $bytes = [IO.File]::ReadAllBytes($path); $header = [BitConverter]::ToInt32($bytes, 0x3c)
    [BitConverter]::ToUInt16($bytes, $header + 4)
}

# An earlier release, as the people using it have it.
$earlier = Start-Process (Join-Path $Files 'earlier\WaypointSetup.exe') '/quiet' -Wait -PassThru
Check ($earlier.ExitCode -eq 0 -and (Test-Path $earlierKey) -and (Image) -like "*$folder\ClientService.exe*") 'the earlier release installs'
Check (Until { Test-Path (Join-Path $state 'status.json') } 60) 'the earlier service keeps its state'
Set-Content (Join-Path $state 'kept-by-update.txt') 'registration'

# This release over it.
$setup = Start-Process (Join-Path $Files 'WaypointSetup.exe') '/quiet' -Wait -PassThru
Check ($setup.ExitCode -eq 0) 'setup finishes'
Check (-not (Test-Path $earlierKey)) 'the earlier entry in installed programs is gone'
if (@(Installed).Count -ne 1) {
    Listed
    $log = Join-Path $env:TEMP 'Waypoint-setup.log'
    if (Test-Path $log) { Get-Content $log | Select-String -Pattern 'Return value 3|Error \d|Product:|LaunchCondition|exit code|completed' | Select-Object -Last 20 | ForEach-Object { '  ' + $_ } }
    else { Write-Host "  no $log" }
}
Check (@(Installed).Count -eq 1) 'one installation is listed'
foreach ($old in 'Setup.exe', 'IKEv2ManagerClient.exe') { Check (-not (Test-Path (Join-Path $folder $old))) "the earlier $old is gone" }
Check (Test-Path (Join-Path $folder 'Waypoint.exe')) 'the window is installed'
Check ((Image) -like "*$folder\ClientService.exe*") 'the service runs the installed binary'
$native = if ([Runtime.InteropServices.RuntimeInformation]::OSArchitecture -eq 'Arm64') { 0xAA64 } else { 0x8664 }
Check ((Machine (Join-Path $folder 'ClientService.exe')) -eq $native) 'the service is built for this processor'
Check (Until { (Get-Service $name).Status -eq 'Running' } 60) 'the service runs'
Check ((Get-Content (Join-Path $state 'kept-by-update.txt')) -eq 'registration') 'the registration is kept'
Check (Until { try { ((Get-Content (Join-Path $state 'status.json') -Raw) | ConvertFrom-Json).Version -eq 7 } catch { $false } } 60) 'the new service publishes its status'
Check ($null -ne (Get-ItemProperty 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run' -Name Waypoint -ErrorAction SilentlyContinue)) 'the icon comes with sign-in'
$config = (& sc.exe qc $name) -join "`n"
Check ($config -match 'BFE' -and $config -match 'RasMan') 'the service starts after BFE and RasMan'
Check (((& sc.exe qfailureflag $name) -join "`n") -match 'NONCRASH_FAILURES\s*:\s*TRUE') 'recovery follows a failed start, not only a crash'

# The same release again: an update in place.
$again = Start-Process (Join-Path $Files 'WaypointSetup.exe') '/quiet' -Wait -PassThru
Check ($again.ExitCode -eq 0 -and @(Installed).Count -eq 1 -and (Test-Path (Join-Path $state 'kept-by-update.txt'))) 'running setup again keeps the installation'

# Removal from the list of installed programs.
$product = @(Installed)[0].PSChildName
$removal = Start-Process (Join-Path $env:WINDIR 'System32\msiexec.exe') "/x $product /qn" -Wait -PassThru
Check ($removal.ExitCode -eq 0) 'removal finishes'
Check ($null -eq (Get-Service $name -ErrorAction SilentlyContinue)) 'the service is gone'
Check (-not (Test-Path $state)) 'the state is removed'
Check (-not (Test-Path (Join-Path $folder 'Waypoint.exe'))) 'the program is removed'
Check ($null -eq (Get-ItemProperty 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run' -Name Waypoint -ErrorAction SilentlyContinue)) 'nothing starts with sign-in'
Write-Host 'Installation checks passed'
