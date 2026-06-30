// CORS proxy para el emulador de Firestore en Codespaces.
// El emulador corre en localhost:8282 pero el browser no puede accederlo
// desde una página HTTPS por Mixed Content ni desde otro origen sin CORS.
// Este proxy escucha en el puerto indicado, agrega los headers CORS y
// reenvía todo al emulador.
//
// Uso: node cors-proxy.js [sourcePort] [targetPort]
// Default: node cors-proxy.js 8283 8282

const http = require('http');

const SOURCE_PORT = parseInt(process.argv[2] || '8283', 10);
const TARGET_PORT = parseInt(process.argv[3] || '8282', 10);

const server = http.createServer((req, res) => {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET, POST, PUT, DELETE, PATCH, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', '*');
  res.setHeader('Access-Control-Expose-Headers', '*');

  if (req.method === 'OPTIONS') {
    res.writeHead(204);
    res.end();
    return;
  }

  const options = {
    hostname: 'localhost',
    port: TARGET_PORT,
    path: req.url,
    method: req.method,
    headers: { ...req.headers, host: `localhost:${TARGET_PORT}` },
  };

  const proxy = http.request(options, (proxyRes) => {
    const headers = { ...proxyRes.headers };
    headers['access-control-allow-origin'] = '*';
    headers['access-control-allow-methods'] = 'GET, POST, PUT, DELETE, PATCH, OPTIONS';
    headers['access-control-allow-headers'] = '*';
    headers['access-control-expose-headers'] = '*';
    res.writeHead(proxyRes.statusCode, headers);
    proxyRes.pipe(res, { end: true });
  });

  proxy.on('error', (err) => {
    console.error('Proxy error:', err.message);
    res.writeHead(502);
    res.end('Bad Gateway');
  });

  req.pipe(proxy, { end: true });
});

server.on('upgrade', (req, socket, head) => {
  // WebSocket passthrough
  const net = require('net');
  const conn = net.connect(TARGET_PORT, 'localhost', () => {
    conn.write(`${req.method} ${req.url} HTTP/1.1\r\n`);
    Object.entries(req.headers).forEach(([k, v]) => conn.write(`${k}: ${v}\r\n`));
    conn.write('\r\n');
    conn.write(head);
    socket.pipe(conn);
    conn.pipe(socket);
  });
  conn.on('error', () => socket.destroy());
});

server.listen(SOURCE_PORT, () => {
  console.log(`[CORS Proxy] :${SOURCE_PORT} → localhost:${TARGET_PORT}`);
});
