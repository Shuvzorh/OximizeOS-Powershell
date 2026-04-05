@echo off
setlocal

set "SCRIPT=%~dp0OximizeOS.ps1"
if not exist "%SCRIPT%" (
    echo Missing script:
    echo %SCRIPT%
    pause
    exit /b 1
)

where pwsh.exe >nul 2>nul
if %errorlevel%==0 (
    pwsh.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -STA -File "%SCRIPT%"
) else (
    powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -STA -File "%SCRIPT%"
)

if errorlevel 1 (
    echo.
    echo Oximize OS exited with an error.
    pause
)

endlocal
