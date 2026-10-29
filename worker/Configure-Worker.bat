@echo off
REM Double-click entry point for the Clicky Worker configurator.
REM Edit .secrets.local in this folder, then run this file (or the Desktop
REM shortcut "Configure Clicky Worker" that the script creates on first run).
setlocal
set "SCRIPT_DIR=%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%Configure-Worker.ps1" %*
set "EXITCODE=%ERRORLEVEL%"
echo.
if "%EXITCODE%"=="0" (
    echo Worker configurator finished successfully.
) else (
    echo Worker configurator exited with code %EXITCODE%.
)
echo.
pause
endlocal & exit /b %EXITCODE%
