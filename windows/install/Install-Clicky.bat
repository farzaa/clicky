@echo off
REM Double-click entry point for the Clicky Windows installer.
REM Delegates to Install-Clicky.ps1 with ExecutionPolicy Bypass so users
REM never need to open a PowerShell prompt or tweak their policy first.
setlocal
set "SCRIPT_DIR=%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%Install-Clicky.ps1" %*
set "EXITCODE=%ERRORLEVEL%"
echo.
if "%EXITCODE%"=="0" (
    echo Installer finished successfully.
) else (
    echo Installer exited with code %EXITCODE%.
)
echo.
pause
endlocal & exit /b %EXITCODE%
