@echo off
rem Double-click to open DebloatTool. It will ask for administrator rights.
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0DebloatTool.ps1" %*
