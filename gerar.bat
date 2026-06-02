@echo off
title ICC - Fluxo de Caixa (atualiza a cada 5 min)
echo.
echo  ICC - Fluxo de Caixa
echo  Buscando dados Omie e publicando no GitHub...
echo  Nao feche esta janela.
echo.
powershell -ExecutionPolicy Bypass -File "%~dp0gerar.ps1" -Loop -Intervalo 300
