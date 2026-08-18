@echo off
rem DS Maid Pet launcher (ASCII only: cmd reads .bat as ANSI, so no CJK in this file)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0pet.ps1"
exit
