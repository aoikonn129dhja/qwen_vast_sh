@echo off
setlocal
where py >nul 2>nul
if errorlevel 1 (
  echo Python launcher ^(py^) is required. Install Python 3 and enable the Python launcher.
  exit /b 1
)
py -3 "%~dp0salad_output_sync.py" %*
exit /b %errorlevel%
