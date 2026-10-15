@echo off
rem ---------------------------------------------------------------
rem  Internal helper for scripts\dsa-start.ps1 - do not run directly.
rem
rem  Starts the DSA service with its console output captured to logs\service.log.
rem  Launched through Win32_Process.Create (WMI), so it inherits no handles from
rem  the calling shell; working directory, environment and redirection are all
rem  set up here instead.
rem
rem  WHY pythonw INSTEAD OF python:
rem  A console program stays attached to a console, and closing that console
rem  delivers CTRL_CLOSE_EVENT, which terminates the process. That was observed
rem  in practice: logs\service.log ended with a bare "^C" and the service was
rem  gone, meaning it was killed by a console control event rather than crashing.
rem  pythonw.exe is a GUI-subsystem binary and never gets a console, so no console
rem  event can reach it. Output still works because cmd sets up the file redirection
rem  before the process starts.
rem
rem  NOTE: do not put parentheses inside echo/rem text that sits in a parenthesised
rem  block - cmd treats the closing paren as the end of the block. That exact mistake
rem  silently broke this file once, so the fallback below uses goto instead of blocks.
rem
rem  Keep this file ASCII-only: cmd.exe reads it using the OEM code page.
rem ---------------------------------------------------------------
setlocal

rem Repository root is the parent directory of this script's directory.
cd /d "%~dp0.." || exit /b 1

rem Force UTF-8 so Chinese log lines do not raise UnicodeEncodeError when stdout
rem is a redirected file; the default would be the OEM/ANSI code page.
set PYTHONIOENCODING=utf-8
set PYTHONUTF8=1

if not exist "logs" mkdir "logs"

set "RUNNER=pythonw"
where pythonw >nul 2>&1
if not errorlevel 1 goto :run

rem pythonw is unavailable: fall back to python, which does own a console window.
set "RUNNER=python"
where python >nul 2>&1
if not errorlevel 1 goto :run

> "logs\service.log" echo [run-service] ERROR: neither pythonw nor python was found on PATH.
exit /b 9009

:run
"%RUNNER%" main.py --serve-only > "logs\service.log" 2>&1
exit /b %ERRORLEVEL%
