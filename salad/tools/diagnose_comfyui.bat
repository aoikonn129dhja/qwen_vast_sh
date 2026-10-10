@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0diagnose_comfyui.ps1" %*
exit /b %errorlevel%
