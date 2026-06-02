/**
 * Servidor proxy local — Fluxo de Caixa ICC
 * Roda: node server.js
 * Acesse: http://localhost:3000
 */
const http  = require('http');
const https = require('https');
const fs    = require('fs');
const path  = require('path');
const url   = require('url');

const PORT      = 3000;
const OMIE_HOST = 'app.omie.com.br';

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js':   'application/javascript',
  '.css':  'text/css',
  '.json': 'application/json',
  '.ico':  'image/x-icon',
};

const server = http.createServer((req, res) => {
  res.setHeader('Access-Control-Allow-Origin',  '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET,POST,OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type');

  if (req.method === 'OPTIONS') { res.writeHead(204); res.end(); return; }

  // ── /proxy/* → encaminha para app.omie.com.br ──
  if (req.url.startsWith('/proxy/')) {
    const apiPath = req.url.slice('/proxy'.length); // ex: /api/v1/financas/contareceber/
    let body = '';
    req.on('data', c => body += c);
    req.on('end', () => {
      const opts = {
        hostname: OMIE_HOST,
        path:     apiPath,
        method:   'POST',
        headers:  {
          'Content-Type':   'application/json',
          'Content-Length': Buffer.byteLength(body),
          'User-Agent':     'ICC-FluxoCaixa/1.0',
        },
      };
      const pReq = https.request(opts, pRes => {
        let data = '';
        pRes.on('data', c => data += c);
        pRes.on('end', () => {
          res.writeHead(pRes.statusCode, { 'Content-Type': 'application/json' });
          res.end(data);
        });
      });
      pReq.on('error', err => {
        res.writeHead(502, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ faultstring: 'Proxy error: ' + err.message }));
      });
      pReq.write(body);
      pReq.end();
    });
    return;
  }

  // ── arquivos estáticos ──
  const filePath = path.join(
    __dirname,
    req.url === '/' ? 'index.html' : url.parse(req.url).pathname
  );

  fs.readFile(filePath, (err, data) => {
    if (err) { res.writeHead(404); res.end('404 Not Found'); return; }
    const ext  = path.extname(filePath).toLowerCase();
    const mime = MIME[ext] || 'application/octet-stream';
    res.writeHead(200, { 'Content-Type': mime });
    res.end(data);
  });
});

server.listen(PORT, '127.0.0.1', () => {
  console.log('\n╔══════════════════════════════════════════╗');
  console.log('║  ICC — Fluxo de Caixa  |  Servidor ativo ║');
  console.log('╠══════════════════════════════════════════╣');
  console.log(`║  Abra no navegador:                      ║`);
  console.log(`║  http://localhost:${PORT}                   ║`);
  console.log('╚══════════════════════════════════════════╝\n');
  console.log('Pressione Ctrl+C para parar o servidor.\n');
});
