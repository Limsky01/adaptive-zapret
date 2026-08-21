@echo off
chcp 65001 > nul
cd /d "%~dp0"
net session >nul 2>&1
if not "%errorlevel%"=="0" (
  powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath 'powershell.exe' -Verb RunAs -WorkingDirectory '%~dp0' -ArgumentList @('-NoProfile','-STA','-ExecutionPolicy','Bypass','-File','%~dp0AdaptiveZapret.Launcher.ps1')"
  exit /b
)
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0AdaptiveZapret.Launcher.ps1"
if errorlevel 1 pause
