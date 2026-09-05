@echo off
rem Запуск інтерфейсу з Windows · один клік по цьому файлу.
rem
rem Навіщо. Конвеєр складається з bash-скриптів, тому САМ набір живе у WSL2
rem (docs/WINDOWS_WSL2.md). Але клікати власник хоче у Windows, а браузер у
rem нього теж віндовий. Цей файл робить рівно міст: запускає `./bdo web`
rem усередині WSL і лишає вікно відкритим, щоб було видно посилання й журнал.
rem
rem Порт і посилання друкує сам `./bdo web`; loopback у WSL2 пробрасується,
rem тому `http://127.0.0.1:<порт>` відкривається у звичайному браузері Windows.
rem
rem Аргументи передаються далі: `bdo.bat --no-open`, `bdo.bat --status`,
rem `bdo.bat --stop` працюють так само, як у терміналі.
setlocal
rem Кодова сторінка UTF-8: без неї cmd показує українські рядки кракозябрами.
chcp 65001 >nul

where wsl.exe >nul 2>nul
if errorlevel 1 (
  echo Немає wsl.exe. Набір працює у WSL2: див. docs\WINDOWS_WSL2.md
  pause
  exit /b 1
)

rem Тека набору береться від розташування цього файла й перекладається у
rem WSL-шлях: копіювати шлях руками власник не мусить.
for /f "usebackq delims=" %%p in (`wsl.exe wslpath -a "%~dp0"`) do set "BDO_DIR=%%p"
if "%BDO_DIR%"=="" (
  echo Не вдалося перекласти шлях "%~dp0" у WSL-шлях.
  pause
  exit /b 1
)

echo Запускаю інтерфейс у WSL: %BDO_DIR%
echo Посилання зʼявиться нижче · відкривай його у своєму браузері.
echo.

wsl.exe --cd "%BDO_DIR%" -- ./bdo web %*
set "RC=%ERRORLEVEL%"

if not "%RC%"=="0" (
  echo.
  echo Інтерфейс завершився з кодом %RC%. Діагностика: wsl.exe --cd "%BDO_DIR%" -- ./bdo platform
)
pause
exit /b %RC%
