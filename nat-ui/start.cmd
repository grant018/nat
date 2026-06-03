@echo off
setlocal
cd /d "%~dp0"

where node >nul 2>nul
if errorlevel 1 (
  echo Node.js is required. Install from https://nodejs.org/ ^(LTS^) then re-run.
  pause
  exit /b 1
)

if not exist "node_modules\express" (
  echo Installing dependencies...
  call npm install --omit=dev --no-audit --no-fund
  if errorlevel 1 (
    echo npm install failed.
    pause
    exit /b 1
  )
)

set NAT_OPEN_BROWSER=1
node server\index.js
