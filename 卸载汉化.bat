@echo off
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0uninstall.ps1"
set "PATCH_EXIT_CODE=%ERRORLEVEL%"
echo.
pause
exit /b %PATCH_EXIT_CODE%
