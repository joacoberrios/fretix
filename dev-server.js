// Servidor de desarrollo para Codespaces.
// Sirve la app Flutter (build/web) y proxea las peticiones de Firestore
// al emulador local (localhost:8282), todo en el mismo origen → sin CORS.
//
// Uso (desde la raíz del proyecto):
//   node dev-server.js
//
// Requiere: npm install http-proxy (una sola vez)
// Sin otras dependencias npm externas.

const http    = require('http');
const fs      = require('fs');
const path    = require('path');
const httpProxy = require('http-proxy');

const PORT            = parseInt(process.env.PORT || '3000', 10);
const STATIC_DIR      = path.join(__dirname, 'build', 'web');
const FIRESTORE_PORT  = 8282;
const FUNCTIONS_PORT  = 5001;

// Extensiones → MIME types
const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js':   'application/javascript',
  '.css':  'text/css',
  '.json': 'application/json',
  '.wasm': 'application/wasm',
  '.png':  'image/png',
  '.ico':  'image/x-icon',
  '.svg':  'image/svg+xml',
  '.ttf':  'font/ttf',
  '.otf':  'font/otf',
  '.woff': 'font/woff',
  '.woff2':'font/woff2',
};

// Crear proxies dedicados por destino.
// changeOrigin:true → reescribe el header Host al target.
// ws:true → habilita el passthrough de WebSocket/upgrade por si acaso.
const firestoreProxy = httpProxy.createProxyServer({
  target:       `http://localhost:${FIRESTORE_PORT}`,
  changeOrigin: true,
  ws:           true,
  selfHandleResponse: false,
});

const functionsProxy = httpProxy.createProxyServer({
  target:       `http://localhost:${FUNCTIONS_PORT}`,
  changeOrigin: true,
  ws:           true,
  selfHandleResponse: false,
});

firestoreProxy.on('error', (e, req, res) => {
  console.error(`[proxy →${FIRESTORE_PORT}] ERROR ${req.url}:`, e.message);
  if (res && !res.headersSent) {
    res.writeHead(502);
    res.end('Bad Gateway');
  }
});

functionsProxy.on('error', (e, req, res) => {
  console.error(`[proxy →${FUNCTIONS_PORT}] ERROR ${req.url}:`, e.message);
  if (res && !res.headersSent) {
    res.writeHead(502);
    res.end('Bad Gateway');
  }
});

firestoreProxy.on('proxyReq', (proxyReq, req) => {
  console.log(`[proxy →${FIRESTORE_PORT}] ${req.method} ${req.url}`);
});
firestoreProxy.on('proxyRes', (proxyRes, req) => {
  console.log(`[proxy →${FIRESTORE_PORT}] response ${proxyRes.statusCode} for ${req.url}`);
});
functionsProxy.on('proxyReq', (proxyReq, req) => {
  console.log(`[proxy →${FUNCTIONS_PORT}] ${req.method} ${req.url}`);
});
functionsProxy.on('proxyRes', (proxyRes, req) => {
  console.log(`[proxy →${FUNCTIONS_PORT}] response ${proxyRes.statusCode} for ${req.url}`);
});

const server = http.createServer((req, res) => {
  const url = req.url.split('?')[0];

  // ── Proxy: Firestore emulator
  if (url.startsWith('/google.firestore.v1.Firestore')) {
    return firestoreProxy.web(req, res);
  }

  // ── Proxy: Functions emulator
  if (url.startsWith('/fretix-dev/') || url.startsWith('/fretix-dev-jb/')) {
    return functionsProxy.web(req, res);
  }

  // ── Static files (Flutter web)
  console.log(`[static] ${req.method} ${req.url}`);
  let filePath = path.join(STATIC_DIR, url === '/' ? 'index.html' : url);

  if (!fs.existsSync(filePath) || fs.statSync(filePath).isDirectory()) {
    filePath = path.join(STATIC_DIR, 'index.html');
  }

  const ext  = path.extname(filePath);
  const mime = MIME[ext] || 'application/octet-stream';

  fs.readFile(filePath, (err, data) => {
    if (err) {
      res.writeHead(404);
      res.end('Not Found');
      return;
    }
    res.writeHead(200, { 'Content-Type': mime });
    res.end(data);
  });
});

// WebSocket passthrough para los proxies
server.on('upgrade', (req, socket, head) => {
  const url = req.url || '';
  if (url.startsWith('/google.firestore.v1.Firestore')) {
    firestoreProxy.ws(req, socket, head);
  } else {
    functionsProxy.ws(req, socket, head);
  }
});

server.listen(PORT, () => {
  console.log(`[dev-server] Serving on http://localhost:${PORT}`);
  console.log(`  Flutter app  → ${STATIC_DIR}`);
  console.log(`  Firestore    → localhost:${FIRESTORE_PORT} (proxied via http-proxy)`);
  console.log(`  Functions    → localhost:${FUNCTIONS_PORT} (proxied via http-proxy)`);
});
