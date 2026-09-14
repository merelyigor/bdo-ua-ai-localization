@echo off
rem Запуск інтерфейсу з Windows · один клік по цьому файлу.
rem
rem Основний шлях · нативний PHP у Windows. WSL2 лишається запасним шляхом
rem лише для машин, де php.exe не встановлено (docs\WINDOWS_WSL2.md).
rem Тека набору завжди береться від розташування цього файла, тому працюють
rem шляхи з пробілами й кирилицею.
rem
rem Кодова сторінка UTF-8: без неї cmd показує українські рядки кракозябрами.
setlocal
chcp 65001 >nul

set "WHERE_EXE=%SystemRoot%\System32\where.exe"
if not exist "%WHERE_EXE%" set "WHERE_EXE=where.exe"
set "PHP_EXE="
for /f "usebackq delims=" %%P in (`"%WHERE_EXE%" php.exe 2^>nul`) do if not defined PHP_EXE set "PHP_EXE=%%P"

if defined PHP_EXE goto native_php

set "RUNTIME_ROOT=%~dp0runtime"
set "RUNTIME_DIR=%RUNTIME_ROOT%\php"
set "RUNTIME_PHP=%RUNTIME_DIR%\php.exe"
if exist "%RUNTIME_PHP%" (
  set "PHP_EXE=%RUNTIME_PHP%"
  set "PORTABLE_PHP=1"
  set "PATH=%RUNTIME_DIR%;%PATH%"
  goto native_php
)

set "PHP_ARCHIVE=php-8.4.25-nts-Win32-vs17-x64.zip"
set "PHP_SHA256=43a8f67ed2e5223fafb21293c85976361808855405278cef2cf3037c3ae2529c"
set "PHP_URL=https://windows.php.net/downloads/releases/%PHP_ARCHIVE%"
echo Не знайдено php.exe у PATH або runtime\php\php.exe.
echo Буде завантажено портативний PHP:
echo   Файл: %PHP_ARCHIVE%
echo   Джерело: %PHP_URL%
echo   Розмір: приблизно 30 МБ
echo   Куди: "%RUNTIME_DIR%"
echo.
call :prepare_portable_php
set "PREPARE_RC=%ERRORLEVEL%"
if "%PREPARE_RC%"=="0" (
  set "PHP_EXE=%RUNTIME_PHP%"
  set "PORTABLE_PHP=1"
  set "PATH=%RUNTIME_DIR%;%PATH%"
  goto native_php
)
if "%PREPARE_RC%"=="2" (
  echo Відмова: контрольна сума завантаженого PHP не збігається.
  pause
  exit /b 1
)
echo Не вдалося підняти портативний PHP через PowerShell. Переходжу до запасного WSL2.

"%WHERE_EXE%" wsl.exe >nul 2>nul
if errorlevel 1 (
  echo Не знайдено нативний php.exe і wsl.exe.
  echo Встанови PHP 8.3+ для Windows або WSL2 як запасний runtime.
  pause
  exit /b 1
)

rem Запасний шлях · старий WSL2 bridge використовується тільки без php.exe.
set "BDO_DIR="
for /f "usebackq delims=" %%P in (`wsl.exe wslpath -a "%~dp0"`) do set "BDO_DIR=%%P"
if not defined BDO_DIR (
  echo Не вдалося перекласти шлях "%~dp0" у WSL-шлях для запасного WSL2.
  pause
  exit /b 1
)

echo Нативний php.exe не знайдено · використовую запасний шлях WSL2: %BDO_DIR%
echo Посилання зʼявиться нижче · відкривай його у своєму браузері.
echo.
wsl.exe --cd "%BDO_DIR%" -- ./bdo web %*
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" (
  echo.
  echo Інтерфейс завершився з кодом %RC%. Діагностика: wsl.exe --cd "%BDO_DIR%" -- ./bdo platform
)
exit /b %RC%

:native_php
if defined PORTABLE_PHP (
  "%PHP_EXE%" -v >nul 2>nul
  if errorlevel 1 (
    echo Не вдалося запустити портативний PHP після розпакування.
    echo Найімовірніша причина: відсутній Microsoft Visual C++ Redistributable 2015-2022 x64.
    echo Встановлювач Microsoft: https://aka.ms/vs/17/release/vc_redist.x64.exe
    pause
    exit /b 1
  )
)
set "PHP_VERSION="
for /f "usebackq delims=" %%V in (`"%PHP_EXE%" -r "echo PHP_VERSION;" 2^>nul`) do if not defined PHP_VERSION set "PHP_VERSION=%%V"
"%PHP_EXE%" -r "exit(PHP_VERSION_ID >= 80300 ? 0 : 1);" >nul 2>nul
if errorlevel 1 (
  echo Знайдено php.exe версії %PHP_VERSION%, але потрібен PHP 8.3+.
  echo WSL2 не використовується, бо нативний PHP уже знайдено.
  pause
  exit /b 1
)

pushd "%~dp0"
if errorlevel 1 (
  echo Не вдалося відкрити теку набору: "%~dp0"
  pause
  exit /b 1
)
echo Запускаю інтерфейс через нативний PHP %PHP_VERSION%.
echo Посилання зʼявиться нижче · відкривай його у своєму браузері.
echo.
"%PHP_EXE%" cli\bdo.php web %*
set "RC=%ERRORLEVEL%"
popd
if not "%RC%"=="0" (
  echo.
  echo Інтерфейс завершився з кодом %RC%. Перевір PHP 8.3+ і state\web.log.
)
exit /b %RC%

:prepare_portable_php
set "PS_EXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PS_EXE%" set "PS_EXE=powershell.exe"
set "BDO_PHP_ROOT=%RUNTIME_ROOT%"
set "BDO_PHP_ARCHIVE=%PHP_ARCHIVE%"
set "BDO_PHP_SHA256=%PHP_SHA256%"
set "BDO_PHP_URL=%PHP_URL%"
set "BDO_PHP_RUNTIME=%RUNTIME_DIR%"
"%PS_EXE%" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "$ErrorActionPreference = 'Stop'; $root = $env:BDO_PHP_ROOT; $archiveName = $env:BDO_PHP_ARCHIVE; $expected = $env:BDO_PHP_SHA256; $url = $env:BDO_PHP_URL; $runtime = $env:BDO_PHP_RUNTIME; $archive = Join-Path $root $archiveName; $download = $archive + '.download'; $extract = Join-Path $root '.php-extract'; try { New-Item -ItemType Directory -Force -Path $root | Out-Null; Remove-Item -LiteralPath $download -Force -ErrorAction SilentlyContinue; Remove-Item -LiteralPath $extract -Recurse -Force -ErrorAction SilentlyContinue; Invoke-WebRequest -Uri $url -OutFile $download -UseBasicParsing; $actual = (Get-FileHash -LiteralPath $download -Algorithm SHA256).Hash.ToLowerInvariant(); if ($actual -ne $expected.ToLowerInvariant()) { [Console]::Error.WriteLine('PHP archive SHA-256 mismatch: expected ' + $expected + ', actual ' + $actual); exit 2 }; Expand-Archive -LiteralPath $download -DestinationPath $extract -Force; $php = Get-ChildItem -LiteralPath $extract -Filter 'php.exe' -File -Recurse | Select-Object -First 1; if ($null -eq $php) { throw 'php.exe was not found in the PHP archive' }; New-Item -ItemType Directory -Force -Path $runtime | Out-Null; Get-ChildItem -LiteralPath $php.DirectoryName -Force | Move-Item -Destination $runtime -Force; [IO.File]::WriteAllText((Join-Path $runtime 'php.ini'), (@('extension_dir=ext', 'extension=curl', 'extension=openssl', 'extension=mbstring', 'extension=fileinfo') -join [Environment]::NewLine), [Text.UTF8Encoding]::new($false)); Remove-Item -LiteralPath $download -Force; Remove-Item -LiteralPath $extract -Recurse -Force; exit 0 } catch { Write-Error $_; exit 1 }"
set "PS_RC=%ERRORLEVEL%"
if not "%PS_RC%"=="0" exit /b %PS_RC%
exit /b 0
