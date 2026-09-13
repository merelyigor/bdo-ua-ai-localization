$ErrorActionPreference = 'Stop'

function Fail([string] $Message) {
    Write-Error $Message
    exit 1
}

$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$phpCommand = Get-Command php.exe -ErrorAction SilentlyContinue
if ($null -eq $phpCommand) {
    Fail 'php.exe is not available before PATH sanitization.'
}
$php = [System.IO.Path]::GetFullPath($phpCommand.Source)
$phpFamily = (& $php -r 'echo PHP_OS_FAMILY;')
if ($LASTEXITCODE -ne 0 -or $phpFamily.Trim() -ne 'Windows') {
    Fail "PHP_OS_FAMILY must be Windows; received '$($phpFamily.Trim())'."
}

$runnerTemp = $env:RUNNER_TEMP
if ([string]::IsNullOrWhiteSpace($runnerTemp)) {
    $runnerTemp = [System.IO.Path]::GetTempPath()
}
$work = Join-Path $runnerTemp 'bdo-windows-native-8.1'
New-Item -ItemType Directory -Force -Path $work | Out-Null

$phpDirectory = Split-Path -Parent $php
$comspec = [System.Environment]::GetEnvironmentVariable('ComSpec')
if ([string]::IsNullOrWhiteSpace($comspec)) {
    Fail 'ComSpec is not available for the bdo.bat smoke.'
}
$env:PATH = $phpDirectory
$bashCommand = Get-Command bash.exe -CommandType Application -ErrorAction SilentlyContinue
if ($null -ne $bashCommand) {
    Fail 'bash remains executable on the sanitized PATH.'
}

$envFile = Join-Path $work 'synthetic.env'
$utf8 = [System.Text.UTF8Encoding]::new($false)
[System.IO.File]::WriteAllText($envFile, @(
    'BDO_ENV=DEV'
    'BDO_API_TARGET=legacy'
    'BDO_API_BASE_DEV=http://127.0.0.1:1'
    'BDO_API_KEY_DEV=windows-native-smoke-key'
) -join "`n", $utf8)

foreach ($name in @(
    'BDO_API_BASE',
    'BDO_API_KEY',
    'BDO_API_ENV',
    'BDO_API_BASE_DEV',
    'BDO_API_KEY_DEV',
    'BDO_ENV',
    'BDO_API_TARGET'
)) {
    Remove-Item "Env:$name" -ErrorAction SilentlyContinue
}
$env:TRANSLATE_ENV_FILE = $envFile

$entry = Join-Path $repo 'cli/bdo.php'

function Invoke-Cli([string[]] $Arguments, [string] $Label) {
    $stdoutPath = Join-Path $work "$Label.stdout"
    $stderrPath = Join-Path $work "$Label.stderr"
    & $php @Arguments 1> $stdoutPath 2> $stderrPath
    $code = $LASTEXITCODE
    [pscustomobject] @{
        Code = $code
        Stdout = [System.IO.File]::ReadAllText($stdoutPath)
        Stderr = [System.IO.File]::ReadAllText($stderrPath)
    }
}

function Invoke-NativeProcess([string[]] $Arguments, [int] $TimeoutMilliseconds) {
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $php
    $startInfo.WorkingDirectory = $repo
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in $Arguments) {
        [void] $startInfo.ArgumentList.Add($argument)
    }
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) {
            Fail 'run-loop process did not start.'
        }
        if (-not $process.WaitForExit($TimeoutMilliseconds)) {
            try {
                $process.Kill($true)
            } catch {
            }
            try {
                $process.WaitForExit(2000)
            } catch {
            }
            Fail 'run-loop timed out on Windows native process capture'
        }
        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        [pscustomobject] @{
            Code = $process.ExitCode
            Stdout = $stdout
            Stderr = $stderr
        }
    } finally {
        $process.Dispose()
    }
}

# ПРАВИЛО: help і run-spec status мусять працювати native PHP на Windows, коли bash недоступний.
# САБОТАЖ: shell-dependent env у тому самому sanitized PATH є negative control; якщо bash лишився доступним або positive command почне від нього залежати, proof мусить впасти.
$help = Invoke-Cli @($entry, 'help') 'help'
if ($help.Code -ne 0) {
    Fail "help returned code $($help.Code)."
}
if ($help.Stderr -ne '') {
    Fail 'help stderr must be empty.'
}
if ($help.Stdout -notmatch [regex]::Escape('bdo · переклад рядків BDO')) {
    Fail 'help root header is missing.'
}
if ($help.Stdout -notmatch [regex]::Escape('Реєстр команд: cli/command-registry.json')) {
    Fail 'help registry line is missing.'
}

$status = Invoke-Cli @($entry, 'run-spec', 'status', 'patch', 'active') 'run-spec-status'
if ($status.Code -ne 0) {
    Fail "run-spec status returned code $($status.Code)."
}
if ($status.Stderr -notmatch [regex]::Escape('Ціль: DEV')) {
    Fail 'run-spec status did not announce synthetic DEV target.'
}
try {
    $json = $status.Stdout | ConvertFrom-Json
} catch {
    Fail 'run-spec status stdout is not JSON.'
}
if ($json.ok -ne $true -or $json.mode -ne 'patch' -or $json.patch -ne 'active' -or $null -ne $json.domain) {
    Fail 'run-spec status JSON contract mismatch.'
}

$runLoopState = Join-Path $work 'run-loop-no-batch-state'
New-Item -ItemType Directory -Force -Path $runLoopState | Out-Null
$env:BDO_STATE_DIR = $runLoopState
$env:BDO_ORCHESTRATOR = 'php'
$runLoop = Invoke-NativeProcess @($entry, 'run-loop', '--once') 10000
if ($runLoop.Code -ne 1) {
    Fail "run-loop --once returned code $($runLoop.Code), expected 1."
}
if ($runLoop.Stderr -notmatch [regex]::Escape('no_current_batch')) {
    Fail 'run-loop --once did not report no_current_batch.'
}

# ПРАВИЛО: перевіряємо саме кліковий шлях `bdo.bat`, а не повторюємо його
# логіку в PowerShell. Копія має пробіл і кирилицю в шляху.
# САБОТАЖ: якщо `.bat` почне вимагати bash, native PHP не створить web state і
# впаде саме рядок `bdo.bat did not start native PHP server.`
$batRepo = Join-Path $work 'bdo native smoke кирилиця'
New-Item -ItemType Directory -Force -Path $batRepo | Out-Null
foreach ($directory in @('cli', 'lib', 'web')) {
    Copy-Item -Path (Join-Path $repo $directory) -Destination $batRepo -Recurse -Force
}
Copy-Item -Path (Join-Path $repo 'bdo.bat') -Destination $batRepo -Force
$bat = Join-Path $batRepo 'bdo.bat'
$batState = Join-Path $work 'bdo-bat-state'
New-Item -ItemType Directory -Force -Path $batState | Out-Null
$env:BDO_STATE_DIR = $batState

function Invoke-Bat([string[]] $Arguments, [string] $Label) {
    $command = 'call "' + $bat + '"'
    foreach ($argument in $Arguments) {
        $command += ' "' + $argument + '"'
    }
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $comspec
    $startInfo.WorkingDirectory = $batRepo
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.Environment['PATH'] = $phpDirectory
    [void] $startInfo.ArgumentList.Add('/d')
    [void] $startInfo.ArgumentList.Add('/c')
    [void] $startInfo.ArgumentList.Add($command)
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) {
            Fail "bdo.bat $Label process did not start."
        }
        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        [pscustomobject] @{
            Code = $process.ExitCode
            Stdout = $stdout
            Stderr = $stderr
        }
    } finally {
        $process.Dispose()
    }
}

$batStartInfo = [System.Diagnostics.ProcessStartInfo]::new()
$batStartInfo.FileName = $comspec
$batStartInfo.WorkingDirectory = $batRepo
$batStartInfo.UseShellExecute = $false
$batStartInfo.RedirectStandardOutput = $true
$batStartInfo.RedirectStandardError = $true
$batStartInfo.Environment['PATH'] = $phpDirectory
[void] $batStartInfo.ArgumentList.Add('/d')
[void] $batStartInfo.ArgumentList.Add('/c')
[void] $batStartInfo.ArgumentList.Add('call "' + $bat + '" --no-open')
$batProcess = [System.Diagnostics.Process]::new()
$batProcess.StartInfo = $batStartInfo
if (-not $batProcess.Start()) {
    Fail 'bdo.bat native process did not start.'
}

$webInfo = Join-Path $batState 'web.json'
$deadline = (Get-Date).AddSeconds(10)
while (-not (Test-Path $webInfo) -and (Get-Date) -lt $deadline) {
    if ($batProcess.HasExited) {
        break
    }
    Start-Sleep -Milliseconds 100
}
if (-not (Test-Path $webInfo)) {
    Fail 'bdo.bat did not start native PHP server.'
}
$batInfo = Get-Content -Raw -Path $webInfo | ConvertFrom-Json
$port = [int] $batInfo.port
$expectedUrl = "http://127.0.0.1:$port/?t=$($batInfo.token)"

$batStatus = Invoke-Bat @('--status') 'bdo-bat-status'
if ($batStatus.Code -ne 0 -or $batStatus.Stdout -notmatch [regex]::Escape($expectedUrl)) {
    Fail 'bdo.bat --status did not report the live native server.'
}

$batSecond = Invoke-Bat @('--no-open') 'bdo-bat-second'
if ($batSecond.Code -ne 0 -or $batSecond.Stdout -notmatch [regex]::Escape($expectedUrl)) {
    Fail 'second bdo.bat launch did not return the existing interface URL.'
}

$batStop = Invoke-Bat @('--stop') 'bdo-bat-stop'
if ($batStop.Code -ne 0 -or $batStop.Stdout -notmatch [regex]::Escape("порт $port вільний")) {
    Fail 'bdo.bat --stop did not report a successful native stop.'
}

$portFree = $false
for ($attempt = 0; $attempt -lt 20; $attempt++) {
    $client = [System.Net.Sockets.TcpClient]::new()
    try {
        $connect = $client.ConnectAsync('127.0.0.1', $port)
        if ($connect.Wait(250) -and $connect.Status -eq [System.Threading.Tasks.TaskStatus]::RanToCompletion) {
            $portFree = $false
            break
        }
        $portFree = $true
    } catch {
        $portFree = $true
    } finally {
        $client.Dispose()
    }
    if ($portFree) {
        break
    }
    Start-Sleep -Milliseconds 100
}
if (-not $portFree) {
    Fail 'bdo.bat --stop did not free the native server port.'
}

if (-not $batProcess.WaitForExit(10000)) {
    try {
        $batProcess.Kill($true)
    } catch {
    }
    Fail 'bdo.bat foreground process did not exit after --stop.'
}
$batStdout = $batProcess.StandardOutput.ReadToEnd()
$batStderr = $batProcess.StandardError.ReadToEnd()
$batProcess.Dispose()
if ($batStdout -notmatch 'http://127\.0\.0\.1:[0-9]+/\?t=[0-9a-fA-F]+') {
    Fail 'bdo.bat did not print interface URL.'
}

# ФАЛЬСИФІКАЦІЯ: цей рядок ловить сервер, який не піднявся; попередній
# `bash=absent` ловить доступність bash, а наступний ловить несправний --stop.
Write-Output "bdo.bat native web: status=0; second-same-url=1; stop=$($batStop.Code); port-free=1; printed-url=1"

$envResult = Invoke-Cli @($entry, 'env') 'env-negative'
if ($envResult.Code -eq 0) {
    Fail 'env unexpectedly succeeded while bash was absent.'
}

Write-Output "Windows native smoke: PHP_OS_FAMILY=Windows; help=$($help.Code); run-spec-status=$($status.Code); run-loop-no-batch=$($runLoop.Code); env-negative=$($envResult.Code); bash=absent"
