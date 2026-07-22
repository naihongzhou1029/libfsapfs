@echo off
rem Friendly double-click launcher for ".\devops.ps1 gui" (APFS Mount Manager
rem window), so a normal user does not have to open an elevated PowerShell
rem session or remember any devops.ps1 options. devops.ps1 is passed -Hidden
rem so it hides its own console window itself, once elevation is confirmed,
rem via a Win32 ShowWindow call; only the GUI window stays visible, like a
rem normal windowed app. This is NOT done via Start-Process's own
rem -WindowStyle Hidden: combined with -Verb RunAs (the elevation branch
rem below), that creates the GUI's own window already hidden too (not just
rem the console) - devops.ps1 hiding its own console after the fact avoids
rem that entirely, regardless of how it was launched. A brief flash of this
rem .bat's own cmd.exe window when double-clicked from Explorer cannot be
rem avoided from within a batch script.
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
	powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command "Start-Process powershell.exe -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','%~dp0devops.ps1','gui','-Hidden'"
	exit /b
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0devops.ps1" gui -Hidden
