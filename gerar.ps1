# =============================================================
#  ICC — Gerador de Fluxo de Caixa
#  Uso: gerar.bat  (loop automático a cada 5 min + push GitHub)
#  Baseado na mesma arquitetura do dashboard de inadimplência
# =============================================================
param(
    [string]$Ano       = "2026",
    [switch]$Loop,
    [int]   $Intervalo = 300
)

$ErrorActionPreference = 'Stop'
$scriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$outputFile = Join-Path $scriptDir "index.html"
$tmpFile    = Join-Path $scriptDir "index.tmp.html"

$companies = @(
    [ordered]@{id="instituto"; name="ICC Instituto"; key="3946880386449"; secret="0c15f825cded97455749c7d6b7558f1e"; color="#1565c0"; dot="#2196F3"},
    [ordered]@{id="telecom";   name="ICC Telecom";   key="4472437527558"; secret="eb030b4871537b1d984ff4078a469f75"; color="#1b5e20"; dot="#43a047"},
    [ordered]@{id="medical";   name="ICC Medical";   key="7069173264153"; secret="9632f5b931f568b6b09accbf25f47496"; color="#4a148c"; dot="#8e24aa"}
)

# ── Omie POST ──
function Omie-Post($url, $call, $key, $secret, $params) {
    $body = [ordered]@{ call=$call; app_key=$key; app_secret=$secret; param=@($params) }
    $json = $body | ConvertTo-Json -Depth 10 -Compress
    return Invoke-RestMethod -Uri $url -Method POST `
        -ContentType "application/json" -Body $json -TimeoutSec 60
}

# ── Paginação com delay ──
function Get-Pages($url, $call, $key, $secret, $listKey) {
    $all = [System.Collections.Generic.List[object]]::new()
    $page = 1; $total = 1
    do {
        $r = Omie-Post $url $call $key $secret @{
            pagina=page; registros_por_pagina=500
            filtrar_por_data_de="01/01/$Ano"; filtrar_por_data_ate="31/12/$Ano"
        }
        if ($r.faultstring) { throw $r.faultstring }
        $chunk = $r.$listKey
        if ($chunk) { foreach ($i in $chunk) { $all.Add($i) } }
        $total = [int]($r.total_de_paginas)
        Write-Host "    pag $page/$total ($($all.Count) reg.)" -ForegroundColor DarkGray
        $page++
        if ($page -le $total) { Start-Sleep -Milliseconds 800 }
    } while ($page -le $total)
    return $all
}

# ── Normaliza item ──
function Norm($item) {
    $venc  = "$($item.data_vencimento)"
    $valor = [double]($item.valor_documento)
    $saldo = if ($item.PSObject.Properties['valor_saldo'] -and $item.valor_saldo) { [double]$item.valor_saldo } else { $valor }
    $st    = "$($item.status_titulo)"
    $nome  = if ($item.nome_fantasia)   { "$($item.nome_fantasia)" }
             elseif ($item.nome_cliente)    { "$($item.nome_cliente)" }
             elseif ($item.nome_fornecedor) { "$($item.nome_fornecedor)" }
             else { "Cod.$($item.codigo_cliente_fornecedor)" }
    $doc   = if ($item.numero_documento) { "$($item.numero_documento)" }
             elseif ($item.numero_parcela){ "$($item.numero_parcela)" }
             else { "$($item.codigo_lancamento_omie)" }
    return [ordered]@{ venc=$venc; saldo=$saldo; status=$st; nome=$nome; doc=$doc }
}

# ── Saldo banco ──
function Get-Saldo($key, $secret) {
    try {
        $r = Omie-Post "https://app.omie.com.br/api/v1/geral/contacorrente/" `
            "ListarContasCorrentes" $key $secret @{pagina=1; registros_por_pagina=50}
        $contas = @($r.ListarContasCorrentes | Where-Object { $_.inativo -ne 'S' })
        return [double](($contas | Measure-Object -Property saldo_inicial -Sum).Sum)
    } catch { return 0.0 }
}

# ── Formata moeda ──
function Fmt($v) { return $v.ToString("N2", [System.Globalization.CultureInfo]::GetCultureInfo("pt-BR")) }

# ── GERA RELATÓRIO ──
function Generate-Report {
    $geradoEm = (Get-Date).ToString("dd/MM/yyyy HH:mm:ss")
    Write-Host ""
    Write-Host "  Gerando relatorio — $geradoEm" -ForegroundColor Cyan

    $payload = [ordered]@{}
    $pendentes = @("A VENCER", "ATRASADO")

    foreach ($c in $companies) {
        Write-Host ""
        Write-Host "  $($c.name)" -ForegroundColor Yellow

        Write-Host "    Contas a Receber..." -ForegroundColor Gray
        $recRaw = Get-Pages "https://app.omie.com.br/api/v1/financas/contareceber/" `
            "ListarContasReceber" $c.key $c.secret "conta_receber_cadastro"

        Start-Sleep -Seconds 2

        Write-Host "    Contas a Pagar..." -ForegroundColor Gray
        $pagRaw = Get-Pages "https://app.omie.com.br/api/v1/financas/contapagar/" `
            "ListarContasPagar" $c.key $c.secret "conta_pagar_cadastro"

        Write-Host "    Saldo Banco..." -ForegroundColor Gray
        $saldo = Get-Saldo $c.key $c.secret

        $recNorm = @($recRaw | ForEach-Object { Norm $_ })
        $pagNorm = @($pagRaw | ForEach-Object { Norm $_ })

        # Filtra: vencimento no ano + status pendente
        $recFilt = @($recNorm | Where-Object {
            ($_.venc -split '/')[2] -eq $Ano -and $_.status -in $pendentes
        })
        $pagFilt = @($pagNorm | Where-Object {
            ($_.venc -split '/')[2] -eq $Ano -and $_.status -in $pendentes
        })

        $totRec = ($recFilt | ForEach-Object { $_.saldo } | Measure-Object -Sum).Sum
        $totPag = ($pagFilt | ForEach-Object { $_.saldo } | Measure-Object -Sum).Sum
        if (-not $totRec) { $totRec = 0 }
        if (-not $totPag) { $totPag = 0 }

        Write-Host "    Pendentes: Rec=$($recFilt.Count) (R`$$(Fmt $totRec))  Pag=$($pagFilt.Count) (R`$$(Fmt $totPag))  Banco=R`$$(Fmt $saldo)" -ForegroundColor Green

        $payload[$c.id] = [ordered]@{
            name    = $c.name
            color   = $c.color
            dot     = $c.dot
            saldo   = $saldo
            totRec  = $totRec
            totPag  = $totPag
            receber = @($recFilt)
            pagar   = @($pagFilt)
        }

        if ($c.id -ne $companies[-1].id) { Start-Sleep -Seconds 3 }
    }

    # ── Totais consolidados ──
    $gTotRec  = ($payload.Values | ForEach-Object { $_.totRec } | Measure-Object -Sum).Sum
    $gTotPag  = ($payload.Values | ForEach-Object { $_.totPag } | Measure-Object -Sum).Sum
    $gTotBanco= ($payload.Values | ForEach-Object { $_.saldo  } | Measure-Object -Sum).Sum
    if (-not $gTotRec)   { $gTotRec   = 0 }
    if (-not $gTotPag)   { $gTotPag   = 0 }
    if (-not $gTotBanco) { $gTotBanco = 0 }
    $gSaldoProj = $gTotBanco + $gTotRec - $gTotPag

    Write-Host ""
    Write-Host "  CONSOLIDADO: Banco=R`$$(Fmt $gTotBanco)  Rec=R`$$(Fmt $gTotRec)  Pag=R`$$(Fmt $gTotPag)  Proj=R`$$(Fmt $gSaldoProj)" -ForegroundColor Cyan

    # ── Serializa para JS ──
    $dataJson = $payload | ConvertTo-Json -Depth 10 -Compress

    # ── Monta cards de empresa para o consolidado ──
    $compCardsHtml = ""
    foreach ($c in $companies) {
        $d = $payload[$c.id]
        $proj = $d.saldo + $d.totRec - $d.totPag
        $projFmt = "R`$ $(Fmt $proj)"
        $projColor = if ($proj -ge 0) { "#2e7d32" } else { "#c62828" }
        $compCardsHtml += @"
<div class="company-row">
  <div class="company-dot" style="background:$($c.dot)"></div>
  <div class="company-info"><strong>$($d.name)</strong><span>Banco: R`$ $(Fmt $d.saldo)</span></div>
  <div class="pct-bar-wrap">
    <div class="pct-bar-bg"><div class="pct-bar" style="width:$(if($gTotRec -gt 0){[math]::Round($d.totRec/$gTotRec*100,0)}else{0})%;background:$($c.dot)"></div></div>
  </div>
  <div class="company-value"><strong style="color:$projColor">$projFmt</strong><span>projetado</span></div>
</div>
"@
    }

    # ── Tabela mensal ──
    $months = @("Jan","Fev","Mar","Abr","Mai","Jun","Jul","Ago","Set","Out","Nov","Dez")
    $monthlyHtml = ""
    for ($m = 0; $m -lt 12; $m++) {
        $mStr = ($m+1).ToString().PadLeft(2,'0')
        $mRec = 0; $mPag = 0
        foreach ($c in $companies) {
            $d = $payload[$c.id]
            $d.receber | Where-Object { $_.venc -match "^../($mStr)/" } | ForEach-Object { $mRec += $_.saldo }
            $d.pagar   | Where-Object { $_.venc -match "^../($mStr)/" } | ForEach-Object { $mPag += $_.saldo }
        }
        $mLiq = $mRec - $mPag
        $liqColor = if ($mLiq -ge 0) { "color:#2e7d32" } else { "color:#c62828" }
        $monthlyHtml += "<tr><td><strong>$($months[$m])</strong></td><td style='text-align:right;color:#2e7d32;font-weight:700'>R`$ $(Fmt $mRec)</td><td style='text-align:right;color:#c62828;font-weight:700'>R`$ $(Fmt $mPag)</td><td style='text-align:right;$liqColor;font-weight:800'>$(if($mLiq -ge 0){'+'}else{''})R`$ $(Fmt $mLiq)</td></tr>`n"
    }

    # ── Semanas do mês corrente ──
    $curMes = (Get-Date).Month
    $curAno = [int]$Ano
    $daysInMonth = [DateTime]::DaysInMonth($curAno, $curMes)
    $weeksHtml = ""
    $wStart = 1; $wNum = 1
    while ($wStart -le $daysInMonth) {
        $wEnd = [math]::Min($wStart + 6, $daysInMonth)
        $wRec = 0; $wPag = 0
        for ($d = $wStart; $d -le $wEnd; $d++) {
            $dayStr = "$($d.ToString().PadLeft(2,'0'))/$($curMes.ToString().PadLeft(2,'0'))/$Ano"
            foreach ($c in $companies) {
                $cd = $payload[$c.id]
                $cd.receber | Where-Object { $_.venc -eq $dayStr } | ForEach-Object { $wRec += $_.saldo }
                $cd.pagar   | Where-Object { $_.venc -eq $dayStr } | ForEach-Object { $wPag += $_.saldo }
            }
        }
        $wLiq = $wRec - $wPag
        $liqC = if ($wLiq -ge 0) { "#2e7d32" } else { "#c62828" }
        $d1 = [DateTime]::new($curAno, $curMes, $wStart)
        $d2 = [DateTime]::new($curAno, $curMes, $wEnd)
        $weeksHtml += @"
<div class="aging-box $(if($wLiq -ge 0){'green'}else{'red'})">
  <div class="aging-count" style="font-size:18px">Sem $wNum</div>
  <div class="aging-label">$($d1.ToString("dd/MM")) - $($d2.ToString("dd/MM"))</div>
  <div style="margin-top:8px;font-size:12px;color:#2e7d32;font-weight:700">▲ R`$ $(Fmt $wRec)</div>
  <div style="font-size:12px;color:#c62828;font-weight:700">▼ R`$ $(Fmt $wPag)</div>
  <div class="aging-value" style="color:$liqC">$(if($wLiq -ge 0){'+'}else{''})R`$ $(Fmt $wLiq)</div>
</div>
"@
        $wStart = $wEnd + 1; $wNum++
    }

    # ── HTML das abas por empresa ──
    $compTabsHtml = ""
    foreach ($c in $companies) {
        $d = $payload[$c.id]
        $proj = $d.saldo + $d.totRec - $d.totPag
        $projColor = if ($proj -ge 0) { "#2e7d32" } else { "#c62828" }

        # Receber table rows
        $recRows = ($d.receber | Sort-Object { $_.venc } | ForEach-Object {
            $sc = $_.status.ToLower().Replace(" ","-")
            "<tr><td>$($_.venc)</td><td>$($_.nome)</td><td style='color:#888;font-size:11px'>$($_.doc)</td><td style='text-align:right;font-weight:700;color:#2e7d32'>R`$ $(Fmt $_.saldo)</td><td><span class='badge $(if($_.status -eq "ATRASADO"){"orange"}else{"blue"})'>$($_.status)</span></td></tr>"
        }) -join "`n"

        $pagRows = ($d.pagar | Sort-Object { $_.venc } | ForEach-Object {
            "<tr><td>$($_.venc)</td><td>$($_.nome)</td><td style='color:#888;font-size:11px'>$($_.doc)</td><td style='text-align:right;font-weight:700;color:#c62828'>R`$ $(Fmt $_.saldo)</td><td><span class='badge $(if($_.status -eq "ATRASADO"){"red"}else{"blue"})'>$($_.status)</span></td></tr>"
        }) -join "`n"

        # Monthly breakdown for company
        $cMonthlyHtml = ""
        for ($m = 0; $m -lt 12; $m++) {
            $mStr = ($m+1).ToString().PadLeft(2,'0')
            $mRec = ($d.receber | Where-Object { $_.venc -match "^../($mStr)/" } | ForEach-Object { $_.saldo } | Measure-Object -Sum).Sum
            $mPag = ($d.pagar   | Where-Object { $_.venc -match "^../($mStr)/" } | ForEach-Object { $_.saldo } | Measure-Object -Sum).Sum
            if (-not $mRec) { $mRec = 0 }; if (-not $mPag) { $mPag = 0 }
            $mLiq = $mRec - $mPag
            $liqC2 = if ($mLiq -ge 0) { "color:#2e7d32" } else { "color:#c62828" }
            $cMonthlyHtml += "<tr><td><strong>$($months[$m])</strong></td><td style='text-align:right;color:#2e7d32;font-weight:700'>R`$ $(Fmt $mRec)</td><td style='text-align:right;color:#c62828;font-weight:700'>R`$ $(Fmt $mPag)</td><td style='text-align:right;$liqC2;font-weight:800'>$(if($mLiq -ge 0){'+'}else{''})R`$ $(Fmt $mLiq)</td></tr>`n"
        }

        $compTabsHtml += @"
<div id="$($c.id)" class="tab-content">
  <div class="company-header" style="background:linear-gradient(135deg,$($c.color),$(($c.dot)))">
    <h2>$($d.name)</h2>
    <p>Fluxo de Caixa $Ano &nbsp;·&nbsp; Banco: R`$ $(Fmt $d.saldo)</p>
  </div>
  <div class="cards-grid">
    <div class="card"><div class="card-value" style="color:#1e3a5f">R`$ $(Fmt $d.saldo)</div><div class="card-label">Saldo Banco</div></div>
    <div class="card"><div class="card-value" style="color:#2e7d32">R`$ $(Fmt $d.totRec)</div><div class="card-label">A Receber ($($d.receber.Count) títulos)</div></div>
    <div class="card red"><div class="card-value">R`$ $(Fmt $d.totPag)</div><div class="card-label">A Pagar ($($d.pagar.Count) títulos)</div></div>
    <div class="card $(if($proj -ge 0){''}else{'red'})"><div class="card-value" style="color:$projColor">R`$ $(Fmt $proj)</div><div class="card-label">Saldo Projetado</div></div>
  </div>
  <div class="section">
    <h3>Fluxo Mensal — $Ano</h3>
    <div class="table-container"><table>
      <thead><tr><th>Mês</th><th style="text-align:right">A Receber</th><th style="text-align:right">A Pagar</th><th style="text-align:right">Líquido</th></tr></thead>
      <tbody>$cMonthlyHtml</tbody>
    </table></div>
  </div>
  <div class="section">
    <h3>▲ Contas a Receber — $($d.receber.Count) títulos pendentes</h3>
    <div class="table-container"><table>
      <thead><tr><th>Vencimento</th><th>Nome</th><th>Documento</th><th style="text-align:right">Valor</th><th>Status</th></tr></thead>
      <tbody>$(if($recRows){"$recRows"}else{"<tr><td colspan='5' style='text-align:center;color:#aaa;padding:20px'>Sem títulos pendentes</td></tr>"})</tbody>
    </table></div>
  </div>
  <div class="section">
    <h3>▼ Contas a Pagar — $($d.pagar.Count) títulos pendentes</h3>
    <div class="table-container"><table>
      <thead><tr><th>Vencimento</th><th>Nome</th><th>Documento</th><th style="text-align:right">Valor</th><th>Status</th></tr></thead>
      <tbody>$(if($pagRows){"$pagRows"}else{"<tr><td colspan='5' style='text-align:center;color:#aaa;padding:20px'>Sem títulos pendentes</td></tr>"})</tbody>
    </table></div>
  </div>
</div>
"@
    }

    # ── Antecipação ──
    $anteHtml = ""
    foreach ($c in $companies) {
        $d = $payload[$c.id]
        $proj = $d.saldo + $d.totRec - $d.totPag
        $anteNeeded = if ($proj -lt 0) { [math]::Abs($proj) } else { 0 }
        $anteColor = if ($anteNeeded -gt 0) { "#7b1fa2" } else { "#2e7d32" }
        $anteText  = if ($anteNeeded -gt 0) { "R`$ $(Fmt $anteNeeded)" } else { "Nao necessaria" }
        $anteSub   = if ($anteNeeded -gt 0) { "Para manter caixa positivo" } else { "Caixa projetado positivo" }
        $anteHtml += @"
<div class="curr-company-row">
  <div class="curr-company-name"><div class="curr-dot" style="background:$($c.dot)"></div>$($d.name)</div>
  <div><span class="curr-value" style="color:$anteColor">$anteText</span><span class="curr-count">$anteSub</span></div>
</div>
"@
    }
    $gAnte = [math]::Max(0, -$gSaldoProj)

    # ── HTML FINAL ──
    $html = @"
<!DOCTYPE html>
<html lang="pt-BR">
<head>
<meta charset="UTF-8"/>
<meta name="viewport" content="width=device-width,initial-scale=1"/>
<meta http-equiv="refresh" content="$Intervalo"/>
<title>Fluxo de Caixa — ICC Grupo</title>
<style>
* { box-sizing: border-box; margin: 0; padding: 0; }
body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; background: #f0f2f5; color: #222; }
.header { background: linear-gradient(135deg, #0d1b2a, #1e3a5f); color: white; padding: 18px 30px; display: flex; justify-content: space-between; align-items: center; box-shadow: 0 2px 12px rgba(0,0,0,0.3); }
.header-left h1 { font-size: 20px; font-weight: 700; }
.header-left p { font-size: 12px; opacity: 0.65; margin-top: 3px; }
.header-right { text-align: right; font-size: 12px; opacity: 0.75; line-height: 1.6; }
.tabs { background: white; border-bottom: 2px solid #e8e8e8; padding: 0 20px; display: flex; gap: 2px; overflow-x: auto; box-shadow: 0 1px 4px rgba(0,0,0,0.06); }
.tab-btn { padding: 14px 24px; border: none; background: none; cursor: pointer; font-size: 13.5px; font-weight: 500; color: #666; border-bottom: 3px solid transparent; margin-bottom: -2px; transition: all 0.2s; white-space: nowrap; }
.tab-btn:hover { color: #1e3a5f; }
.tab-btn.active { color: #1e3a5f; border-bottom-color: #1e3a5f; font-weight: 700; }
.tab-content { display: none; padding: 24px; max-width: 1440px; margin: 0 auto; }
.tab-content.active { display: block; }
.company-header { color: white; padding: 22px 28px; border-radius: 12px; margin-bottom: 22px; box-shadow: 0 4px 16px rgba(0,0,0,0.18); }
.company-header h2 { font-size: 24px; margin-bottom: 4px; }
.company-header p { opacity: 0.8; font-size: 13px; }
.cards-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(190px, 1fr)); gap: 14px; margin-bottom: 22px; }
.card { background: white; border-radius: 10px; padding: 20px 18px; text-align: center; box-shadow: 0 2px 8px rgba(0,0,0,0.07); border-top: 4px solid #2196F3; transition: transform 0.15s; }
.card:hover { transform: translateY(-2px); }
.card.red { border-top-color: #e53935; }
.card-value { font-size: 26px; font-weight: 800; color: #1e3a5f; margin-bottom: 5px; line-height: 1.1; }
.card.red .card-value { color: #c62828; }
.card-label { font-size: 12px; color: #888; font-weight: 500; }
.section { background: white; border-radius: 10px; padding: 20px 22px; margin-bottom: 18px; box-shadow: 0 2px 8px rgba(0,0,0,0.06); }
.section h3 { font-size: 15px; font-weight: 700; margin-bottom: 16px; color: #1e3a5f; padding-bottom: 10px; border-bottom: 2px solid #f0f2f5; }
.aging-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(150px, 1fr)); gap: 12px; }
.aging-box { border-radius: 10px; padding: 16px 12px; text-align: center; border: 1px solid; }
.aging-box.green  { background: #f1f8e9; border-color: #aed581; }
.aging-box.yellow { background: #fffde7; border-color: #ffe082; }
.aging-box.orange { background: #fff3e0; border-color: #ffcc80; }
.aging-box.red    { background: #ffebee; border-color: #ef9a9a; }
.aging-count { font-size: 28px; font-weight: 800; line-height: 1; color: #1e3a5f; }
.aging-label { font-size: 12px; font-weight: 700; margin: 6px 0 4px; color: #555; }
.aging-value { font-size: 14px; font-weight: 800; margin-top: 8px; padding-top: 8px; border-top: 1px solid rgba(0,0,0,0.09); }
.curr-card { background: white; border-radius: 10px; padding: 20px 22px; margin-bottom: 18px; box-shadow: 0 2px 8px rgba(0,0,0,0.07); border-top: 4px solid #7b1fa2; }
.curr-card-title { font-size: 14px; font-weight: 800; color: #1e3a5f; margin-bottom: 14px; }
.curr-company-row { display: flex; align-items: center; justify-content: space-between; padding: 11px 0; border-bottom: 1px solid #f5f5f5; }
.curr-company-row:last-child { border-bottom: none; }
.curr-company-name { display: flex; align-items: center; gap: 8px; font-size: 13px; font-weight: 600; color: #333; }
.curr-dot   { width: 10px; height: 10px; border-radius: 50%; flex-shrink: 0; }
.curr-value { font-size: 16px; font-weight: 800; }
.curr-count { font-size: 11px; color: #aaa; margin-left: 5px; }
.company-breakdown { display: flex; flex-direction: column; gap: 10px; }
.company-row { display: flex; align-items: center; gap: 14px; padding: 14px 16px; background: #fafbfc; border-radius: 8px; border: 1px solid #ebebeb; }
.company-dot { width: 13px; height: 13px; border-radius: 50%; flex-shrink: 0; }
.company-info { flex: 1; }
.company-info strong { display: block; font-size: 14px; }
.company-info span   { font-size: 12px; color: #999; }
.pct-bar-wrap { flex: 2; }
.pct-bar-bg { background: #eee; border-radius: 4px; height: 6px; }
.pct-bar    { height: 6px; border-radius: 4px; }
.company-value { text-align: right; min-width: 120px; }
.company-value strong { display: block; font-size: 16px; font-weight: 800; }
.company-value span   { font-size: 11px; color: #aaa; }
.table-container { overflow-x: auto; }
table { width: 100%; border-collapse: collapse; font-size: 12.5px; }
thead th { background: #f5f7fa; padding: 10px 12px; text-align: left; font-weight: 700; color: #444; border-bottom: 2px solid #e0e4ea; white-space: nowrap; }
tbody td { padding: 9px 12px; border-bottom: 1px solid #f0f0f0; vertical-align: middle; }
tbody tr:hover td { background: #f9fafb; }
.badge { display: inline-block; padding: 3px 9px; border-radius: 20px; font-size: 11px; font-weight: 700; white-space: nowrap; }
.badge.red    { background: #ffebee; color: #c62828; }
.badge.orange { background: #fff3e0; color: #e65100; }
.badge.blue   { background: #e3f2fd; color: #1565c0; }
.badge.green  { background: #e8f5e9; color: #2e7d32; }
@media (max-width: 768px) { .cards-grid { grid-template-columns: repeat(2,1fr); } .tab-content { padding: 14px; } }
</style>
</head>
<body>
<div class="header">
  <div class="header-left">
    <h1>💰 Fluxo de Caixa — ICC Grupo</h1>
    <p>Gerado automaticamente via integracao Omie API</p>
  </div>
  <div class="header-right">Ultima atualizacao<br><strong>$geradoEm</strong></div>
</div>
<div class="tabs">
  <button class="tab-btn active" data-tab="consolidado" onclick="showTab('consolidado')">📊 Consolidado</button>
  <button class="tab-btn" data-tab="antecipacao"  onclick="showTab('antecipacao')">⚡ Antecipacao</button>
  <button class="tab-btn" data-tab="instituto"    onclick="showTab('instituto')">🏛️ ICC Instituto</button>
  <button class="tab-btn" data-tab="telecom"      onclick="showTab('telecom')">📡 ICC Telecom</button>
  <button class="tab-btn" data-tab="medical"      onclick="showTab('medical')">🏥 ICC Medical</button>
</div>

<!-- ═══ CONSOLIDADO ═══ -->
<div id="consolidado" class="tab-content active">
  <div class="company-header" style="background:linear-gradient(135deg,#0d1b2a,#1e3a5f)">
    <h2>Resumo Executivo Consolidado — ICC Grupo</h2>
    <p>Fluxo de Caixa $Ano &nbsp;·&nbsp; Banco consolidado: R`$ $(Fmt $gTotBanco)</p>
  </div>
  <div class="cards-grid">
    <div class="card"><div class="card-value">R`$ $(Fmt $gTotBanco)</div><div class="card-label">Saldo Banco Consolidado</div></div>
    <div class="card"><div class="card-value" style="color:#2e7d32">R`$ $(Fmt $gTotRec)</div><div class="card-label">Total a Receber ($Ano)</div></div>
    <div class="card red"><div class="card-value">R`$ $(Fmt $gTotPag)</div><div class="card-label">Total a Pagar ($Ano)</div></div>
    <div class="card $(if($gSaldoProj -ge 0){''}else{'red'})"><div class="card-value" style="color:$(if($gSaldoProj -ge 0){'#2e7d32'}else{'#c62828'})">R`$ $(Fmt $gSaldoProj)</div><div class="card-label">Saldo Projetado Final</div></div>
  </div>

  <div class="curr-card">
    <div class="curr-card-title">⚡ Antecipacao necessaria para manter caixa positivo</div>
    $anteHtml
    <div class="curr-company-row" style="border-top:2px solid #e0e0e0;margin-top:8px;padding-top:14px">
      <div style="font-weight:800;color:#4a148c;font-size:14px">TOTAL GRUPO</div>
      <div><span class="curr-value" style="color:$(if($gAnte -gt 0){'#7b1fa2'}else{'#2e7d32'});font-size:20px">$(if($gAnte -gt 0){"R`$ $(Fmt $gAnte)"}else{"Nao necessaria"})</span></div>
    </div>
  </div>

  <div class="section">
    <h3>Fluxo Mensal Consolidado — $Ano</h3>
    <div class="table-container"><table>
      <thead><tr><th>Mes</th><th style="text-align:right">A Receber</th><th style="text-align:right">A Pagar</th><th style="text-align:right">Liquido</th></tr></thead>
      <tbody>$monthlyHtml</tbody>
    </table></div>
  </div>

  <div class="section">
    <h3>Semanas de $(([System.Globalization.CultureInfo]::GetCultureInfo("pt-BR")).DateTimeFormat.GetMonthName($curMes)) — Receita vs Despesa</h3>
    <div class="aging-grid">$weeksHtml</div>
  </div>

  <div class="section">
    <h3>Resultado por Empresa</h3>
    <div class="company-breakdown">$compCardsHtml</div>
  </div>
</div>

<!-- ═══ ANTECIPAÇÃO ═══ -->
<div id="antecipacao" class="tab-content">
  <div class="company-header" style="background:linear-gradient(135deg,#1a0533,#4a148c)">
    <h2>⚡ Antecipacao de Recebiveis</h2>
    <p>Valor minimo a antecipar por empresa para manter caixa positivo</p>
  </div>
  <div class="curr-card">
    <div class="curr-card-title">Antecipacao necessaria — Detalhamento</div>
    $anteHtml
    <div class="curr-company-row" style="border-top:2px solid #e0e0e0;margin-top:8px;padding-top:14px">
      <div style="font-weight:800;color:#4a148c;font-size:14px">TOTAL CONSOLIDADO</div>
      <div><span class="curr-value" style="color:$(if($gAnte -gt 0){'#7b1fa2'}else{'#2e7d32'});font-size:22px">$(if($gAnte -gt 0){"R`$ $(Fmt $gAnte)"}else{"Grupo saudavel ✓"})</span></div>
    </div>
  </div>
  <div class="section">
    <h3>Como interpretar</h3>
    <div style="font-size:13px;line-height:1.7;color:#444">
      <p>O valor de <strong>antecipacao necessaria</strong> representa o montante minimo que cada empresa precisa receber antecipadamente para que o saldo projetado (<em>Banco + A Receber - A Pagar</em>) seja positivo ao final do periodo.</p>
      <br/>
      <p><strong>Formula:</strong> Antecipacao = max(0, A Pagar - Banco - A Receber)</p>
      <br/>
      <p>Os titulos considerados sao apenas os de status <strong>A VENCER</strong> e <strong>ATRASADO</strong> com vencimento em <strong>$Ano</strong>.</p>
    </div>
  </div>
</div>

<!-- ═══ ABAS EMPRESA ═══ -->
$compTabsHtml

<script>
function showTab(id) {
  document.querySelectorAll('.tab-content').forEach(function(t){ t.classList.remove('active'); });
  document.querySelectorAll('.tab-btn').forEach(function(b){ b.classList.remove('active'); });
  var tab = document.getElementById(id);
  if (tab) tab.classList.add('active');
  document.querySelectorAll('.tab-btn').forEach(function(btn){
    if (btn.getAttribute('data-tab') === id) btn.classList.add('active');
  });
}

// Countdown
var cd = $Intervalo;
setInterval(function(){
  cd--;
  if (cd <= 0) cd = $Intervalo;
}, 1000);
</script>
</body>
</html>
"@

    [System.IO.File]::WriteAllText($tmpFile, $html, [System.Text.Encoding]::UTF8)
    Move-Item -Path $tmpFile -Destination $outputFile -Force
    Write-Host "  HTML gerado: index.html ($([math]::Round((Get-Item $outputFile).Length/1KB,1)) KB)" -ForegroundColor Green

    # ── Git push ──
    try {
        Push-Location $scriptDir
        $status = git status --porcelain 2>&1
        if ($status) {
            git add index.html 2>&1 | Out-Null
            git commit -m "Auto: fluxo de caixa $geradoEm" 2>&1 | Out-Null
            $pushResult = git push origin main 2>&1
            Write-Host "  GitHub Pages atualizado!" -ForegroundColor Green
        } else {
            Write-Host "  Sem alteracoes para publicar." -ForegroundColor DarkGray
        }
    } catch {
        Write-Host "  Git push falhou (verifique credenciais): $_" -ForegroundColor Yellow
    } finally {
        Pop-Location
    }
}

# ── Execucao ──
$Host.UI.RawUI.WindowTitle = "ICC Fluxo de Caixa — Monitoramento"
Write-Host ""
Write-Host "  ICC — Fluxo de Caixa  |  Loop a cada $Intervalo segundos" -ForegroundColor Cyan
Write-Host "  GitHub: https://gustavovieira07.github.io/fluxo-de-caixa/" -ForegroundColor Gray
Write-Host ""

if ($Loop) {
    Generate-Report
    Start-Process $outputFile
    while ($true) {
        Write-Host ""
        Write-Host "  Aguardando $Intervalo s..." -ForegroundColor DarkGray
        Start-Sleep -Seconds $Intervalo
        Generate-Report
    }
} else {
    Generate-Report
    Start-Process $outputFile
    Write-Host ""
    Write-Host "  Pressione Enter para fechar." -ForegroundColor Gray
    Read-Host
}
