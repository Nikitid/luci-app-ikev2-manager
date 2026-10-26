param([Parameter(Mandatory)] [string]$Files, [string]$Base)
# Waypoint as a person meets it, against a real router, on a disposable Windows:
# this build installed, registered with the link in invitation.txt, connected,
# and its services, a choice and the person's own addresses tried with real
# traffic. The router's side is done meanwhile by its administrator: the device
# approved once it registers, then given an offer with one required and one
# optional service, and the right to two addresses of its own.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
if ($Base) {
    New-Item -ItemType Directory -Force $Files | Out-Null
    $index = Join-Path $Files 'index.txt'
    Invoke-WebRequest -UseBasicParsing "$Base/index.txt" -OutFile $index
    foreach ($file in Get-Content $index | Where-Object { $_ -match '\S' -and $_ -ne 'index.txt' }) {
        Invoke-WebRequest -UseBasicParsing "$Base/$($file.Trim())" -OutFile (Join-Path $Files $file.Trim())
    }
}
$name = 'IKEv2ManagerClient'
$state = Join-Path $env:ProgramData $name
$hosts = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'

function Check([bool]$ok, [string]$what) {
    if (-not $ok) { Write-Host "FAIL $what"; Write-Host ('  status: ' + (Get-Content (Join-Path $state 'status.json') -Raw -ErrorAction SilentlyContinue)); exit 1 }
    Write-Host "PASS $what"
}
function Until([scriptblock]$condition, [int]$seconds) {
    $deadline = (Get-Date).AddSeconds($seconds)
    while ((Get-Date) -lt $deadline) { if (& $condition) { return $true }; Start-Sleep 2 }
    return $false
}
function Status() { try { (Get-Content (Join-Path $state 'status.json') -Raw) | ConvertFrom-Json } catch { $null } }

# One request over the service's control pipe, framed as the window frames it:
# four bytes of length, the JSON, the answer, and an empty acknowledgement.
function Send([hashtable]$request) {
    $pipe = New-Object IO.Pipes.NamedPipeClientStream('.', "$name-control", [IO.Pipes.PipeDirection]::InOut)
    try {
        $pipe.Connect(3000)
        $frame = { param($text) $bytes = [Text.Encoding]::UTF8.GetBytes($text); $pipe.Write([BitConverter]::GetBytes([int]$bytes.Length), 0, 4); $pipe.Write($bytes, 0, $bytes.Length); $pipe.Flush() }
        & $frame ($request | ConvertTo-Json -Compress -Depth 4)
        $read = { param($count) $buffer = New-Object byte[] $count; $offset = 0; while ($offset -lt $count) { $got = $pipe.Read($buffer, $offset, $count - $offset); if ($got -le 0) { throw 'pipe closed' }; $offset += $got }; ,$buffer }
        $length = [BitConverter]::ToInt32((& $read 4), 0)
        $answer = [Text.Encoding]::UTF8.GetString((& $read $length)) | ConvertFrom-Json
        & $frame '{}'
        return $answer.state
    } finally { $pipe.Dispose() }
}
function Managed() { (Get-Content $hosts -Raw) }

$setup = Start-Process (Join-Path $Files 'WaypointSetup.exe') '/quiet' -Wait -PassThru
Check ($setup.ExitCode -eq 0) 'this build installs'
Check (Until { (Get-Service $name -ErrorAction SilentlyContinue).Status -eq 'Running' -and (Status) } 90) 'the service runs and says how it is'

$link = (Get-Content (Join-Path $Files 'invitation.txt') -Raw).Trim()
$cut = $link.IndexOf('#')
Check ((Send @{ version = 1; operation = 'begin'; endpoint = $link.Substring(0, $cut); invitation = $link.Substring($cut + 1) }) -eq 'accepted') 'registration with the link starts'
Check (Until { $s = Status; $s.State -eq 'registration_pending' -or $s.State -eq 'blocked' } 120) 'the device registers and waits for the administrator'
Check (Until { $s = Status; $s.State -eq 'blocked' -and $s.Services.Count -ge 1 } 600) 'the administrator lets it in'

Check ((Send @{ version = 1; operation = 'connect' }) -eq 'accepted') 'connecting is asked for'
Check (Until { (Status).State -eq 'protected' } 180) 'the tunnel comes up and the router confirms it'

# A name of the assigned service, as the hosts block written by Waypoint has it.
$assigned = [regex]::Matches((Managed), '(?m)^\s*(\d+\.\d+\.\d+\.\d+)\s+([a-z0-9.-]+\.[a-z]{2,})\s*$') | ForEach-Object { $_.Groups[2].Value } | Select-Object -First 1
Check ($null -ne $assigned) "a service name is reached through the tunnel's address: $assigned"
$reached = try { (Invoke-WebRequest -UseBasicParsing -TimeoutSec 20 "https://$assigned/" -MaximumRedirection 0 -ErrorAction Stop).StatusCode } catch { if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 } }
Check ($reached -gt 0) "the assigned service answers through the tunnel (HTTP $reached)"

# The offer: one optional service, turned on here.
Check (Until { $s = Status; @($s.Entries | Where-Object { -not $_.Required }).Count -ge 1 } 600) 'the offer reaches the window with an optional service'
$optional = @((Status).Entries | Where-Object { -not $_.Required })[0].Id
Check ((Send @{ version = 1; operation = 'choose'; on = @($optional); closed = @() }) -eq 'accepted') "turning $optional on is taken"
Check (Until { $s = Status; -not $s.ChoicePending -and @($s.Entries | Where-Object { $_.Id -eq $optional -and $_.On }).Count -eq 1 } 120) "$optional is on as the router applied it"

# The person's own address: refused for a private network, taken for a public site.
Check (Until { $null -ne (Status).Own } 600) 'the right to own addresses reaches the window'
$direct = (Invoke-WebRequest -UseBasicParsing -TimeoutSec 20 'https://ifconfig.me/ip').Content.Trim()
Check ((Send @{ version = 1; operation = 'own'; domains = @(); networks = @('192.168.1.0/24') }) -eq 'accepted') 'a private network is sent'
Check (Until { (Status).Own.Answer -eq 'refused' } 120) 'the router refuses a private network and the window says so'
Check ((Send @{ version = 1; operation = 'own'; domains = @('ifconfig.me'); networks = @() }) -eq 'accepted') 'a site of the person is sent'
Check (Until { $s = Status; -not $s.Own.Pending -and $s.Own.Answer -eq '' -and @($s.Own.Domains) -contains 'ifconfig.me' } 120) 'the router keeps it for this device'
Check (Until { (Managed) -match '(?m)^\s*\d+\.\d+\.\d+\.\d+\s+ifconfig\.me\s*$' } 120) 'it is reached through the tunnel'
$through = (Invoke-WebRequest -UseBasicParsing -TimeoutSec 20 'https://ifconfig.me/ip').Content.Trim()
Check ($through -ne $direct -and $through -match '^\d+\.\d+\.\d+\.\d+$') "the site sees the router's exit ($through), not this network ($direct)"

Check ((Send @{ version = 1; operation = 'disconnect' }) -eq 'accepted') 'disconnecting is asked for'
Write-Host 'Live check passed'
