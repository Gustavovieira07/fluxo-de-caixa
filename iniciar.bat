@echo off
title ICC - Fluxo de Caixa
echo.
echo  Iniciando servidor ICC - Fluxo de Caixa...
echo.

where node >nul 2>&1
if %errorlevel% neq 0 (
    echo  ERRO: Node.js nao encontrado.
    echo  Baixe em: https://nodejs.org
    pause
    exit /b 1
)

cd /d "%~dp0"
start "" http://localhost:3000
node server.js
pause
