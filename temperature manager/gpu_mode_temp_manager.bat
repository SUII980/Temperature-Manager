@echo off
title GPU Mode / Temp Manager (Universal NVIDIA / AMD / Intel)
:: Request administrator elevation
net session >nul 2>&1
if %errorlevel% neq 0 (
  echo Requesting administrative privileges...
  powershell -Command "Start-Process cmd -ArgumentList '/c \"%~dpnx0\"' -Verb RunAs"
  exit /b
)
:: Run the PowerShell UI script
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0gpu_mode_temp_manager.ps1"
:: Close CMD completely after PowerShell exits
exit
