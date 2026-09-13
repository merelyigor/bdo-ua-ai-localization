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
