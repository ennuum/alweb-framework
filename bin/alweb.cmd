@echo off
rem Lanceur de la commande alweb (Windows). Ajoutez ce dossier bin au PATH pour taper simplement alweb.
rem ALEX : variable ALEX (executable), sinon alex, sinon alexc dans le PATH.
setlocal
set "ALWEB_HOME=%~dp0..\alweb"
set "ALEX_BIN=%ALEX%"
if "%ALEX_BIN%"=="" (
  where alex >nul 2>nul && set "ALEX_BIN=alex"
)
if "%ALEX_BIN%"=="" (
  where alexc >nul 2>nul && set "ALEX_BIN=alexc"
)
if "%ALEX_BIN%"=="" (
  echo alweb: ALEX introuvable ^(installez-le ou definissez ALEX=chemin\vers\alex.exe^) 1>&2
  exit /b 127
)
"%ALEX_BIN%" run "%ALWEB_HOME%\commande.al" -- %*
exit /b %ERRORLEVEL%
