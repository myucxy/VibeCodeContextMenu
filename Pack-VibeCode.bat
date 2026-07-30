@echo off
setlocal EnableExtensions DisableDelayedExpansion
chcp 65001 >nul

set "PACK_SCRIPT=%~dp0Pack-VibeCode.ps1"
set "PAUSE_AFTER=1"
if /I "%~1"=="-NoPause" set "PAUSE_AFTER="

if not exist "%PACK_SCRIPT%" (
    echo 找不到打包脚本: %PACK_SCRIPT%
    set "RESULT=1"
    goto finish
)

set "PWSH=%ProgramFiles%\PowerShell\7\pwsh.exe"
if exist "%PWSH%" (
    "%PWSH%" -NoLogo -NoProfile -NonInteractive -Command "exit 0" >nul 2>&1
    if not errorlevel 1 goto run_pwsh
)

set "PWSH=%LOCALAPPDATA%\Programs\VibeCodeRuntime\PowerShell\pwsh.exe"
if exist "%PWSH%" (
    "%PWSH%" -NoLogo -NoProfile -NonInteractive -Command "exit 0" >nul 2>&1
    if not errorlevel 1 goto run_pwsh
)

set "WINDOWS_PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%WINDOWS_PS%" goto run_windows_ps

echo 无法启动打包脚本：未找到可用的 PowerShell。
set "RESULT=1"
goto finish

:run_pwsh
"%PWSH%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%PACK_SCRIPT%" -Force %*
set "RESULT=%ERRORLEVEL%"
goto finish

:run_windows_ps
"%WINDOWS_PS%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%PACK_SCRIPT%" -Force %*
set "RESULT=%ERRORLEVEL%"

:finish
if defined PAUSE_AFTER pause
exit /b %RESULT%
