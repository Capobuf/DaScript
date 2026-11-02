@echo off
setlocal
title DaScript - Anteprima aggiornamenti Windows
set "previewPowerShell=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "previewPowerShell=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%previewPowerShell%" (
    echo Windows PowerShell non disponibile.
    pause
    exit /b 1
)
echo DaScript - Anteprima UI: nessun aggiornamento o riavvio reale.
"%previewPowerShell%" -NoProfile -STA -File "%~dp0WindowsUpdate.ps1" -Action Preview
set "previewExit=%errorlevel%"
if not "%previewExit%"=="0" (
    echo Impossibile aprire l'anteprima. Leggere l'errore qui sopra.
    pause
)
exit /b %previewExit%
