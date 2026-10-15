@echo off
cd /d "%~dp0"

python vast_output_sync.py

if errorlevel 1 (
    echo.
    echo Vast Output Sync exited with an error.
    pause
)
