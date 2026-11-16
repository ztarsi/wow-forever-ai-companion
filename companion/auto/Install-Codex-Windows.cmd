@echo off
rem Select Codex explicitly, then use the shared setup and scheduler.
setlocal
set "AIC_AUTO_PROVIDER=codex"
call "%~dp0Install-Windows.cmd"
