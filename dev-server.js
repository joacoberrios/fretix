// Servidor de desarrollo para Codespaces.
// Sirve la app Flutter (build/web) y proxea las peticiones de Firestore
// al emulador local (localhost:8282), todo en el mismo origen → sin CORS.
//
// Uso (desde la raíz del proyecto):
//   node dev-server.js
//
// Requisitos: Node.js >= 16 (ya disponible en Codespaces)
// Sin dependencias npm externas — solo módulos built-in.

const http = require('http');
const fs   = require('fs');
const path = require('path');

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

function proxyTo(targetPort, req, res) {
  const options = {
    hostname: 'localhost',
    port: targetPort,
    path: req.url,
    method: req.method,
    headers: { ...req.headers, host: `localhost:${targetPort}` },
  };
  const proxy = http.request(options, (pr) => {
    res.writeHead(pr.statusCode, pr.headers);
    pr.pipe(res, { end: true });
  });
  proxy.on('error', (e) => {
    console.error(`Proxy →${targetPort} error:`, e.message);
    res.writeHead(502);
    res.end('Bad Gateway');
  });
  req.pipe(proxy, { end: true });
}

const server = http.createServer((req, res) => {
  const url = req.url.split('?')[0];

  // ── Proxy: Firestore emulator
  if (url.startsWith('/google.firestore.v1.Firestore')) {
    return proxyTo(FIRESTORE_PORT, req, res);
  }

  // ── Proxy: Functions emulator (REST, no túnel)
  if (url.startsWith('/fretix-dev/') || url.startsWith('/fretix-dev-jb/')) {
    return proxyTo(FUNCTIONS_PORT, req, res);
  }

  // ── Static files (Flutter web)
  let filePath = path.join(STATIC_DIR, url === '/' ? 'index.html' : url);

  // Si el archivo no existe → devolver index.html (SPA routing)
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

// WebSocket passthrough para Firestore (WebChannel usa long-polling, pero por si acaso)
server.on('upgrade', (req, socket, head) => {
  const net  = require('net');
  const port = req.url.startsWith('/google.firestore') ? FIRESTORE_PORT : FUNCTIONS_PORT;
  const conn = net.connect(port, 'localhost', () => {
    conn.write(`${req.method} ${req.url} HTTP/1.1\r\n`);
    Object.entries(req.headers).forEach(([k, v]) => conn.write(`${k}: ${v}\r\n`));
    conn.write('\r\n');
    conn.write(head);
    socket.pipe(conn);
    conn.pipe(socket);
  });
  conn.on('error', () => socket.destroy());
});

server.listen(PORT, () => {
  console.log(`[dev-server] Serving on http://localhost:${PORT}`);
  console.log(`  Flutter app  → ${STATIC_DIR}`);
  console.log(`  Firestore    → localhost:${FIRESTORE_PORT} (proxied)`);
  console.log(`  Functions    → localhost:${FUNCTIONS_PORT} (proxied)`);
});
