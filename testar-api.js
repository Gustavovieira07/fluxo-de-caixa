/**
 * Teste direto da API Omie — rode no terminal:
 *   node testar-api.js
 *
 * Mostra o que a API retorna sem nenhum filtro,
 * o nome exato das chaves e um registro de exemplo.
 */
const https = require('https');

const COMPANIES = {
  instituto: { name:'Instituto', key:'3946880386449', secret:'0c15f825cded97455749c7d6b7558f1e' },
  telecom:   { name:'Telecom',   key:'4472437527558', secret:'eb030b4871537b1d984ff4078a469f75' },
  medical:   { name:'Medical',   key:'7069173264153', secret:'9632f5b931f568b6b09accbf25f47496' },
};

function post(path, body) {
  return new Promise((resolve, reject) => {
    const data = JSON.stringify(body);
    const req = https.request({
      hostname: 'app.omie.com.br',
      path,
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(data) },
    }, res => {
      let buf = '';
      res.on('data', c => buf += c);
      res.on('end', () => { try { resolve(JSON.parse(buf)); } catch(e){ reject(new Error('JSON inválido: '+buf.slice(0,200))); } });
    });
    req.on('error', reject);
    req.write(data); req.end();
  });
}

async function testCompany(id, c) {
  console.log('\n' + '═'.repeat(55));
  console.log(`  ${c.name.toUpperCase()}`);
  console.log('═'.repeat(55));

  // ── Contas a Receber (sem filtro) ──
  console.log('\n▶ Contas a Receber — sem filtro de data');
  try {
    const r = await post('/api/v1/financas/contareceber/', {
      call: 'ListarContasReceber', app_key: c.key, app_secret: c.secret,
      param: [{ pagina: 1, registros_por_pagina: 2 }]
    });
    if (r.faultstring) { console.log('  ERRO:', r.faultstring); }
    else {
      const total = r.total_de_registros ?? r.total_registros ?? '?';
      const listKey = Object.keys(r).find(k => Array.isArray(r[k]));
      console.log(`  Total registros : ${total}`);
      console.log(`  Chave da lista  : ${listKey}`);
      if (listKey && r[listKey].length > 0) {
        const item = r[listKey][0];
        const cab  = item.cabecalho || item;
        console.log(`  Vencimento      : ${cab.data_vencimento || item.data_vencimento || 'N/A'}`);
        console.log(`  Valor           : ${cab.valor_documento || item.valor_documento || 'N/A'}`);
        console.log(`  Status          : ${JSON.stringify(item.status_titulo || cab.status_titulo || 'N/A')}`);
        console.log(`  Nome cliente    : ${(item.clientes_documento||{}).nome_fantasia || cab.nome_cliente || item.nome_fantasia || 'N/A'}`);
        console.log('\n  >> Estrutura completa do 1º registro:');
        console.log(JSON.stringify(item, null, 2).split('\n').map(l=>'     '+l).join('\n'));
      }
    }
  } catch(e) { console.log('  EXCEÇÃO:', e.message); }

  // ── Contas a Receber (filtro 2026) ──
  console.log('\n▶ Contas a Receber — filtro: 01/01/2026 a 31/12/2026');
  try {
    const r = await post('/api/v1/financas/contareceber/', {
      call: 'ListarContasReceber', app_key: c.key, app_secret: c.secret,
      param: [{ pagina: 1, registros_por_pagina: 2,
                filtrar_por_data_de: '01/01/2026', filtrar_por_data_ate: '31/12/2026' }]
    });
    if (r.faultstring) console.log('  ERRO:', r.faultstring);
    else console.log(`  Total 2026: ${r.total_de_registros ?? r.total_registros ?? '?'} registros`);
  } catch(e) { console.log('  EXCEÇÃO:', e.message); }

  // ── Contas a Pagar (sem filtro) ──
  console.log('\n▶ Contas a Pagar — sem filtro de data');
  try {
    const r = await post('/api/v1/financas/contapagar/', {
      call: 'ListarContasPagar', app_key: c.key, app_secret: c.secret,
      param: [{ pagina: 1, registros_por_pagina: 2 }]
    });
    if (r.faultstring) { console.log('  ERRO:', r.faultstring); }
    else {
      const total = r.total_de_registros ?? r.total_registros ?? '?';
      const listKey = Object.keys(r).find(k => Array.isArray(r[k]));
      console.log(`  Total registros : ${total}`);
      console.log(`  Chave da lista  : ${listKey}`);
      if (listKey && r[listKey].length > 0) {
        const item = r[listKey][0];
        const cab  = item.cabecalho || item;
        console.log(`  Vencimento      : ${cab.data_vencimento || item.data_vencimento || 'N/A'}`);
        console.log(`  Valor           : ${cab.valor_documento || item.valor_documento || 'N/A'}`);
      }
    }
  } catch(e) { console.log('  EXCEÇÃO:', e.message); }

  // ── Saldo banco ──
  console.log('\n▶ Contas Correntes (saldo banco)');
  try {
    const r = await post('/api/v1/geral/contacorrente/', {
      call: 'ListarContasCorrentes', app_key: c.key, app_secret: c.secret,
      param: [{ pagina: 1, registros_por_pagina: 5, apenas_importado_api: 'N' }]
    });
    if (r.faultstring) { console.log('  ERRO:', r.faultstring); }
    else {
      const listKey = Object.keys(r).find(k => Array.isArray(r[k]));
      const contas  = listKey ? r[listKey] : [];
      console.log(`  Contas encontradas: ${contas.length}`);
      if (contas.length > 0) {
        console.log('\n  >> Estrutura da 1ª conta:');
        console.log(JSON.stringify(contas[0], null, 2).split('\n').map(l=>'     '+l).join('\n'));
      }
    }
  } catch(e) { console.log('  EXCEÇÃO:', e.message); }
}

(async () => {
  console.log('\n╔═══════════════════════════════════════════════════════╗');
  console.log('║  Diagnóstico API Omie — Fluxo de Caixa ICC           ║');
  console.log('╚═══════════════════════════════════════════════════════╝');
  for (const [id, c] of Object.entries(COMPANIES)) {
    await testCompany(id, c);
  }
  console.log('\n' + '═'.repeat(55));
  console.log('  Diagnóstico concluído.');
  console.log('═'.repeat(55) + '\n');
})();
