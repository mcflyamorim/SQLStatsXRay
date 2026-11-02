@echo off
title SQLStatsXRay
echo Starting SQLStatsXRay (Windows PowerShell)...
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0Decode-StatsStream.ps1" -Gui
