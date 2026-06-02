@echo off
title ICC - Fluxo de Caixa (atualiza a cada 5 min)
powershell -ExecutionPolicy Bypass -File "%~dp0gerar.ps1" -Loop -Intervalo 300
