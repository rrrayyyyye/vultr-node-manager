@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0_install-shortcut.ps1"
echo.
pause
