@echo off
setlocal

:: ============================================
:: Auto Elevate to Administrator
:: ============================================
net session >nul 2>&1
if %errorLevel% neq 0 (
    echo Requesting Administrator access...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs -ArgumentList '\"%~1\"'"
    exit /b
)

echo Running as Administrator...
echo.

:: ============================================
:: Target mount directory (arg or prompt)
:: ============================================
set "MOUNTDIR=%~1"
if "%MOUNTDIR%"=="" (
    echo Usage:
    echo   %~nx0 "C:\Path\To\WIMMountFolder"
    echo.
    set /p MOUNTDIR=Enter WIM mount folder path: 
)
if "%MOUNTDIR%"=="" (
    echo No mount folder provided. Exiting.
    pause
    exit /b 1
)

echo Target mount folder: "%MOUNTDIR%"
echo.

:: ============================================
:: Cleanup stuck mounts
:: ============================================
echo Cleaning up WIM mounts...
dism /Cleanup-Wim
dism /Cleanup-Mountpoints

:: ============================================
:: Try to unmount (force discard)
:: ============================================
echo Attempting to unmount...
dism /Unmount-Wim /MountDir:"%MOUNTDIR%" /Discard

:: ============================================
:: Delete folder if it still exists
:: ============================================
if exist "%MOUNTDIR%" (
    echo Taking ownership...
    takeown /f "%MOUNTDIR%" /r /d y >nul 2>nul
    icacls "%MOUNTDIR%" /grant administrators:F /t >nul 2>nul

    echo Deleting folder...
    rd /s /q "%MOUNTDIR%"
) else (
    echo Mount folder not found on disk. Skipping delete.
)

echo.
echo DONE. Press any key to exit.
pause >nul
