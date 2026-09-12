@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0prepare-repository-payload.ps1"
if errorlevel 1 (
    echo.
    echo Preparation failed. Do not run the installer.
    pause
    exit /b 1
)
echo.
echo Repository payload is ready. You can now run the installer.
pause
