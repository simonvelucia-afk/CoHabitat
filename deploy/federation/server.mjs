// server.mjs — enveloppe HTTP de la passerelle de federation.
//
// Ne contient que la plomberie : lecture du corps, bornes de taille,
// journal. Toute la logique est dans lib/app.mjs, testee sans socket.

import { createServer } from 'node:http';
import { loadConfig } from './lib/config.mjs';
import { createDb } from './lib/db.mjs';
import { createApp } from './lib/app.mjs';
import { createOutbox } from './lib/outbox.mjs';
import { publicKeyToSpki } from './lib/jwt.mjs';
import { createPublicKey } from 'node:crypto';

const MAX_BODY = 256 * 1024;

const config = loadConfig();
config.publicKeyB64 = publicKeyToSpki(createPublicKey(config.privateKey));

const db = createDb({ postgrestUrl: config.postgrestUrl, serviceKey: config.serviceKey });
const app = createApp({ config, db });
const outbox = createOutbox({ config, db, app });

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    req.on('data', (c) => {
      size += c.length;
      if (size > MAX_BODY) { reject(new Error('corps trop volumineux')); req.destroy(); return; }
      chunks.push(c);
    });
    req.on('end', () => {
      const raw = Buffer.concat(chunks).toString('utf8');
      if (!raw) return resolve(null);
      try { resolve(JSON.parse(raw)); } catch { reject(new Error('json invalide')); }
    });
    req.on('error', reject);
  });
}

const server = createServer(async (req, res) => {
  const started = Date.now();
  const url = new URL(req.url, 'http://localhost');
  let out;
  try {
    const body = req.method === 'GET' || req.method === 'HEAD' ? null : await readBody(req);
    out = await app.handle({ method: req.method, path: url.pathname, headers: req.headers, body });
  } catch (e) {
    out = { status: 400, body: { error: 'bad_request', detail: e.message } };
  }
  const payload = JSON.stringify(out.body);
  res.writeHead(out.status, { 'Content-Type': 'application/json; charset=utf-8' });
  res.end(payload);
  console.info(`${req.method} ${url.pathname} -> ${out.status} (${Date.now() - started} ms)`);
});

server.listen(config.port, () => {
  console.info(`[federation] instance=${config.instanceId} port=${config.port}`);
  console.info(`[federation] cle publique=${config.publicKeyB64}`);
  outbox.start();
});

for (const sig of ['SIGTERM', 'SIGINT']) {
  process.on(sig, () => { outbox.stop(); server.close(() => process.exit(0)); });
}
