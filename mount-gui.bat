@echo off
rem Friendly double-click launcher for ".\devops.ps1 gui" (APFS Mount Manager
rem window), so a normal user does not have to open an elevated PowerShell
rem session or remember any devops.ps1 options. Every PowerShell hop below
rem runs with -WindowStyle Hidden so only the GUI window itself is visible,
rem like a normal windowed app; this does not affect the GUI window (a
rem separate top-level window, unrelated to the console). A brief flash of
rem this .bat's own cmd.exe window when double-clicked from Explorer cannot
rem be avoided from within a batch script.
rem
rem devops.ps1 is resolved relative to this .bat file's own folder (%~dp0),
rem not the current working directory, so this wrapper can be launched from
rem anywhere (eg. double-clicked in Explorer) as long as it stays alongside
rem devops.ps1.

net session >nul 2>&1
if %errorlevel% neq 0 (
	rem Not elevated: relaunch PowerShell itself elevated via UAC, passing
	rem devops.ps1's path as a separate -ArgumentList element so it is not
	rem broken by spaces (eg. "Program Files") without any manual escaping.
	powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command "Start-Process powershell.exe -Verb RunAs -WindowStyle Hidden -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','%~dp0devops.ps1','gui'"
	exit /b
)

powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0devops.ps1" gui
