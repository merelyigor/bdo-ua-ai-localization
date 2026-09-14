$ErrorActionPreference = 'Stop'

function Fail([string] $Message) {
    Write-Error $Message
    exit 1
}

$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$batSource = [System.IO.File]::ReadAllText((Join-Path $repo 'bdo.bat'))
function Test-BatPortableRuntimeContract([string] $Source) {
    foreach ($required in @(
        'php-8.4.25-nts-Win32-vs17-x64.zip',
        '43a8f67ed2e5223fafb21293c85976361808855405278cef2cf3037c3ae2529c',
        'https://windows.php.net/downloads/releases/',
        'Get-FileHash',
        'Expand-Archive',
        'extension_dir=ext',
        'extension=curl',
        'extension=openssl',
        'extension=mbstring',
        'extension=fileinfo',
        'Microsoft Visual C++ Redistributable 2015-2022 x64'
    )) {
        if (-not $Source.Contains($required)) {
            return $false
        }
    }

    return $true
}
if (-not (Test-BatPortableRuntimeContract $batSource)) {
    Fail 'bdo.bat portable PHP contract is incomplete.'
}
$withoutHashCheck = $batSource.Replace('Get-FileHash', 'HASH_CHECK_REMOVED_BY_SABOTAGE')
if (Test-BatPortableRuntimeContract $withoutHashCheck) {
    Fail 'checksum sabotage was not detected.'
}
Write-Output 'bdo.bat portable contract: checksum-sabotage=detected; pinned-version=1; php.ini-extensions=4'
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

# `cmd.exe` не можна запускати через `ArgumentList`: .NET екранує лапки за
# правилами звичайної програми, і cmd бачить шлях разом із `\"`, а не сам шлях
# (`'\"D:\...\bdo.bat\"' is not recognized`). Тому рядок аргументів складається
# вручну за правилом cmd: `/d /c ""<шлях>" "<аргумент>""`.
function Get-CmdArguments([string[]] $Arguments) {
    $inner = '"' + $bat + '"'
    foreach ($argument in $Arguments) {
        $inner += ' "' + $argument + '"'
    }

    return '/d /c "' + $inner + '"'
}

function Invoke-Bat([string[]] $Arguments, [string] $Label) {
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $comspec
    $startInfo.WorkingDirectory = $batRepo
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.Environment['PATH'] = $phpDirectory
    $startInfo.Arguments = Get-CmdArguments $Arguments
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

function Invoke-BatProbe([string] $BatPath, [string] $WorkingDirectory, [string] $PathValue, [string] $StateDirectory, [string[]] $Arguments, [string] $Label) {
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $comspec
    $startInfo.WorkingDirectory = $WorkingDirectory
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.Environment['PATH'] = $PathValue
    $startInfo.Environment['BDO_STATE_DIR'] = $StateDirectory
    $inner = '"' + $BatPath + '"'
    foreach ($argument in $Arguments) {
        $inner += ' "' + $argument + '"'
    }
    $startInfo.Arguments = '/d /c "' + $inner + '"'
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        if (-not $process.Start()) {
            Fail "bdo.bat $Label process did not start."
        }
        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        $watch.Stop()
        [pscustomobject] @{
            Code = $process.ExitCode
            Stdout = $stdout
            Stderr = $stderr
            Milliseconds = $watch.ElapsedMilliseconds
        }
    } finally {
        $process.Dispose()
    }
}

# ПРАВИЛО: наявний runtime\php\php.exe має перемагати завантаження навіть коли
# PATH навмисно не містить PHP. Копія PHP з runner лише підробляє вже завантажений
# runtime; мережевий шлях і PowerShell у цьому сценарії не потрібні.
$runtimeRepo = Join-Path $work 'bdo portable runtime кирилиця'
New-Item -ItemType Directory -Force -Path $runtimeRepo | Out-Null
foreach ($directory in @('cli', 'lib', 'web')) {
    Copy-Item -Path (Join-Path $repo $directory) -Destination $runtimeRepo -Recurse -Force
}
Copy-Item -Path (Join-Path $repo 'bdo.bat') -Destination $runtimeRepo -Force
$runtimePhp = Join-Path $runtimeRepo 'runtime\php'
New-Item -ItemType Directory -Force -Path $runtimePhp | Out-Null
Copy-Item -Path (Join-Path $phpDirectory '*') -Destination $runtimePhp -Recurse -Force
$emptyPath = Join-Path $work 'path-without-php'
New-Item -ItemType Directory -Force -Path $emptyPath | Out-Null
$runtimeState = Join-Path $work 'portable-runtime-state'
New-Item -ItemType Directory -Force -Path $runtimeState | Out-Null
$runtimeFirst = Invoke-BatProbe (Join-Path $runtimeRepo 'bdo.bat') $runtimeRepo $emptyPath $runtimeState @('--stop') 'portable-runtime-first'
$runtimeSecond = Invoke-BatProbe (Join-Path $runtimeRepo 'bdo.bat') $runtimeRepo $emptyPath $runtimeState @('--stop') 'portable-runtime-second'
if ($runtimeFirst.Code -ne 0 -or $runtimeSecond.Code -ne 0) {
    Fail "portable runtime probe failed: first=$($runtimeFirst.Code), second=$($runtimeSecond.Code)."
}
if ($runtimeFirst.Stdout -match [regex]::Escape('Буде завантажено портативний PHP') -or $runtimeSecond.Stdout -match [regex]::Escape('Буде завантажено портативний PHP')) {
    Fail 'portable runtime probe attempted a download.'
}
if ($runtimeSecond.Milliseconds -ge 5000) {
    Fail "portable runtime second launch was not fast: $($runtimeSecond.Milliseconds) ms."
}
if (Get-ChildItem -Path (Join-Path $runtimeRepo 'runtime') -Filter '*.zip*' -File -ErrorAction SilentlyContinue) {
    Fail 'portable runtime probe left a download archive.'
}
Write-Output "bdo.bat portable runtime: runtime-selected=1; second-silent=1; second-ms=$($runtimeSecond.Milliseconds); download=0"

$batStartInfo = [System.Diagnostics.ProcessStartInfo]::new()
$batStartInfo.FileName = $comspec
$batStartInfo.WorkingDirectory = $batRepo
$batStartInfo.UseShellExecute = $false
$batStartInfo.RedirectStandardOutput = $true
$batStartInfo.RedirectStandardError = $true
$batStartInfo.Environment['PATH'] = $phpDirectory
$batStartInfo.Arguments = Get-CmdArguments @('--no-open')
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
    # Порожнє повідомлення про падіння вже коштувало кола CI на Linux: воно
    # називає симптом і мовчить про причину. Тому перед відмовою друкуємо все,
    # що процес устиг сказати, і журнал сервера · саме там лежить рядок, який
    # пояснює, чому PHP не піднявся.
    Write-Output "--- bdo.bat діагностика ---"
    Write-Output "процес завершився: $($batProcess.HasExited)"
    if ($batProcess.HasExited) {
        Write-Output "код виходу: $($batProcess.ExitCode)"
        Write-Output "stdout:"
        Write-Output $batProcess.StandardOutput.ReadToEnd()
        Write-Output "stderr:"
        Write-Output $batProcess.StandardError.ReadToEnd()
    } else {
        Write-Output 'процес ще живий · вивід не читаємо, щоб не блокувати канал'
    }
    $batLog = Join-Path $batState 'web.log'
    Write-Output "--- state/web.log ---"
    if (Test-Path $batLog) {
        Write-Output (Get-Content -Raw -Path $batLog)
    } else {
        Write-Output 'журналу немає'
    }
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

# `env` БІЛЬШЕ НЕ Є негативним контролем · і це саме те, заради чого робився
# підетап 9.3. Раніше вибір цілі жив у `cli/system/select-env.sh`, тому на
# Windows без bash команда падала, і смок цим користувався. Тепер ціль
# розвʼязує PHP (`ApiEnvironment`), тому `env` мусить ПРАЦЮВАТИ.
$envResult = Invoke-Cli @($entry, 'env') 'env-positive'
if ($envResult.Code -ne 0) {
    Fail "env must work natively without bash; code $($envResult.Code): $($envResult.Stderr)"
}
if ($envResult.Stderr -notmatch [regex]::Escape('Ціль: DEV')) {
    Fail 'env did not announce the synthetic DEV target.'
}

# Негативний контроль лишається, але тепер на команді, яка bash СПРАВДІ
# потребує: `gate` виконує `scripts/agent-check.sh`. Якщо вона раптом почне
# проходити без bash · значить PATH більше не очищений, і решта доказів цього
# смоку нічого не варта.
$gateResult = Invoke-Cli @($entry, 'gate', 'docs') 'gate-negative'
if ($gateResult.Code -eq 0) {
    Fail 'gate unexpectedly succeeded while bash was absent · PATH is not sanitized.'
}

Write-Output "Windows native smoke: PHP_OS_FAMILY=Windows; help=$($help.Code); run-spec-status=$($status.Code); run-loop-no-batch=$($runLoop.Code); env-works=$($envResult.Code); gate-negative=$($gateResult.Code); bash=absent"
