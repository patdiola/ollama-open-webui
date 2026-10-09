@echo off
rem Windows entry point. Runs setup.ps1 without changing your execution policy.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup.ps1" %*
exit /b %errorlevel%
