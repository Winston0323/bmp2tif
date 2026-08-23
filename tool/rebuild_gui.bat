@echo off
setlocal
cd /d "%~dp0\.."
python "%~dp0rebuild_gui.py"
if errorlevel 1 pause
