@echo off
rem  Cross Input launcher. Double-click to start the server.
rem  Reads the .ps1 explicitly as UTF-8 so Chinese text never garbles.
cd /d "%~dp0"
where pwsh >nul 2>nul
if %errorlevel%==0 (
  pwsh -NoProfile -ExecutionPolicy Bypass -Command "$p=Join-Path '%~dp0' 'cross-input.ps1'; & ([scriptblock]::Create((Get-Content -Raw -Encoding UTF8 $p))) %*"
) else (
  powershell -NoProfile -ExecutionPolicy Bypass -Command "$p=Join-Path '%~dp0' 'cross-input.ps1'; & ([scriptblock]::Create((Get-Content -Raw -Encoding UTF8 $p))) %*"
)
if errorlevel 1 pause
