# =============================================================
#  ICC — Gerador de Fluxo de Caixa
#  Uso: duplo clique em gerar.bat  (atualiza a cada 5 minutos)
# =============================================================
param(
    [string]$Ano        = "2026",
    [switch]$Loop,
    [int]   $Intervalo  = 300   # segundos entre atualizações
)

$ErrorActionPreference = 'Stop'
$scriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$outputFile = Join-Path $scriptDir "relatorio.html"
$tmpFile    = Join-Path $scriptDir "relatorio.tmp.html"

$companies = @(
    [ordered]@{id="instituto"; name="ICC Instituto"; key="3946880386449"; secret="0c15f825cded97455749c7d6b7558f1e"; color="#3b82f6"},
    [ordered]@{id="telecom";   name="ICC Telecom";   key="4472437527558"; secret="eb030b4871537b1d984ff4078a469f75"; color="#10b981"},
    [ordered]@{id="medical";   name="ICC Medical";   key="7069173264153"; secret="9632f5b931f568b6b09accbf25f47496"; color="#f59e0b"}
)

# ── Omie POST ──
function Omie-Post($url, $call, $key, $secret, $params) {
    $body = [ordered]@{ call=$call; app_key=$key; app_secret=$secret; param=@($params) }
    $json = $body | ConvertTo-Json -Depth 10 -Compress
    $resp = Invoke-RestMethod -Uri $url -Method POST `
        -ContentType "application/json" -Body $json -TimeoutSec 60
    if ($resp.faultstring) { throw "[$call] $($resp.faultstring)" }
    return $resp
}

# ── Busca páginas com filtro de data + delay para evitar rate-limit ──
# A API Omie limita 100 registros/página independente do registros_por_pagina solicitado.
# Delay de 700ms entre páginas evita erro "REDUNDANT".
function Get-AllPages($url, $call, $key, $secret, $listKey) {
    $all   = [System.Collections.Generic.List[object]]::new()
    $page  = 1
    $total = 1
    do {
        $params = @{
            pagina               = $page
            registros_por_pagina = 500          # API caps at 100, mas enviamos 500
            filtrar_por_data_de  = "01/01/$Ano"
            filtrar_por_data_ate = "31/12/$Ano"
        }
        $r = Omie-Post $url $call $key $secret $params
        $chunk = $r.$listKey
        if ($chunk) { foreach ($i in $chunk) { $all.Add($i) } }
        $total = [int]($r.total_de_paginas)
        Write-Host "    pág $page/$total  ($($all.Count) reg. no filtro 2026)" -ForegroundColor DarkGray
        $page++
        if ($page -le $total) { Start-Sleep -Milliseconds 700 }  # evita rate-limit
    } while ($page -le $total)
    return $all
}

# ── Normaliza item (flat estrutura Omie) ──
function Norm($item, $tipo) {
    $venc  = "$($item.data_vencimento)"
    $valor = [double]($item.valor_documento)
    $saldo = if ($item.PSObject.Properties['valor_saldo'] -and $item.valor_saldo) { [double]$item.valor_saldo } else { $valor }
    $st    = "$($item.status_titulo)"
    $nome  = if ($item.nome_fantasia)  { "$($item.nome_fantasia)" }
             elseif ($item.nome_cliente)   { "$($item.nome_cliente)" }
             elseif ($item.nome_fornecedor){ "$($item.nome_fornecedor)" }
             elseif ($item.razao_social)   { "$($item.razao_social)" }
             else { "Cód.$($item.codigo_cliente_fornecedor)" }
    $doc   = if ($item.numero_documento) { "$($item.numero_documento)" }
             elseif ($item.numero_parcela){ "$($item.numero_parcela)" }
             else { "$($item.codigo_lancamento_omie)" }
    return [ordered]@{ venc=$venc; valor=$valor; saldo=$saldo; status=$st; nome=$nome; doc=$doc }
}

# ── Filtra por ano no campo data_vencimento ──
function Filter-Year($items, $year) {
    return @($items | Where-Object { ($_.venc -split '/')[2] -eq $year })
}

# ── Gera um relatorio.html com os dados embutidos ──
function Generate-Report {
    Write-Host ""
    Write-Host "  ► Buscando dados Omie..." -ForegroundColor Cyan
    $geradoEm = (Get-Date).ToString("dd/MM/yyyy HH:mm:ss")
    $payload = [ordered]@{}

    foreach ($c in $companies) {
        Write-Host ""
        Write-Host "  $($c.name)" -ForegroundColor Yellow

        Write-Host "    Contas a Receber (todas)..." -ForegroundColor Gray
        $recRaw = Get-AllPages "https://app.omie.com.br/api/v1/financas/contareceber/" `
            "ListarContasReceber" $c.key $c.secret "conta_receber_cadastro"

        Write-Host "    Contas a Pagar (todas)..." -ForegroundColor Gray
        $pagRaw = Get-AllPages "https://app.omie.com.br/api/v1/financas/contapagar/" `
            "ListarContasPagar" $c.key $c.secret "conta_pagar_cadastro"

        Write-Host "    Saldo Banco..." -ForegroundColor Gray
        $saldo = 0.0
        try {
            $sr = Omie-Post "https://app.omie.com.br/api/v1/geral/contacorrente/" `
                "ListarContasCorrentes" $c.key $c.secret @{pagina=1;registros_por_pagina=50}
            $contas = @($sr.ListarContasCorrentes | Where-Object { $_.inativo -ne 'S' })
            $saldo  = [double](($contas | Measure-Object -Property saldo_inicial -Sum).Sum)
        } catch { Write-Host "    (saldo banco indisponível)" -ForegroundColor DarkGray }

        # Normaliza, filtra por vencimento no ano E por status pendente
        # Status pendentes: "A VENCER" (futuro) e "ATRASADO" (vencido não recebido/pago)
        $pendentes = @("A VENCER", "ATRASADO")
        $recNorm = @($recRaw | ForEach-Object { Norm $_ 'rec' })
        $pagNorm = @($pagRaw | ForEach-Object { Norm $_ 'pag' })
        $recFilt = @($recNorm | Where-Object { ($_.venc -split '/')[2] -eq $Ano -and $_.status -in $pendentes })
        $pagFilt = @($pagNorm | Where-Object { ($_.venc -split '/')[2] -eq $Ano -and $_.status -in $pendentes })

        Write-Host "    $Ano pendentes → Receber=$($recFilt.Count)  Pagar=$($pagFilt.Count)  Banco=R`$$([math]::Round($saldo,2))" -ForegroundColor Green

        $payload[$c.id] = [ordered]@{
            name    = $c.name
            color   = $c.color
            saldo   = $saldo
            receber = $recFilt
            pagar   = $pagFilt
        }
    }

    Write-Host ""
    Write-Host "  ► Gerando HTML..." -ForegroundColor Cyan

    $dataJson = $payload | ConvertTo-Json -Depth 10 -Compress

    $html = @"
<!DOCTYPE html>
<html lang="pt-BR">
<head>
<meta charset="UTF-8"/>
<meta name="viewport" content="width=device-width,initial-scale=1"/>
<meta http-equiv="refresh" content="$Intervalo"/>
<title>Fluxo de Caixa ICC — $geradoEm</title>
<script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.0/dist/chart.umd.min.js"></script>
<script>const RAW=$dataJson; const ANO="$Ano";</script>
<style>
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:'Segoe UI',system-ui,sans-serif;background:#f0f4f8;color:#1a2942}
.hdr{background:linear-gradient(135deg,#0d2137,#1a3a5c);color:#fff;padding:14px 28px;display:flex;justify-content:space-between;align-items:center}
.hdr-l h1{font-size:18px;font-weight:700}.hdr-l p{font-size:11px;color:#90aecb;margin-top:2px}
.hdr-r{text-align:right;font-size:11px;color:#90aecb}.hdr-r strong{display:block;font-size:13px;font-weight:700;color:#fff;margin-top:2px}
.refresh-bar{background:#1a3a5c;padding:6px 28px;font-size:11px;color:#90aecb;display:flex;justify-content:space-between}
.tabs{background:#fff;border-bottom:2px solid #dde4ef;display:flex;padding:0 24px;overflow-x:auto;box-shadow:0 1px 4px rgba(0,0,0,.06)}
.tab-btn{padding:12px 18px;border:none;background:transparent;color:#5a7186;font-size:13px;font-weight:500;cursor:pointer;border-bottom:3px solid transparent;white-space:nowrap;transition:all .15s;margin-bottom:-2px}
.tab-btn.active{color:#1a6fc4;border-bottom-color:#1a6fc4;font-weight:700}
.content{padding:20px 28px;max-width:1600px;margin:0 auto}
.panel{display:none}.panel.active{display:block}
.banner{background:linear-gradient(135deg,#0d2137,#1a3a5c);border-radius:10px;padding:20px 26px;margin-bottom:18px;color:#fff}
.banner h2{font-size:19px;font-weight:700;margin-bottom:3px}.banner p{font-size:12px;color:#90aecb}
.kgrid{display:grid;grid-template-columns:repeat(auto-fit,minmax(180px,1fr));gap:14px;margin-bottom:18px}
.kcard{background:#fff;border-radius:10px;padding:16px 18px;box-shadow:0 1px 4px rgba(0,0,0,.07);border:1px solid #dde4ef;border-top:3px solid #1a6fc4}
.kcard.red{border-top-color:#e53e3e}.kcard.grn{border-top-color:#2f855a}.kcard.pur{border-top-color:#6b46c1}
.klbl{font-size:10px;color:#5a7186;font-weight:700;text-transform:uppercase;letter-spacing:.05em;margin-bottom:7px}
.kval{font-size:22px;font-weight:800;color:#1a2942;line-height:1}
.kval.red{color:#c53030}.kval.grn{color:#276749}.kval.pur{color:#6b46c1}
.ksub{font-size:11px;color:#718096;margin-top:4px}
.ante-card{background:linear-gradient(135deg,#1a1756,#2d3498,#1a3a5c);border-radius:10px;padding:20px 24px;margin-bottom:18px;color:#fff;box-shadow:0 4px 15px rgba(26,111,196,.25)}
.ante-title{font-size:11px;font-weight:700;color:#a5b4fc;text-transform:uppercase;letter-spacing:.06em;margin-bottom:14px}
.ante-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(160px,1fr))}
.ante-item{padding:0 18px;text-align:center;border-right:1px solid rgba(255,255,255,.1)}
.ante-item:first-child{padding-left:0}.ante-item:last-child{border-right:none}
.ante-lbl{font-size:11px;color:#a5b4fc;margin-bottom:3px}
.ante-val{font-size:21px;font-weight:800;color:#fbbf24}
.ante-date{font-size:10px;color:#818cf8;margin-top:2px}
.ante-ok{font-size:17px;font-weight:700;color:#6ee7b7}
.chart-card{background:#fff;border-radius:10px;padding:16px 18px;box-shadow:0 1px 4px rgba(0,0,0,.07);border:1px solid #dde4ef;margin-bottom:18px}
.chart-title{font-size:13px;font-weight:700;color:#2d3748;margin-bottom:12px}
.chart-canvas{position:relative;height:260px}
.drill-bar{background:#fff;border:1px solid #dde4ef;border-radius:10px;padding:12px 18px;margin-bottom:18px;display:flex;align-items:center;gap:10px;flex-wrap:wrap}
.drill-bar label{font-size:12px;font-weight:700;color:#1a2942}
.mnav{display:flex;gap:4px;flex-wrap:wrap}
.mbtn{background:#f0f4f8;border:1px solid #c8d6e5;border-radius:6px;padding:4px 9px;font-size:12px;cursor:pointer;color:#1a2942;transition:all .1s}
.mbtn:hover,.mbtn.on{background:#1a6fc4;color:#fff;border-color:#1a6fc4;font-weight:700}
.week-card{background:#fff;border-radius:10px;padding:16px 18px;box-shadow:0 1px 4px rgba(0,0,0,.07);border:1px solid #dde4ef;margin-bottom:18px}
.week-title{font-size:13px;font-weight:700;color:#2d3748;margin-bottom:12px;display:flex;justify-content:space-between;align-items:center}
.wgrid{display:grid;grid-template-columns:repeat(auto-fit,minmax(155px,1fr));gap:12px}
.witem{border:1px solid #e2e8f0;border-radius:8px;padding:12px;position:relative;overflow:hidden}
.witem.best-r{border-color:#c6f6d5;background:#f0fff4}.witem.best-p{border-color:#fed7d7;background:#fff5f5}
.wnum{font-size:10px;font-weight:700;color:#718096;text-transform:uppercase;margin-bottom:4px}
.wdates{font-size:10px;color:#a0aec0;margin-bottom:7px}
.wrec{font-size:14px;font-weight:800;color:#276749}
.wpag{font-size:14px;font-weight:800;color:#c53030;margin-top:4px}
.wbal{font-size:12px;font-weight:700;margin-top:5px;padding-top:5px;border-top:1px solid #e2e8f0}
.wbar{height:4px;border-radius:2px;margin-top:3px}
.wbadge{position:absolute;top:6px;right:6px;font-size:9px;padding:2px 5px;border-radius:3px;font-weight:700}
.daily-card{background:#fff;border-radius:10px;overflow:hidden;box-shadow:0 1px 4px rgba(0,0,0,.07);border:1px solid #dde4ef;margin-bottom:18px}
.daily-head{padding:12px 16px;border-bottom:1px solid #edf2f7;display:flex;justify-content:space-between;align-items:center}
.daily-scroll{max-height:520px;overflow-y:auto}
.two-col{display:grid;grid-template-columns:1fr 1fr;gap:16px;margin-bottom:18px}
@media(max-width:900px){.two-col{grid-template-columns:1fr}}
.tcard{background:#fff;border-radius:10px;overflow:hidden;box-shadow:0 1px 4px rgba(0,0,0,.07);border:1px solid #dde4ef}
.thead2{padding:12px 16px;display:flex;justify-content:space-between;align-items:center;border-bottom:1px solid #edf2f7}
.tscroll{max-height:380px;overflow-y:auto;overflow-x:auto}
table{width:100%;border-collapse:collapse}
thead th{background:#f7fafc;padding:8px 12px;text-align:left;font-size:10px;font-weight:700;text-transform:uppercase;letter-spacing:.05em;color:#718096;position:sticky;top:0;border-bottom:1px solid #e2e8f0}
tbody tr{border-bottom:1px solid #f0f4f8}
tbody tr:hover{background:#f7fafc}
td{padding:8px 12px;font-size:12px;color:#2d3748}
.badge{display:inline-block;padding:2px 7px;border-radius:4px;font-size:10px;font-weight:700;text-transform:uppercase}
.b-aberto,.b-a-vencer{background:#eff6ff;color:#1a6fc4;border:1px solid #bfdbfe}
.b-atrasado{background:#fffbeb;color:#92400e;border:1px solid #fde68a}
.b-recebido,.b-pago{background:#f0fff4;color:#276749;border:1px solid #c6f6d5}
.b-cancelado{background:#f7fafc;color:#a0aec0;border:1px solid #e2e8f0}
.cdot{display:inline-block;width:8px;height:8px;border-radius:50%;margin-right:5px;vertical-align:middle}
.pos{color:#276749;font-weight:700}.neg{color:#c53030;font-weight:700}.zer{color:#718096}
::-webkit-scrollbar{width:5px;height:5px}::-webkit-scrollbar-thumb{background:#c8d6e5;border-radius:4px}
</style>
</head>
<body>
<div class="hdr">
  <div class="hdr-l"><h1>📊 Fluxo de Caixa — ICC Grupo</h1><p>Integração Omie API · Ano $Ano</p></div>
  <div class="hdr-r">Gerado em<strong id="gerado">$geradoEm</strong></div>
</div>
<div class="refresh-bar">
  <span>⏱ Próxima atualização automática em <span id="countdown">$Intervalo</span>s</span>
  <span>Receber: Instituto + Telecom + Medical &nbsp;|&nbsp; Pagar: Instituto + Telecom + Medical</span>
</div>
<div class="tabs">
  <button class="tab-btn active" onclick="T(this,'resumo')">📊 Consolidado</button>
  <button class="tab-btn" onclick="T(this,'ante')">⚡ Antecipação</button>
  <button class="tab-btn" onclick="T(this,'instituto')">🏛️ ICC Instituto</button>
  <button class="tab-btn" onclick="T(this,'telecom')">📡 ICC Telecom</button>
  <button class="tab-btn" onclick="T(this,'medical')">🏥 ICC Medical</button>
</div>
<div class="content">
  <div id="resumo"    class="panel active"></div>
  <div id="ante"      class="panel"></div>
  <div id="instituto" class="panel"></div>
  <div id="telecom"   class="panel"></div>
  <div id="medical"   class="panel"></div>
</div>
<script>
'use strict';
const MO=['Janeiro','Fevereiro','Março','Abril','Maio','Junho','Julho','Agosto','Setembro','Outubro','Novembro','Dezembro'];
const MS=['Jan','Fev','Mar','Abr','Mai','Jun','Jul','Ago','Set','Out','Nov','Dez'];
const DW=['Dom','Seg','Ter','Qua','Qui','Sex','Sáb'];
const PENDINGS=['A VENCER','ATRASADO','ABERTO',''];
let charts={}, selMes=new Date().getMonth();

const fc=v=>new Intl.NumberFormat('pt-BR',{minimumFractionDigits:2,maximumFractionDigits:2}).format(v||0);
const ots=s=>{if(!s||!s.includes('/'))return 0;const[d,m,y]=s.split('/');return new Date(+y,+m-1,+d).getTime();};
const omo=s=>{if(!s||!s.includes('/'))return-1;return+s.split('/')[1]-1;};
// Only count pending (not yet received/paid) for cash flow calculations
const isPending=s=>PENDINGS.includes((s||'').toUpperCase());

function T(btn,id){
  document.querySelectorAll('.panel').forEach(p=>p.classList.remove('active'));
  document.querySelectorAll('.tab-btn').forEach(b=>b.classList.remove('active'));
  document.getElementById(id).classList.add('active');
  btn.classList.add('active');
}

// monthly — only ABERTO/ATRASADO counts for projection
function byMonth(rec,pag){
  const m=Array.from({length:12},(_,i)=>({month:i,receber:0,pagar:0}));
  rec.forEach(r=>{if(isPending(r.status)){const mo=omo(r.venc);if(mo>=0)m[mo].receber+=r.saldo;}});
  pag.forEach(p=>{if(isPending(p.status)){const mo=omo(p.venc);if(mo>=0)m[mo].pagar+=p.saldo;}});
  return m;
}

function calcAnte(monthly,sb){
  let run=sb||0,min=run,minMon=-1;
  const running=monthly.map((m,i)=>{run+=m.receber-m.pagar;if(run<min){min=run;minMon=i;}return run;});
  return{needed:min<0?Math.abs(min):0,minMon,minBalance:min,running};
}

function mkChart(id,monthly,color,sb){
  if(charts[id])charts[id].destroy();
  const{running}=calcAnte(monthly,sb);
  charts[id]=new Chart(document.getElementById(id).getContext('2d'),{
    data:{labels:MS,datasets:[
      {type:'bar',label:'Entradas (ABERTO)',data:monthly.map(m=>m.receber),backgroundColor:'rgba(39,103,73,.6)',borderColor:'#2f855a',borderWidth:1},
      {type:'bar',label:'Saídas (ABERTO)',data:monthly.map(m=>-m.pagar),backgroundColor:'rgba(197,48,48,.5)',borderColor:'#c53030',borderWidth:1},
      {type:'line',label:'Saldo Acum.',data:running,borderColor:color,backgroundColor:'transparent',borderWidth:2.5,pointRadius:3,tension:.3,yAxisID:'y2'},
    ]},
    options:{responsive:true,maintainAspectRatio:false,interaction:{mode:'index',intersect:false},
      plugins:{legend:{labels:{color:'#4a5568',font:{size:11}}},tooltip:{callbacks:{label:c=>` ${c.dataset.label}: R$ ${fc(Math.abs(c.parsed.y))}`}}},
      scales:{
        x:{ticks:{color:'#718096',font:{size:11}},grid:{color:'#f0f4f8'}},
        y:{ticks:{color:'#718096',font:{size:10},callback:v=>'R$'+fc(v)},grid:{color:'rgba(224,231,239,.6)'}},
        y2:{position:'right',ticks:{color,font:{size:10},callback:v=>'R$'+fc(v)},grid:{drawOnChartArea:false}}
      }
    }
  });
}

function fillTbl(bodyId,ctId,rows){
  const s=[...rows].sort((a,b)=>ots(a.venc)-ots(b.venc));
  if(ctId)document.getElementById(ctId).textContent=rows.length+' reg.';
  document.getElementById(bodyId).innerHTML=s.length?s.map(r=>{
    const sc=(r.status||'a vencer').toLowerCase().replace(/\s+/g,'-');
    return`<tr><td style="white-space:nowrap;font-weight:600">${r.venc||'—'}</td>
      <td style="max-width:180px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap" title="${r.nome}">${r.nome}</td>
      <td style="color:#718096;font-size:11px">${r.doc}</td>
      <td style="text-align:right;font-weight:700">R$ ${fc(r.saldo)}</td>
      <td><span class="badge b-${sc}">${r.status||'—'}</span></td></tr>`;
  }).join(''):`<tr><td colspan="5" style="text-align:center;padding:22px;color:#718096">Sem registros</td></tr>`;
}

// Weeks
function buildWeeks(mo){
  const yr=+ANO,dim=new Date(yr,mo+1,0).getDate();
  const weeks=[],mm=String(mo+1).padStart(2,'0');
  let ws=1,wn=1;
  while(ws<=dim){const we=Math.min(ws+6,dim);weeks.push({n:wn,s:ws,e:we,rec:0,pag:0});wn++;ws=we+1;}
  Object.values(RAW).forEach(d=>{
    d.receber.forEach(r=>{ if(!isPending(r.status)||omo(r.venc)!==mo)return; const day=+r.venc.split('/')[0]; const w=weeks.find(w=>day>=w.s&&day<=w.e); if(w)w.rec+=r.saldo; });
    d.pagar.forEach(p=>{   if(!isPending(p.status)||omo(p.venc)!==mo)return; const day=+p.venc.split('/')[0]; const w=weeks.find(w=>day>=w.s&&day<=w.e); if(w)w.pag+=p.saldo; });
  });
  return weeks;
}

function renderWeekly(mo){
  const weeks=buildWeeks(mo);
  const maxR=Math.max(...weeks.map(w=>w.rec),1),maxP=Math.max(...weeks.map(w=>w.pag),1);
  const bri=weeks.reduce((bi,w,i)=>w.rec>weeks[bi].rec?i:bi,0);
  const bpi=weeks.reduce((bi,w,i)=>w.pag>weeks[bi].pag?i:bi,0);
  const yr=+ANO,mm2=String(mo+1).padStart(2,'0');
  return`<div class="week-card"><div class="week-title"><span>Semanas de ${MO[mo]} — Receita e Despesa</span><span style="font-size:11px;color:#718096">🟢 Maior receita &nbsp;🔴 Maior despesa</span></div>
  <div class="wgrid">${weeks.map((w,i)=>{
    const saldo=w.rec-w.pag,d1=new Date(yr,mo,w.s),d2=new Date(yr,mo,w.e);
    const dd1=String(w.s).padStart(2,'0'),dd2=String(w.e).padStart(2,'0');
    const cls=i===bri&&w.rec>0?'best-r':i===bpi&&w.pag>0?'best-p':'';
    return`<div class="witem ${cls}">
      ${i===bri&&w.rec>0?'<span class="wbadge" style="background:#c6f6d5;color:#276749">▲ Maior rec.</span>':''}
      ${i===bpi&&w.pag>0?'<span class="wbadge" style="background:#fed7d7;color:#c53030">▼ Maior desp.</span>':''}
      <div class="wnum">Semana ${w.n}</div>
      <div class="wdates">${DW[d1.getDay()]} ${dd1}/${mm2} → ${DW[d2.getDay()]} ${dd2}/${mm2}</div>
      <div class="wrec">▲ R$ ${fc(w.rec)}</div>
      <div class="wbar" style="width:${Math.round(w.rec/maxR*100)}%;background:#2f855a"></div>
      <div class="wpag" style="margin-top:5px">▼ R$ ${fc(w.pag)}</div>
      <div class="wbar" style="width:${Math.round(w.pag/maxP*100)}%;background:#c53030"></div>
      <div class="wbal ${saldo>=0?'pos':'neg'}">${saldo>=0?'+':'-'}R$ ${fc(Math.abs(saldo))}</div>
    </div>`;}).join('')}</div></div>`;
}

// Daily
function buildDayMap(mo){
  const yr=+ANO,dim=new Date(yr,mo+1,0).getDate(),map={};
  for(let d=1;d<=dim;d++){const dd=String(d).padStart(2,'0'),mm=String(mo+1).padStart(2,'0');map[`${dd}/${mm}/${yr}`]={rec:0,pag:0,rcnt:0,pcnt:0};}
  Object.values(RAW).forEach(d=>{
    d.receber.forEach(r=>{if(isPending(r.status)&&omo(r.venc)===mo&&map[r.venc]){map[r.venc].rec+=r.saldo;map[r.venc].rcnt++;}});
    d.pagar.forEach(p=>  {if(isPending(p.status)&&omo(p.venc)===mo&&map[p.venc]){map[p.venc].pag+=p.saldo;map[p.venc].pcnt++;}});
  });
  return Object.entries(map).map(([date,v])=>({date,...v})).sort((a,b)=>ots(a.date)-ots(b.date));
}

function renderDaily(mo,sb){
  const rows=buildDayMap(mo),yr=+ANO;
  const maxV=Math.max(...rows.map(r=>Math.max(r.rec,r.pag)),1);
  let run=sb||0;
  const n=new Date(),todayStr=`${String(n.getDate()).padStart(2,'0')}/${String(n.getMonth()+1).padStart(2,'0')}/${n.getFullYear()}`;
  const trs=rows.map(r=>{
    const d=new Date(yr,mo,+r.date.split('/')[0]),dow=d.getDay(),isWE=dow===0||dow===6,isToday=r.date===todayStr;
    const liq=r.rec-r.pag; run+=liq;
    const pR=Math.round(r.rec/maxV*90),pP=Math.round(r.pag/maxV*90),hasDat=r.rec>0||r.pag>0;
    return`<tr style="${isToday?'background:#eff6ff':isWE?'background:#fafbfc':''}${!hasDat?';opacity:.35':''}">
      <td style="font-weight:700;white-space:nowrap;color:#1a3a5c">${r.date.slice(0,5)}</td>
      <td style="color:#718096">${DW[dow]}</td>
      <td style="text-align:right;color:#276749;font-weight:${r.rec>0?700:400}">${r.rec>0?'R$ '+fc(r.rec):'—'}</td>
      <td style="text-align:right;color:#c53030;font-weight:${r.pag>0?700:400}">${r.pag>0?'R$ '+fc(r.pag):'—'}</td>
      <td style="text-align:right" class="${liq>0?'pos':liq<0?'neg':'zer'}">${liq!==0?(liq>0?'+':'-')+'R$ '+fc(Math.abs(liq)):'—'}</td>
      <td style="text-align:right;font-weight:700" class="${run>=0?'pos':'neg'}">R$ ${fc(run)}</td>
      <td><div style="display:flex;flex-direction:column;gap:2px">
        ${r.rec>0?`<div style="display:flex;align-items:center;gap:2px"><span style="font-size:9px;color:#276749;width:8px">▲</span><div style="height:5px;width:${pR}px;background:#2f855a;border-radius:2px"></div></div>`:''}
        ${r.pag>0?`<div style="display:flex;align-items:center;gap:2px"><span style="font-size:9px;color:#c53030;width:8px">▼</span><div style="height:5px;width:${pP}px;background:#c53030;border-radius:2px"></div></div>`:''}
      </td>
      <td style="font-size:11px;color:#718096">${r.rcnt>0?`<span style="color:#276749">+${r.rcnt}</span>`:''} ${r.pcnt>0?`<span style="color:#c53030">-${r.pcnt}</span>`:''}</td>
    </tr>`;}).join('');
  return`<div class="daily-card">
    <div class="daily-head"><span style="font-size:13px;font-weight:700">Fluxo Diário — ${MO[mo]} ${ANO} (Consolidado)</span><span style="font-size:11px;color:#718096">Saldo inicial: R$ ${fc(sb)}</span></div>
    <div class="daily-scroll"><table>
      <thead><tr><th>Data</th><th>Dia</th><th style="text-align:right">Entradas</th><th style="text-align:right">Saídas</th><th style="text-align:right">Líquido</th><th style="text-align:right">Saldo Acum.</th><th>Vol.</th><th>Títulos</th></tr></thead>
      <tbody>${trs}</tbody>
    </table></div>
  </div>`;
}

function monthNav(mo){
  return`<div class="drill-bar"><label>📅 Mês:</label><div class="mnav">${MS.map((m,i)=>`<button class="mbtn${i===mo?' on':''}" onclick="changeMes(${i},this)">${m}</button>`).join('')}</div></div>`;
}
function changeMes(mo,btn){
  selMes=mo;
  const sb=Object.values(RAW).reduce((s,d)=>s+d.saldo,0);
  document.getElementById('weekly-area').innerHTML=renderWeekly(mo);
  document.getElementById('daily-area').innerHTML=renderDaily(mo,sb);
  document.querySelectorAll('.mbtn').forEach(b=>b.classList.remove('on'));
  btn.classList.add('on');
}

function render(){
  const ids=Object.keys(RAW);
  let tR=0,tP=0,tB=0;
  const merged=Array.from({length:12},(_,i)=>({month:i,receber:0,pagar:0}));
  const compRows=[];

  ids.forEach(id=>{
    const d=RAW[id];
    const mo=byMonth(d.receber,d.pagar);
    const ante=calcAnte(mo,d.saldo);
    const totR=d.receber.filter(r=>isPending(r.status)).reduce((s,r)=>s+r.saldo,0);
    const totP=d.pagar.filter(p=>isPending(p.status)).reduce((s,p)=>s+p.saldo,0);
    const proj=d.saldo+totR-totP;
    tR+=totR;tP+=totP;tB+=d.saldo;
    mo.forEach((m,i)=>{merged[i].receber+=m.receber;merged[i].pagar+=m.pagar;});
    compRows.push({id,d,mo,ante,totR,totP,proj});

    document.getElementById(id).innerHTML=`
      <div class="banner" style="border-left:5px solid ${d.color}"><h2>${d.name}</h2><p>Ano ${ANO} · Banco: R$ ${fc(d.saldo)}</p></div>
      <div class="kgrid">
        <div class="kcard grn"><div class="klbl">Saldo Banco</div><div class="kval grn">R$ ${fc(d.saldo)}</div><div class="ksub">Contas correntes</div></div>
        <div class="kcard"><div class="klbl">A Receber (pendente)</div><div class="kval" style="color:#276749">R$ ${fc(totR)}</div><div class="ksub">${d.receber.filter(r=>isPending(r.status)).length} títulos abertos</div></div>
        <div class="kcard red"><div class="klbl">A Pagar (pendente)</div><div class="kval red">R$ ${fc(totP)}</div><div class="ksub">${d.pagar.filter(p=>isPending(p.status)).length} títulos abertos</div></div>
        <div class="kcard ${proj>=0?'grn':'red'}"><div class="klbl">Saldo Projetado</div><div class="kval ${proj>=0?'grn':'red'}">R$ ${fc(proj)}</div><div class="ksub">Banco + Receber − Pagar</div></div>
        <div class="kcard pur"><div class="klbl">Antecipação Necessária</div><div class="kval pur">${ante.needed>0?'R$ '+fc(ante.needed):'Não necessária'}</div><div class="ksub">${ante.needed>0?'Déficit em '+MS[ante.minMon]+'/'+ANO:'Caixa positivo ✓'}</div></div>
      </div>
      <div class="chart-card"><div class="chart-title">📈 Fluxo Mensal — ${d.name}</div><div class="chart-canvas"><canvas id="ch_${id}"></canvas></div></div>
      <div class="two-col">
        <div class="tcard"><div class="thead2"><span style="font-weight:700;color:#276749">▲ A Receber (${d.receber.length} total)</span><span id="ct_rec_${id}" style="font-size:11px;color:#718096"></span></div><div class="tscroll"><table><thead><tr><th>Vencimento</th><th>Nome/Cód.</th><th>Documento</th><th style="text-align:right">Valor</th><th>Status</th></tr></thead><tbody id="rec_${id}"></tbody></table></div></div>
        <div class="tcard"><div class="thead2"><span style="font-weight:700;color:#c53030">▼ A Pagar (${d.pagar.length} total)</span><span id="ct_pag_${id}" style="font-size:11px;color:#718096"></span></div><div class="tscroll"><table><thead><tr><th>Vencimento</th><th>Nome/Cód.</th><th>Documento</th><th style="text-align:right">Valor</th><th>Status</th></tr></thead><tbody id="pag_${id}"></tbody></table></div></div>
      </div>`;
    requestAnimationFrame(()=>{
      mkChart('ch_'+id,mo,d.color,d.saldo);
      fillTbl('rec_'+id,'ct_rec_'+id,d.receber);
      fillTbl('pag_'+id,'ct_pag_'+id,d.pagar);
    });
  });

  const tProj=tB+tR-tP, tAnte=compRows.reduce((s,c)=>s+c.ante.needed,0);
  const mergedAnte=calcAnte(merged,tB);
  const anteHtml=compRows.map(c=>`<div class="ante-item">
    <div class="ante-lbl" style="color:${c.d.color}">${c.d.name}</div>
    ${c.ante.needed>0?`<div class="ante-val">R$ ${fc(c.ante.needed)}</div><div class="ante-date">Déficit em ${MS[c.ante.minMon]}/${ANO}</div>`:`<div class="ante-ok">Positivo ✓</div>`}
  </div>`).join('');

  document.getElementById('resumo').innerHTML=`
    <div class="banner"><h2>Resumo Executivo Consolidado — ICC Grupo</h2><p>Fluxo ${ANO} · Banco consolidado: R$ ${fc(tB)}</p></div>
    <div class="kgrid">
      <div class="kcard grn"><div class="klbl">Saldo Banco Consolidado</div><div class="kval grn">R$ ${fc(tB)}</div><div class="ksub">3 empresas</div></div>
      <div class="kcard"><div class="klbl">Total a Receber (${ANO})</div><div class="kval" style="color:#276749">R$ ${fc(tR)}</div><div class="ksub">Títulos pendentes</div></div>
      <div class="kcard red"><div class="klbl">Total a Pagar (${ANO})</div><div class="kval red">R$ ${fc(tP)}</div><div class="ksub">Títulos pendentes</div></div>
      <div class="kcard ${tProj>=0?'grn':'red'}"><div class="klbl">Saldo Projetado Final</div><div class="kval ${tProj>=0?'grn':'red'}">R$ ${fc(tProj)}</div><div class="ksub">Banco + Receber − Pagar</div></div>
      <div class="kcard pur"><div class="klbl">Antecipação Total</div><div class="kval pur">${tAnte>0?'R$ '+fc(tAnte):'Não necessária'}</div><div class="ksub">Para manter caixa positivo</div></div>
    </div>
    <div class="ante-card"><div class="ante-title">⚡ Antecipação necessária para manter caixa positivo</div>
      <div class="ante-grid">${anteHtml}
        <div class="ante-item" style="border-left:1px solid rgba(255,255,255,.2);padding-left:20px">
          <div class="ante-lbl" style="color:#c4b5fd">TOTAL GRUPO</div>
          ${tAnte>0?`<div class="ante-val" style="font-size:24px">R$ ${fc(tAnte)}</div>`:`<div class="ante-ok" style="font-size:20px">Grupo saudável ✓</div>`}
        </div>
      </div>
    </div>
    ${monthNav(selMes)}
    <div id="weekly-area">${renderWeekly(selMes)}</div>
    <div id="daily-area">${renderDaily(selMes,tB)}</div>
    <div class="chart-card"><div class="chart-title">📈 Fluxo Mensal Consolidado ${ANO}</div><div class="chart-canvas"><canvas id="ch_resumo"></canvas></div></div>
    <div class="tcard" style="margin-bottom:18px"><div class="thead2"><span style="font-weight:700">Resumo por Empresa</span></div>
      <div class="tscroll"><table><thead><tr><th>Empresa</th><th style="text-align:right">Banco</th><th style="text-align:right">A Receber</th><th style="text-align:right">A Pagar</th><th style="text-align:right">Projetado</th><th style="text-align:right">Antecipação</th><th>Pior Mês</th></tr></thead>
      <tbody>${compRows.map(c=>`<tr>
        <td><span class="cdot" style="background:${c.d.color}"></span>${c.d.name}</td>
        <td style="text-align:right;color:#276749;font-weight:700">R$ ${fc(c.d.saldo)}</td>
        <td style="text-align:right;color:#276749">R$ ${fc(c.totR)}</td>
        <td style="text-align:right;color:#c53030">R$ ${fc(c.totP)}</td>
        <td style="text-align:right;font-weight:700" class="${c.proj>=0?'pos':'neg'}">R$ ${fc(c.proj)}</td>
        <td style="text-align:right;color:${c.ante.needed>0?'#6b46c1':'#276749'};font-weight:700">${c.ante.needed>0?'R$ '+fc(c.ante.needed):'—'}</td>
        <td style="color:#718096">${c.ante.needed>0?MS[c.ante.minMon]+'/'+ANO:'—'}</td>
      </tr>`).join('')}</tbody></table></div></div>`;

  document.getElementById('ante').innerHTML=`
    <div class="banner"><h2>⚡ Antecipação de Recebíveis</h2><p>Valor mínimo a antecipar por empresa para manter caixa positivo</p></div>
    <div class="ante-card"><div class="ante-title">Antecipação necessária</div>
      <div class="ante-grid">${anteHtml}
        <div class="ante-item" style="border-left:1px solid rgba(255,255,255,.2);padding-left:20px">
          <div class="ante-lbl" style="color:#c4b5fd">TOTAL GRUPO</div>
          ${tAnte>0?`<div class="ante-val" style="font-size:24px">R$ ${fc(tAnte)}</div><div class="ante-date">Soma dos déficits</div>`:`<div class="ante-ok" style="font-size:20px">Grupo saudável ✓</div>`}
        </div>
      </div>
    </div>
    <div class="chart-card"><div class="chart-title">📉 Saldo Consolidado — Com vs Sem Antecipação</div><div class="chart-canvas"><canvas id="ch_ante"></canvas></div></div>
    <div class="kgrid">${compRows.map(c=>{
      const pct=c.totR>0?(c.ante.needed/c.totR*100).toFixed(1):0;
      return`<div class="kcard pur" style="border-top-color:${c.d.color}">
        <div class="klbl">${c.d.name}</div>
        <div class="kval" style="color:${c.d.color};font-size:18px">${c.ante.needed>0?'R$ '+fc(c.ante.needed):'Não necessária'}</div>
        <div class="ksub">${c.ante.needed>0?pct+'% do recebível · '+MS[c.ante.minMon]+'/'+ANO:'Banco cobre os pagamentos'}</div>
      </div>`;}).join('')}</div>`;

  requestAnimationFrame(()=>{
    mkChart('ch_resumo',merged,'#1a6fc4',tB);
    const withAnte=(()=>{let r=tB+mergedAnte.needed;return merged.map(m=>{r+=m.receber-m.pagar;return r;});})();
    if(charts.ch_ante)charts.ch_ante.destroy();
    charts.ch_ante=new Chart(document.getElementById('ch_ante').getContext('2d'),{
      data:{labels:MS,datasets:[
        {type:'line',label:'Sem antecipação',data:mergedAnte.running,borderColor:'#c53030',backgroundColor:'rgba(197,48,48,.07)',borderWidth:2.5,fill:true,tension:.3,pointRadius:3},
        {type:'line',label:'Com antecipação',data:withAnte,borderColor:'#276749',backgroundColor:'rgba(39,103,73,.07)',borderWidth:2.5,fill:true,tension:.3,pointRadius:3},
        {type:'line',label:'Zero',data:Array(12).fill(0),borderColor:'#a0aec0',borderDash:[4,3],borderWidth:1,pointRadius:0},
      ]},
      options:{responsive:true,maintainAspectRatio:false,
        plugins:{legend:{labels:{color:'#4a5568',font:{size:11}}},tooltip:{callbacks:{label:c=>` ${c.dataset.label}: R$ ${fc(c.parsed.y)}`}}},
        scales:{x:{ticks:{color:'#718096',font:{size:11}},grid:{color:'#f0f4f8'}},y:{ticks:{color:'#718096',font:{size:10},callback:v=>'R$'+fc(v)},grid:{color:'rgba(224,231,239,.6)'}}}
      }
    });
  });
}

// Countdown
let cd=$Intervalo;
setInterval(()=>{cd--;const el=document.getElementById('countdown');if(el)el.textContent=cd;if(cd<=0)cd=$Intervalo;},1000);

render();
</script>
</body>
</html>
"@

    # Write via temp file to avoid partial reads
    [System.IO.File]::WriteAllText($tmpFile, $html, [System.Text.Encoding]::UTF8)
    Move-Item -Path $tmpFile -Destination $outputFile -Force

    Write-Host "  ✅ relatorio.html atualizado — $geradoEm" -ForegroundColor Green
}

# ── Execução ──
$Host.UI.RawUI.WindowTitle = "ICC Fluxo de Caixa — Monitoramento"

if ($Loop) {
    # Abre o arquivo na primeira execução
    Write-Host "  Modo contínuo: atualiza a cada $Intervalo segundos." -ForegroundColor Cyan
    Generate-Report
    Start-Process $outputFile
    while ($true) {
        Write-Host ""
        Write-Host "  Aguardando $Intervalo segundos para próxima atualização..." -ForegroundColor DarkGray
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
