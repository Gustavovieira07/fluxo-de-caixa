# ============================================================
#  ICC — Gerador de Fluxo de Caixa
#  Uso: duplo clique em gerar.bat  (ou: powershell -File gerar.ps1)
#  Gera relatorio.html com dados do Omie já embutidos.
# ============================================================
param(
    [string]$De  = "01/01/2026",
    [string]$Ate = "31/12/2026"
)

$Host.UI.RawUI.WindowTitle = "ICC - Gerando Fluxo de Caixa..."
Write-Host ""
Write-Host "  ICC - Fluxo de Caixa  |  Buscando dados Omie..." -ForegroundColor Cyan
Write-Host "  Período: $De a $Ate" -ForegroundColor Gray
Write-Host ""

$companies = @(
    [ordered]@{id="instituto"; name="ICC Instituto"; key="3946880386449"; secret="0c15f825cded97455749c7d6b7558f1e"; color="#3b82f6"},
    [ordered]@{id="telecom";   name="ICC Telecom";   key="4472437527558"; secret="eb030b4871537b1d984ff4078a469f75"; color="#10b981"},
    [ordered]@{id="medical";   name="ICC Medical";   key="7069173264153"; secret="9632f5b931f568b6b09accbf25f47496"; color="#f59e0b"}
)

function Call-Omie($url, $body) {
    $json = $body | ConvertTo-Json -Depth 10 -Compress
    try {
        return Invoke-RestMethod -Uri $url -Method POST -ContentType "application/json" -Body $json -TimeoutSec 30
    } catch {
        Write-Host "    Erro HTTP: $_" -ForegroundColor Red
        return $null
    }
}

function Get-Pages($key, $secret, $url, $call, $listKey) {
    $all = [System.Collections.Generic.List[object]]::new()
    $page = 1; $totalPages = 1
    do {
        $body = @{
            call       = $call
            app_key    = $key
            app_secret = $secret
            param      = @(@{
                pagina               = $page
                registros_por_pagina = 500
                filtrar_por_data_de  = $De
                filtrar_por_data_ate = $Ate
            })
        }
        $r = Call-Omie $url $body
        if ($null -eq $r -or $r.faultstring) {
            Write-Host "    API error: $($r.faultstring)" -ForegroundColor Red
            break
        }
        $items = $r.$listKey
        if ($items) { foreach ($i in $items) { $all.Add($i) } }
        $totalPages = [int]($r.total_de_paginas)
        Write-Host "    Pág $page/$totalPages ($($all.Count) registros)" -ForegroundColor DarkGray
        $page++
    } while ($page -le $totalPages)
    return ,$all
}

# ── Fetch ──
$payload = [ordered]@{}

foreach ($c in $companies) {
    Write-Host "  ► $($c.name)" -ForegroundColor Yellow

    Write-Host "    Contas a Receber..." -ForegroundColor Gray
    $rec = Get-Pages $c.key $c.secret `
        "https://app.omie.com.br/api/v1/financas/contareceber/" `
        "ListarContasReceber" "conta_receber_cadastro"

    Write-Host "    Contas a Pagar..." -ForegroundColor Gray
    $pag = Get-Pages $c.key $c.secret `
        "https://app.omie.com.br/api/v1/financas/contapagar/" `
        "ListarContasPagar" "conta_pagar_cadastro"

    Write-Host "    Saldo Banco..." -ForegroundColor Gray
    $saldoResp = Call-Omie "https://app.omie.com.br/api/v1/geral/contacorrente/" @{
        call="ListarContasCorrentes"; app_key=$c.key; app_secret=$c.secret
        param=@(@{pagina=1; registros_por_pagina=50})
    }
    $contas = if ($saldoResp.ListarContasCorrentes) {
        $saldoResp.ListarContasCorrentes | Where-Object { $_.inativo -ne "S" }
    } else { @() }
    $saldo = if ($contas) { ($contas | Measure-Object -Property saldo_inicial -Sum).Sum } else { 0 }

    Write-Host "    Receber=$($rec.Count)  Pagar=$($pag.Count)  Banco=R$$([math]::Round($saldo,2))" -ForegroundColor Green

    $payload[$c.id] = [ordered]@{
        name    = $c.name
        color   = $c.color
        saldo   = [double]$saldo
        receber = @($rec | ForEach-Object {[ordered]@{
            venc   = "$($_.data_vencimento)"
            valor  = [double]($_.valor_documento)
            saldo  = [double](if ($_.valor_saldo) {$_.valor_saldo} else {$_.valor_documento})
            status = "$($_.status_titulo)"
            nome   = if ($_.nome_fantasia) {"$($_.nome_fantasia)"} elseif ($_.nome_cliente) {"$($_.nome_cliente)"} else {"Cód.$($_.codigo_cliente_fornecedor)"}
            doc    = if ($_.numero_documento) {"$($_.numero_documento)"} else {"$($_.codigo_lancamento_omie)"}
        }})
        pagar = @($pag | ForEach-Object {[ordered]@{
            venc   = "$($_.data_vencimento)"
            valor  = [double]($_.valor_documento)
            saldo  = [double](if ($_.valor_saldo) {$_.valor_saldo} else {$_.valor_documento})
            status = "$($_.status_titulo)"
            nome   = if ($_.nome_fantasia) {"$($_.nome_fantasia)"} elseif ($_.nome_fornecedor) {"$($_.nome_fornecedor)"} else {"Cód.$($_.codigo_cliente_fornecedor)"}
            doc    = if ($_.numero_documento) {"$($_.numero_documento)"} else {"$($_.codigo_lancamento_omie)"}
        }})
    }
}

Write-Host ""
Write-Host "  Gerando HTML..." -ForegroundColor Cyan

$dataJson   = $payload | ConvertTo-Json -Depth 10 -Compress
$geradoEm   = (Get-Date).ToString("dd/MM/yyyy HH:mm:ss")
$scriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$outputFile = Join-Path $scriptDir "relatorio.html"

# ── HTML Template ──
$html = @"
<!DOCTYPE html>
<html lang="pt-BR">
<head>
<meta charset="UTF-8"/>
<meta name="viewport" content="width=device-width,initial-scale=1"/>
<title>Fluxo de Caixa ICC — $geradoEm</title>
<script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.0/dist/chart.umd.min.js"></script>
<script>const RAW=$dataJson;</script>
<style>
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:'Segoe UI',system-ui,sans-serif;background:#f0f4f8;color:#1a2942;min-height:100vh}
.hdr{background:linear-gradient(135deg,#0d2137,#1a3a5c);color:#fff;padding:14px 28px;display:flex;justify-content:space-between;align-items:center}
.hdr h1{font-size:18px;font-weight:700}.hdr p{font-size:11px;color:#90aecb;margin-top:2px}
.hdr-r{text-align:right;font-size:11px;color:#90aecb}.hdr-r strong{display:block;font-size:13px;font-weight:700;color:#fff;margin-top:2px}
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
.ante-card{background:linear-gradient(135deg,#1a1756,#2d3498,#1a3a5c);border-radius:10px;padding:20px 24px;margin-bottom:18px;color:#fff}
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
.drill-bar{background:#fff;border:1px solid #dde4ef;border-radius:10px;padding:12px 18px;margin-bottom:18px;display:flex;align-items:center;gap:12px;flex-wrap:wrap}
.drill-bar label{font-size:12px;font-weight:700;color:#1a2942}
.mnav{display:flex;gap:4px;flex-wrap:wrap}
.mbtn{background:#f0f4f8;border:1px solid #c8d6e5;border-radius:6px;padding:4px 9px;font-size:12px;cursor:pointer;color:#1a2942;transition:all .1s}
.mbtn:hover{background:#1a6fc4;color:#fff;border-color:#1a6fc4}
.mbtn.on{background:#1a6fc4;color:#fff;border-color:#1a6fc4;font-weight:700}
.week-card{background:#fff;border-radius:10px;padding:16px 18px;box-shadow:0 1px 4px rgba(0,0,0,.07);border:1px solid #dde4ef;margin-bottom:18px}
.week-title{font-size:13px;font-weight:700;color:#2d3748;margin-bottom:12px;display:flex;justify-content:space-between}
.wgrid{display:grid;grid-template-columns:repeat(auto-fit,minmax(155px,1fr));gap:12px}
.witem{border:1px solid #e2e8f0;border-radius:8px;padding:12px;position:relative;overflow:hidden}
.witem.best-r{border-color:#c6f6d5;background:#f0fff4}.witem.best-p{border-color:#fed7d7;background:#fff5f5}
.wnum{font-size:10px;font-weight:700;color:#718096;text-transform:uppercase;margin-bottom:4px}
.wdates{font-size:10px;color:#a0aec0;margin-bottom:7px}
.wrec{font-size:14px;font-weight:800;color:#276749}
.wpag{font-size:14px;font-weight:800;color:#c53030;margin-top:3px}
.wbal{font-size:12px;font-weight:700;margin-top:5px;padding-top:5px;border-top:1px solid #e2e8f0}
.wbar{height:4px;border-radius:2px;margin-top:3px;transition:width .3s}
.wbadge{position:absolute;top:6px;right:6px;font-size:9px;padding:2px 5px;border-radius:3px;font-weight:700}
.daily-card{background:#fff;border-radius:10px;overflow:hidden;box-shadow:0 1px 4px rgba(0,0,0,.07);border:1px solid #dde4ef;margin-bottom:18px}
.daily-head{padding:12px 16px;border-bottom:1px solid #edf2f7;display:flex;justify-content:space-between;align-items:center}
.daily-scroll{max-height:500px;overflow-y:auto}
.two-col{display:grid;grid-template-columns:1fr 1fr;gap:16px;margin-bottom:18px}
@media(max-width:900px){.two-col{grid-template-columns:1fr}}
.tcard{background:#fff;border-radius:10px;overflow:hidden;box-shadow:0 1px 4px rgba(0,0,0,.07);border:1px solid #dde4ef}
.thead2{padding:12px 16px;display:flex;justify-content:space-between;align-items:center;border-bottom:1px solid #edf2f7}
.tscroll{max-height:350px;overflow-y:auto;overflow-x:auto}
table{width:100%;border-collapse:collapse}
thead th{background:#f7fafc;padding:8px 12px;text-align:left;font-size:10px;font-weight:700;text-transform:uppercase;letter-spacing:.05em;color:#718096;position:sticky;top:0;border-bottom:1px solid #e2e8f0}
tbody tr{border-bottom:1px solid #f0f4f8}
tbody tr:hover{background:#f7fafc}
td{padding:8px 12px;font-size:12px;color:#2d3748}
.badge{display:inline-block;padding:2px 7px;border-radius:4px;font-size:10px;font-weight:700;text-transform:uppercase}
.b-aberto{background:#fff5f5;color:#c53030;border:1px solid #fed7d7}
.b-recebido,.b-pago{background:#f0fff4;color:#276749;border:1px solid #c6f6d5}
.b-vencido{background:#fffbeb;color:#92400e;border:1px solid #fde68a}
.b-cancelado{background:#f7fafc;color:#718096;border:1px solid #e2e8f0}
.cdot{display:inline-block;width:8px;height:8px;border-radius:50%;margin-right:5px;vertical-align:middle}
.pos{color:#276749;font-weight:700}.neg{color:#c53030;font-weight:700}.zer{color:#718096}
::-webkit-scrollbar{width:5px;height:5px}::-webkit-scrollbar-thumb{background:#c8d6e5;border-radius:4px}
</style>
</head>
<body>
<div class="hdr">
  <div><h1>📊 Fluxo de Caixa — ICC Grupo</h1><p>Gerado via Omie API · Período: $De a $Ate</p></div>
  <div class="hdr-r">Gerado em<strong>$geradoEm</strong></div>
</div>
<div class="tabs">
  <button class="tab-btn active" onclick="T('resumo')">📊 Consolidado</button>
  <button class="tab-btn" onclick="T('ante')">⚡ Antecipação</button>
  <button class="tab-btn" onclick="T('instituto')">🏛️ ICC Instituto</button>
  <button class="tab-btn" onclick="T('telecom')">📡 ICC Telecom</button>
  <button class="tab-btn" onclick="T('medical')">🏥 ICC Medical</button>
</div>
<div class="content">
  <div id="resumo" class="panel active"></div>
  <div id="ante"   class="panel"></div>
  <div id="instituto" class="panel"></div>
  <div id="telecom"   class="panel"></div>
  <div id="medical"   class="panel"></div>
</div>
<script>
'use strict';
const MO=['Janeiro','Fevereiro','Março','Abril','Maio','Junho','Julho','Agosto','Setembro','Outubro','Novembro','Dezembro'];
const MS=['Jan','Fev','Mar','Abr','Mai','Jun','Jul','Ago','Set','Out','Nov','Dez'];
const DW=['Dom','Seg','Ter','Qua','Qui','Sex','Sáb'];
let charts={}, selMes=new Date().getMonth();

const fc=v=>new Intl.NumberFormat('pt-BR',{minimumFractionDigits:2,maximumFractionDigits:2}).format(v||0);
const ots=s=>{if(!s||!s.includes('/'))return 0;const[d,m,y]=s.split('/');return new Date(+y,+m-1,+d).getTime();};
const omo=s=>{if(!s||!s.includes('/'))return-1;return+s.split('/')[1]-1;};

function T(id){
  document.querySelectorAll('.panel').forEach(p=>p.classList.remove('active'));
  document.querySelectorAll('.tab-btn').forEach(b=>b.classList.remove('active'));
  document.getElementById(id).classList.add('active');
  event.target.classList.add('active');
}

// monthly aggregation
function byMonth(rec,pag){
  const m=Array.from({length:12},(_,i)=>({month:i,receber:0,pagar:0}));
  rec.forEach(r=>{const mo=omo(r.venc);if(mo>=0)m[mo].receber+=r.saldo;});
  pag.forEach(p=>{const mo=omo(p.venc);if(mo>=0)m[mo].pagar+=p.saldo;});
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
      {type:'bar',label:'Entradas',data:monthly.map(m=>m.receber),backgroundColor:'rgba(39,103,73,.6)',borderColor:'#2f855a',borderWidth:1},
      {type:'bar',label:'Saídas',data:monthly.map(m=>-m.pagar),backgroundColor:'rgba(197,48,48,.5)',borderColor:'#c53030',borderWidth:1},
      {type:'line',label:'Saldo Acum.',data:running,borderColor:color,backgroundColor:'transparent',borderWidth:2.5,pointRadius:3,tension:.3,yAxisID:'y2'},
    ]},
    options:{responsive:true,maintainAspectRatio:false,
      interaction:{mode:'index',intersect:false},
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
  const nowTs=Date.now();
  const s=[...rows].sort((a,b)=>ots(a.venc)-ots(b.venc));
  if(ctId)document.getElementById(ctId).innerHTML=rows.length+' reg.';
  document.getElementById(bodyId).innerHTML=s.length?s.map(r=>{
    let sc=r.status.toLowerCase();
    if((sc==='aberto'||sc==='')&&ots(r.venc)<nowTs)sc='vencido';
    return`<tr><td style="white-space:nowrap">${r.venc||'—'}</td>
      <td style="max-width:180px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap" title="${r.nome}">${r.nome}</td>
      <td style="color:#718096;font-size:11px">${r.doc}</td>
      <td style="text-align:right;font-weight:600">R$ ${fc(r.saldo)}</td>
      <td><span class="badge b-${sc}">${sc.toUpperCase()||'—'}</span></td></tr>`;
  }).join(''):`<tr><td colspan="5" style="text-align:center;padding:22px;color:#718096">Sem registros no período</td></tr>`;
}

// Weekly card
function buildWeeks(mo){
  const yr=2026,dim=new Date(yr,mo+1,0).getDate();
  const weeks=[],mm=String(mo+1).padStart(2,'0');
  let ws=1,wn=1;
  while(ws<=dim){const we=Math.min(ws+6,dim);weeks.push({n:wn,s:ws,e:we,rec:0,pag:0});wn++;ws=we+1;}
  Object.values(RAW).forEach(d=>{
    [...d.receber,...d.pagar].forEach(t=>{
      if(omo(t.venc)!==mo)return;
      const day=+t.venc.split('/')[0];
      const w=weeks.find(w=>day>=w.s&&day<=w.e);
      if(!w)return;
      if(d.receber.includes(t))w.rec+=t.saldo; else w.pag+=t.saldo;
    });
  });
  return weeks;
}

function renderWeekly(mo){
  const weeks=buildWeeks(mo);
  const maxR=Math.max(...weeks.map(w=>w.rec),1);
  const maxP=Math.max(...weeks.map(w=>w.pag),1);
  const bri=weeks.reduce((bi,w,i)=>w.rec>weeks[bi].rec?i:bi,0);
  const bpi=weeks.reduce((bi,w,i)=>w.pag>weeks[bi].pag?i:bi,0);
  const yr=2026,mm2=String(mo+1).padStart(2,'0');
  return `<div class="week-card"><div class="week-title"><span>Semanas de ${MO[mo]} — Receita e Despesa</span><span style="font-size:11px;color:#718096">🟢 Maior receita &nbsp; 🔴 Maior despesa</span></div>
  <div class="wgrid">${weeks.map((w,i)=>{
    const saldo=w.rec-w.pag;
    const d1=new Date(yr,mo,w.s),d2=new Date(yr,mo,w.e);
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
    </div>`;
  }).join('')}</div></div>`;
}

// Daily table
function buildDayMap(mo){
  const yr=2026,dim=new Date(yr,mo+1,0).getDate(),map={};
  for(let d=1;d<=dim;d++){
    const dd=String(d).padStart(2,'0'),mm=String(mo+1).padStart(2,'0');
    map[`${dd}/${mm}/${yr}`]={rec:0,pag:0,rcnt:0,pcnt:0};
  }
  Object.values(RAW).forEach(d=>{
    d.receber.forEach(r=>{if(omo(r.venc)===mo&&map[r.venc]){map[r.venc].rec+=r.saldo;map[r.venc].rcnt++;}});
    d.pagar.forEach(p=>  {if(omo(p.venc)===mo&&map[p.venc]){map[p.venc].pag+=p.saldo;map[p.venc].pcnt++;}});
  });
  return Object.entries(map).map(([date,v])=>({date,...v})).sort((a,b)=>ots(a.date)-ots(b.date));
}

function renderDaily(mo,sb){
  const rows=buildDayMap(mo);
  const maxV=Math.max(...rows.map(r=>Math.max(r.rec,r.pag)),1);
  let run=sb||0;
  const yr=2026;
  const todayStr=(()=>{const n=new Date();return`${String(n.getDate()).padStart(2,'0')}/${String(n.getMonth()+1).padStart(2,'0')}/${n.getFullYear()}`;})();
  const trs=rows.map(r=>{
    const d=new Date(yr,mo,+r.date.split('/')[0]);
    const dow=d.getDay(),isWE=dow===0||dow===6,isToday=r.date===todayStr;
    const liq=r.rec-r.pag; run+=liq;
    const pR=Math.round(r.rec/maxV*90),pP=Math.round(r.pag/maxV*90);
    const hasDat=r.rec>0||r.pag>0;
    return`<tr style="${isToday?'background:#eff6ff':isWE?'background:#fafbfc':''}${!hasDat?';opacity:.4':''}">
      <td style="font-weight:700;white-space:nowrap;color:#1a3a5c">${r.date.slice(0,5)}</td>
      <td style="color:#718096">${DW[dow]}</td>
      <td style="text-align:right;color:#276749;font-weight:${r.rec>0?700:400}">${r.rec>0?'R$ '+fc(r.rec):'—'}</td>
      <td style="text-align:right;color:#c53030;font-weight:${r.pag>0?700:400}">${r.pag>0?'R$ '+fc(r.pag):'—'}</td>
      <td style="text-align:right" class="${liq>0?'pos':liq<0?'neg':'zer'}">${liq!==0?(liq>0?'+':'-')+'R$ '+fc(Math.abs(liq)):'—'}</td>
      <td style="text-align:right" class="${run>=0?'pos':'neg'}">R$ ${fc(run)}</td>
      <td><div style="display:flex;flex-direction:column;gap:2px">
        ${r.rec>0?`<div style="display:flex;align-items:center;gap:2px"><span style="font-size:9px;color:#276749;width:8px">▲</span><div style="height:5px;width:${pR}px;background:#2f855a;border-radius:2px"></div></div>`:''}
        ${r.pag>0?`<div style="display:flex;align-items:center;gap:2px"><span style="font-size:9px;color:#c53030;width:8px">▼</span><div style="height:5px;width:${pP}px;background:#c53030;border-radius:2px"></div></div>`:''}
      </td>
      <td style="font-size:11px;color:#718096">${r.rcnt>0?`<span style="color:#276749">+${r.rcnt}</span>`:''}${r.pcnt>0?` <span style="color:#c53030">-${r.pcnt}</span>`:''}</td>
    </tr>`;
  }).join('');
  return`<div class="daily-card">
    <div class="daily-head"><span style="font-size:13px;font-weight:700">Fluxo Diário — ${MO[mo]} 2026 (Consolidado)</span><span style="font-size:11px;color:#718096">Saldo parte de R$ ${fc(sb)}</span></div>
    <div class="daily-scroll"><table>
      <thead><tr><th>Data</th><th>Dia</th><th style="text-align:right">Entradas</th><th style="text-align:right">Saídas</th><th style="text-align:right">Líquido</th><th style="text-align:right">Saldo Acum.</th><th>Barras</th><th>Títulos</th></tr></thead>
      <tbody>${trs}</tbody>
    </table></div>
  </div>`;
}

// Month nav
function monthNav(mo){
  return`<div class="drill-bar"><label>📅 Mês:</label><div class="mnav">${MS.map((m,i)=>`<button class="mbtn${i===mo?' on':''}" onclick="changeMes(${i})">${m}</button>`).join('')}</div></div>`;
}

function changeMes(mo){
  selMes=mo;
  const sb=Object.values(RAW).reduce((s,d)=>s+d.saldo,0);
  document.getElementById('weekly-area').innerHTML=renderWeekly(mo);
  document.getElementById('daily-area').innerHTML=renderDaily(mo,sb);
  document.querySelectorAll('.mbtn').forEach((b,i)=>b.classList.toggle('on',i===mo));
}

// ── MAIN RENDER ──
function render(){
  const ids=Object.keys(RAW);
  let tR=0,tP=0,tB=0;
  const merged=Array.from({length:12},(_,i)=>({month:i,receber:0,pagar:0}));
  const compRows=[];

  ids.forEach(id=>{
    const d=RAW[id];
    const mo=byMonth(d.receber,d.pagar);
    const ante=calcAnte(mo,d.saldo);
    const totR=d.receber.reduce((s,r)=>s+r.saldo,0);
    const totP=d.pagar.reduce((s,p)=>s+p.saldo,0);
    const proj=d.saldo+totR-totP;
    tR+=totR;tP+=totP;tB+=d.saldo;
    mo.forEach((m,i)=>{merged[i].receber+=m.receber;merged[i].pagar+=m.pagar;});
    compRows.push({id,d,mo,ante,totR,totP,proj});

    // Company tab
    document.getElementById(id).innerHTML=`
      <div class="banner" style="border-left:5px solid ${d.color}"><h2>${d.name}</h2><p>Jan/2026 a Dez/2026 · Banco: R$ ${fc(d.saldo)}</p></div>
      <div class="kgrid">
        <div class="kcard grn"><div class="klbl">Saldo Banco</div><div class="kval grn">R$ ${fc(d.saldo)}</div><div class="ksub">Contas correntes</div></div>
        <div class="kcard"><div class="klbl">Total a Receber</div><div class="kval" style="color:#276749">R$ ${fc(totR)}</div><div class="ksub">${d.receber.length} títulos</div></div>
        <div class="kcard red"><div class="klbl">Total a Pagar</div><div class="kval red">R$ ${fc(totP)}</div><div class="ksub">${d.pagar.length} títulos</div></div>
        <div class="kcard ${proj>=0?'grn':'red'}"><div class="klbl">Saldo Projetado</div><div class="kval ${proj>=0?'grn':'red'}">R$ ${fc(proj)}</div><div class="ksub">Banco+Receber−Pagar</div></div>
        <div class="kcard pur"><div class="klbl">Antecipação Necessária</div><div class="kval pur">${ante.needed>0?'R$ '+fc(ante.needed):'Não necessária'}</div><div class="ksub">${ante.needed>0?'Déficit em '+MS[ante.minMon]+'/26':'Caixa positivo ✓'}</div></div>
      </div>
      <div class="chart-card"><div class="chart-title">📈 Fluxo Mensal</div><div class="chart-canvas"><canvas id="ch_${id}"></canvas></div></div>
      <div class="two-col">
        <div class="tcard"><div class="thead2"><span style="font-weight:700;color:#276749">▲ A Receber</span><span id="ct_rec_${id}" style="font-size:11px;color:#718096"></span></div><div class="tscroll"><table><thead><tr><th>Vencimento</th><th>Nome</th><th>Documento</th><th style="text-align:right">Valor</th><th>Status</th></tr></thead><tbody id="rec_${id}"></tbody></table></div></div>
        <div class="tcard"><div class="thead2"><span style="font-weight:700;color:#c53030">▼ A Pagar</span><span id="ct_pag_${id}" style="font-size:11px;color:#718096"></span></div><div class="tscroll"><table><thead><tr><th>Vencimento</th><th>Nome</th><th>Documento</th><th style="text-align:right">Valor</th><th>Status</th></tr></thead><tbody id="pag_${id}"></tbody></table></div></div>
      </div>`;
    requestAnimationFrame(()=>{
      mkChart('ch_'+id,mo,d.color,d.saldo);
      fillTbl('rec_'+id,'ct_rec_'+id,d.receber);
      fillTbl('pag_'+id,'ct_pag_'+id,d.pagar);
    });
  });

  const tProj=tB+tR-tP;
  const tAnte=compRows.reduce((s,c)=>s+c.ante.needed,0);
  const mergedAnte=calcAnte(merged,tB);

  // Ante card
  const anteHtml=compRows.map(c=>`<div class="ante-item">
    <div class="ante-lbl" style="color:${c.d.color}">${c.d.name}</div>
    ${c.ante.needed>0?`<div class="ante-val">R$ ${fc(c.ante.needed)}</div><div class="ante-date">Déficit em ${MS[c.ante.minMon]}/26</div>`:`<div class="ante-ok">Positivo ✓</div>`}
  </div>`).join('');

  // Resumo
  document.getElementById('resumo').innerHTML=`
    <div class="banner"><h2>Resumo Executivo Consolidado — ICC Grupo</h2><p>Fluxo Anual 2026 · Banco consolidado: R$ ${fc(tB)}</p></div>
    <div class="kgrid">
      <div class="kcard grn"><div class="klbl">Saldo Banco Consolidado</div><div class="kval grn">R$ ${fc(tB)}</div><div class="ksub">3 empresas</div></div>
      <div class="kcard"><div class="klbl">Total a Receber (2026)</div><div class="kval" style="color:#276749">R$ ${fc(tR)}</div><div class="ksub">Jan a Dez</div></div>
      <div class="kcard red"><div class="klbl">Total a Pagar (2026)</div><div class="kval red">R$ ${fc(tP)}</div><div class="ksub">Jan a Dez</div></div>
      <div class="kcard ${tProj>=0?'grn':'red'}"><div class="klbl">Saldo Projetado Final</div><div class="kval ${tProj>=0?'grn':'red'}">R$ ${fc(tProj)}</div><div class="ksub">Banco+Receber−Pagar</div></div>
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
    <div class="chart-card"><div class="chart-title">📈 Fluxo Mensal Consolidado 2026</div><div class="chart-canvas"><canvas id="ch_resumo"></canvas></div></div>
    <div class="tcard" style="margin-bottom:18px"><div class="thead2"><span style="font-weight:700">Resumo por Empresa</span></div>
      <div class="tscroll"><table><thead><tr><th>Empresa</th><th style="text-align:right">Banco</th><th style="text-align:right">A Receber</th><th style="text-align:right">A Pagar</th><th style="text-align:right">Projetado</th><th style="text-align:right">Antecipação</th><th>Pior Mês</th></tr></thead>
      <tbody>${compRows.map(c=>`<tr>
        <td><span class="cdot" style="background:${c.d.color}"></span>${c.d.name}</td>
        <td style="text-align:right;color:#276749;font-weight:700">R$ ${fc(c.d.saldo)}</td>
        <td style="text-align:right;color:#276749">R$ ${fc(c.totR)}</td>
        <td style="text-align:right;color:#c53030">R$ ${fc(c.totP)}</td>
        <td style="text-align:right;font-weight:700" class="${c.proj>=0?'pos':'neg'}">R$ ${fc(c.proj)}</td>
        <td style="text-align:right;color:${c.ante.needed>0?'#6b46c1':'#276749'};font-weight:700">${c.ante.needed>0?'R$ '+fc(c.ante.needed):'—'}</td>
        <td style="color:#718096">${c.ante.needed>0?MS[c.ante.minMon]+'/2026':'—'}</td>
      </tr>`).join('')}</tbody></table></div></div>`;

  // Ante tab
  document.getElementById('ante').innerHTML=`
    <div class="banner"><h2>⚡ Antecipação de Recebíveis</h2><p>Valor mínimo a antecipar por empresa</p></div>
    <div class="ante-card"><div class="ante-title">Antecipação necessária para manter caixa positivo</div>
      <div class="ante-grid">${anteHtml}
        <div class="ante-item" style="border-left:1px solid rgba(255,255,255,.2);padding-left:20px">
          <div class="ante-lbl" style="color:#c4b5fd">TOTAL GRUPO</div>
          ${tAnte>0?`<div class="ante-val" style="font-size:24px">R$ ${fc(tAnte)}</div><div class="ante-date">Soma dos déficits individuais</div>`:`<div class="ante-ok" style="font-size:20px">Grupo saudável ✓</div>`}
        </div>
      </div>
    </div>
    <div class="chart-card"><div class="chart-title">📉 Saldo Consolidado — Com vs Sem Antecipação</div><div class="chart-canvas"><canvas id="ch_ante"></canvas></div></div>
    <div class="kgrid">${compRows.map(c=>{
      const pct=c.totR>0?(c.ante.needed/c.totR*100).toFixed(1):0;
      return`<div class="kcard pur" style="border-top-color:${c.d.color}">
        <div class="klbl">${c.d.name}</div>
        <div class="kval" style="color:${c.d.color};font-size:18px">${c.ante.needed>0?'R$ '+fc(c.ante.needed):'Não necessária'}</div>
        <div class="ksub">${c.ante.needed>0?pct+'% do recebível · '+MS[c.ante.minMon]+'/26':'Banco cobre os pagamentos'}</div>
      </div>`;}).join('')}</div>`;

  requestAnimationFrame(()=>{
    mkChart('ch_resumo',merged,'#1a6fc4',tB);
    // ante chart
    const withAnte=(()=>{let r=tB+mergedAnte.needed;return merged.map(m=>{r+=m.receber-m.pagar;return r;});})();
    charts.ch_ante&&charts.ch_ante.destroy();
    charts.ch_ante=new Chart(document.getElementById('ch_ante').getContext('2d'),{
      data:{labels:MS,datasets:[
        {type:'line',label:'Sem antecipação',data:mergedAnte.running,borderColor:'#c53030',backgroundColor:'rgba(197,48,48,.07)',borderWidth:2.5,fill:true,tension:.3,pointRadius:3},
        {type:'line',label:'Com antecipação (R$'+fc(mergedAnte.needed)+')',data:withAnte,borderColor:'#276749',backgroundColor:'rgba(39,103,73,.07)',borderWidth:2.5,fill:true,tension:.3,pointRadius:3},
        {type:'line',label:'Zero',data:Array(12).fill(0),borderColor:'#a0aec0',borderDash:[4,3],borderWidth:1,pointRadius:0},
      ]},
      options:{responsive:true,maintainAspectRatio:false,
        plugins:{legend:{labels:{color:'#4a5568',font:{size:11}}},tooltip:{callbacks:{label:c=>` ${c.dataset.label}: R$ ${fc(c.parsed.y)}`}}},
        scales:{x:{ticks:{color:'#718096',font:{size:11}},grid:{color:'#f0f4f8'}},y:{ticks:{color:'#718096',font:{size:10},callback:v=>'R$'+fc(v)},grid:{color:'rgba(224,231,239,.6)'}}}
      }
    });
  });
}
render();
</script>
</body>
</html>
"@

[System.IO.File]::WriteAllText($outputFile, $html, [System.Text.Encoding]::UTF8)

Write-Host ""
Write-Host "  ✅ Relatório gerado: relatorio.html" -ForegroundColor Green
Write-Host ""
Write-Host "  Abrindo no navegador..." -ForegroundColor Cyan
Start-Process $outputFile
Write-Host ""
Write-Host "  Pressione Enter para fechar." -ForegroundColor Gray
Read-Host
