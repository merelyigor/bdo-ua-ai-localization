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
$work = Join-Path $runnerTemp 'bdo-windows-native-6.6.1'
New-Item -ItemType Directory -Force -Path $work | Out-Null

$phpDirectory = Split-Path -Parent $php
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

$envResult = Invoke-Cli @($entry, 'env') 'env-negative'
if ($envResult.Code -eq 0) {
    Fail 'env unexpectedly succeeded while bash was absent.'
}

Write-Output "Windows native smoke: PHP_OS_FAMILY=Windows; help=$($help.Code); run-spec-status=$($status.Code); env-negative=$($envResult.Code); bash=absent"
