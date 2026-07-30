@echo off
setlocal EnableExtensions DisableDelayedExpansion

rem Detect the native architecture even when launched from a 32-bit process on 64-bit Windows.
if /I "%PROCESSOR_ARCHITECTURE%"=="x86" if not defined PROCESSOR_ARCHITEW6432 goto unsupported_32bit

set "ARCH="
if /I "%PROCESSOR_ARCHITECTURE%"=="AMD64" set "ARCH=x64"
if /I "%PROCESSOR_ARCHITECTURE%"=="ARM64" set "ARCH=arm64"
if /I "%PROCESSOR_ARCHITEW6432%"=="AMD64" set "ARCH=x64"
if /I "%PROCESSOR_ARCHITEW6432%"=="ARM64" set "ARCH=arm64"
if not defined ARCH goto unsupported_arch

set "SCRIPT=%~dp0VibeCode.ps1"
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

where tar.exe >nul 2>&1
if errorlevel 1 goto bootstrap_failed
where certutil.exe >nul 2>&1
if errorlevel 1 goto bootstrap_failed

set "HASH_LIST=%~dp0installers\powershell\portable-sha256.txt"
if not exist "%HASH_LIST%" goto bootstrap_failed

set "ARCHIVE="
set "ASSET_NAME="
set /a PACKAGE_COUNT=0
for %%F in ("%~dp0installers\powershell\PowerShell-*-win-%ARCH%.zip") do (
    if exist "%%~fF" (
        set /a PACKAGE_COUNT+=1
        set "ARCHIVE=%%~fF"
        set "ASSET_NAME=%%~nxF"
    )
)
if not "%PACKAGE_COUNT%"=="1" goto bootstrap_failed

set "EXPECTED_HASH="
set "HASH_ASSET="
for /f "tokens=1,2" %%H in ('type "%HASH_LIST%" ^| findstr /I /L /C:"%ASSET_NAME%"') do (
    set "EXPECTED_HASH=%%H"
    set "HASH_ASSET=%%I"
)
if not defined EXPECTED_HASH goto bootstrap_failed
set "HASH_ASSET=%HASH_ASSET:~1%"
if /I not "%HASH_ASSET%"=="%ASSET_NAME%" goto bootstrap_failed

set "ACTUAL_HASH="
for /f "tokens=* delims=" %%H in ('certutil.exe -hashfile "%ARCHIVE%" SHA256 ^| findstr /R /I "^[0-9A-F][0-9A-F]*$"') do (
    if not defined ACTUAL_HASH set "ACTUAL_HASH=%%H"
)
set "ACTUAL_HASH=%ACTUAL_HASH: =%"
if /I not "%ACTUAL_HASH%"=="%EXPECTED_HASH%" (
    echo PowerShell 7 offline package SHA-256 verification failed.
    goto bootstrap_failed
)

echo PowerShell was not found. Deploying the bundled %ARCH% PowerShell 7 package...
set "TARGET=%LOCALAPPDATA%\Programs\VibeCodeRuntime\PowerShell"
set "STAGING=%LOCALAPPDATA%\Programs\VibeCodeRuntime\staging-powershell-bat-%RANDOM%-%RANDOM%"
if exist "%STAGING%" rmdir /s /q "%STAGING%"
mkdir "%STAGING%" >nul 2>&1
if errorlevel 1 goto bootstrap_failed
tar.exe -xf "%ARCHIVE%" -C "%STAGING%"
if errorlevel 1 goto bootstrap_failed
if not exist "%STAGING%\pwsh.exe" goto bootstrap_failed

"%STAGING%\pwsh.exe" -NoLogo -NoProfile -NonInteractive -Command "if ($PSVersionTable.PSVersion.Major -ge 7) { exit 0 } else { exit 1 }" >nul 2>&1
if errorlevel 1 goto bootstrap_failed

if exist "%TARGET%" rmdir /s /q "%TARGET%"
if exist "%TARGET%" goto bootstrap_failed
move /y "%STAGING%" "%TARGET%" >nul
if errorlevel 1 goto bootstrap_failed
if not exist "%TARGET%\pwsh.exe" goto bootstrap_failed
set "PWSH=%TARGET%\pwsh.exe"
goto run_pwsh

:bootstrap_failed
if defined STAGING if exist "%STAGING%" rmdir /s /q "%STAGING%"
echo Unable to start: the PowerShell 7 offline package is missing, duplicated, invalid, or cannot be extracted.
echo Verify the matching ZIP and portable-sha256.txt under installers\powershell, and ensure tar/certutil are available.
pause
exit /b 1

:unsupported_32bit
echo 32-bit Windows is not supported. VibeCode requires 64-bit Windows ^(x64/ARM64^).
pause
exit /b 1

:unsupported_arch
echo Unsupported Windows architecture: %PROCESSOR_ARCHITECTURE%. VibeCode supports x64/ARM64 only.
pause
exit /b 1

:run_pwsh
"%PWSH%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
set "RESULT=%ERRORLEVEL%"
if not "%RESULT%"=="0" pause
exit /b %RESULT%

:run_windows_ps
"%WINDOWS_PS%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
set "RESULT=%ERRORLEVEL%"
if not "%RESULT%"=="0" pause
exit /b %RESULT%
