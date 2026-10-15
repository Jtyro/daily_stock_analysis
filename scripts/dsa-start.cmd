@echo off
rem ---------------------------------------------------------------
rem  DSA one-click launcher (double-clickable).
rem  Passes all arguments through to scripts\dsa-start.ps1
rem    dsa-start.cmd              -> start (idempotent)
rem    dsa-start.cmd stop         -> stop
rem    dsa-start.cmd restart      -> restart
rem    dsa-start.cmd status       -> show status
rem  Keep this file ASCII-only: cmd.exe reads it using the OEM code page.
rem ---------------------------------------------------------------
setlocal

rem Switch to UTF-8 so the PowerShell script's Chinese output renders correctly.
chcp 65001 >nul 2>&1

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0dsa-start.ps1" %*
set "RC=%ERRORLEVEL%"

if not "%RC%"=="0" (
    echo.
    echo [FAILED] exit code %RC% - see the messages above.
    echo Press any key to close...
    pause >nul
)

exit /b %RC%
