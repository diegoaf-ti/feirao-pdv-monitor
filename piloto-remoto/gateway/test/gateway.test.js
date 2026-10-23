'use strict';

const assert = require('node:assert/strict');
const { test, before, after } = require('node:test');
const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const net = require('node:net');
const tls = require('node:tls');
const https = require('node:https');
const http = require('node:http');
const { execFileSync } = require('node:child_process');
const { once } = require('node:events');
const { createGateway, fromFiles } = require('../server');
const { AuthorizedRelay } = require('../relay');
const { initialize } = require('../init-state');
const { initializeEnrollmentState } = require('../enrollment');

let directory; let certificates;
const agentId = '0249a001-0000-4000-8000-000000000001';
const agent2 = '0249a002-0000-4000-8000-000000000002';
const repeaterId = '490001';
const password = 'Te5t!234';
const pause = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const until = async (predicate) => { for (let n = 0; n < 100; n += 1) { if (predicate()) return; await pause(10); } assert.fail('Condition not reached'); };
const read = (file) => fs.readFileSync(path.join(directory, file));
const openssl = (...args) => execFileSync(process.env.OPENSSL || 'openssl', args, { cwd: directory, stdio: 'ignore' });

before(() => {
  directory = fs.mkdtempSync(path.join(os.tmpdir(), 'pdv-remote-synthetic-'));
  fs.chmodSync(directory, 0o700);
  for (const name of ['server-ca', 'device-ca', 'control-ca']) {
    openssl('req', '-x509', '-newkey', 'ec', '-pkeyopt', 'ec_paramgen_curve:P-256', '-nodes', '-keyout', `${name}.key`, '-out', `${name}.crt`, '-days', '3', '-subj', `/CN=${name}`, '-addext', 'basicConstraints=critical,CA:TRUE,pathlen:1');
  }
  openssl('req', '-newkey', 'rsa:2048', '-nodes', '-sha256', '-keyout', 'issuing-ca.key', '-out', 'issuing-ca.csr', '-subj', '/CN=synthetic-device-issuer');
  fs.writeFileSync(path.join(directory, 'issuing-ca.ext'), 'basicConstraints=critical,CA:TRUE,pathlen:0\nkeyUsage=critical,keyCertSign,cRLSign\n');
  openssl('x509', '-req', '-in', 'issuing-ca.csr', '-CA', 'device-ca.crt', '-CAkey', 'device-ca.key', '-set_serial', '0x123456', '-days', '2', '-sha256', '-extfile', 'issuing-ca.ext', '-out', 'issuing-ca.crt');
  for (const name of ['issuing-ca.key', 'issuing-ca.crt']) fs.chmodSync(path.join(directory, name), 0o600);
  openssl('req', '-newkey', 'rsa:2048', '-nodes', '-sha256', '-keyout', 'enrolling.key', '-out', 'enrolling.csr', '-subj', `/CN=pdv-${agentId}`);
  const leaf = (name, ca, purpose) => {
    openssl('req', '-newkey', 'ec', '-pkeyopt', 'ec_paramgen_curve:P-256', '-nodes', '-keyout', `${name}.key`, '-out', `${name}.csr`, '-subj', `/CN=${name}`);
    fs.writeFileSync(path.join(directory, `${name}.ext`), `basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=${purpose}\nsubjectAltName=DNS:localhost,IP:127.0.0.1\n`);
    openssl('x509', '-req', '-in', `${name}.csr`, '-CA', `${ca}.crt`, '-CAkey', `${ca}.key`, '-CAcreateserial', '-out', `${name}.crt`, '-days', '1', '-extfile', `${name}.ext`);
    return { key: read(`${name}.key`), cert: read(`${name}.crt`) };
  };
  certificates = { server: leaf('localhost', 'server-ca', 'serverAuth'), device: leaf('device1', 'device-ca', 'clientAuth'), device2: leaf('device2', 'device-ca', 'clientAuth'), control: leaf('conecta-api', 'control-ca', 'clientAuth'), control2: leaf('other-api', 'control-ca', 'clientAuth') };
});
after(() => fs.rmSync(directory, { recursive: true, force: true }));

const options = (overrides = {}) => {
  const folder = fs.mkdtempSync(path.join(directory, 'journal-'));
  return {
    hostname: 'localhost', viewerHost: '127.0.0.1', viewerIps: ['127.0.0.1'], journal: path.join(folder, 'leases.json'),
    bindings: [{ agentId, repeaterId, certificateSha256: new crypto.X509Certificate(certificates.device.cert).fingerprint256 }], passwords: { [agentId]: password },
    controlClientSha256: new crypto.X509Certificate(certificates.control.cert).fingerprint256,
    controlTls: { ...certificates.server, ca: read('control-ca.crt') }, deviceTls: { ...certificates.server, ca: read('device-ca.crt') }, ...overrides,
  };
};
const fixture = async (t, overrides) => {
  const config = options(overrides); const gateway = createGateway(config); const ports = await gateway.listen();
  t.after(() => gateway.stop());
  return { gateway, config, ports };
};
const body = (milliseconds = 10000) => ({ sessionId: crypto.randomUUID(), agentId, repeaterId, expiresAt: new Date(Date.now() + milliseconds).toISOString(), certificateSha256: new crypto.X509Certificate(certificates.device.cert).fingerprint256.replace(/:/g, '').toLowerCase() });
const request = (ports, method, route, value, identity = certificates.control) => new Promise((resolve, reject) => {
  const req = https.request({ hostname: 'localhost', host: '127.0.0.1', servername: 'localhost', port: ports.controlPort, path: route, method, ca: read('server-ca.crt'), ...identity, agent: false, headers: { 'Content-Type': 'application/json' }, timeout: 2000 }, (res) => {
    let data = ''; res.setEncoding('utf8'); res.on('data', (part) => { data += part; });
    res.on('end', () => resolve({ status: res.statusCode, data: JSON.parse(data), headers: res.headers }));
  });
  req.on('timeout', () => req.destroy(new Error('Timeout'))); req.on('error', reject); req.end(value === undefined ? undefined : JSON.stringify(value));
});
const connectDevice = async (ports, identity = certificates.device) => {
  const socket = tls.connect({ host: '127.0.0.1', servername: 'localhost', port: ports.devicePort, ca: read('server-ca.crt'), ...identity }); socket.on('error', () => {});
  await once(socket, 'secureConnect'); return socket;
};
const frame = (id = repeaterId) => { const value = Buffer.alloc(250); value.write(`ID:${id}`, 'ascii'); return value; };
const connectViewer = async (port) => { const socket = net.connect({ host: '127.0.0.1', port }); socket.on('error', () => {}); await once(socket, 'connect'); return socket; };

test('TLS real: frame Mode II fragmentado e bytes RFB passam nos dois sentidos após autorização', async (t) => {
  const { gateway, ports, config } = await fixture(t); const input = body();
  const created = await request(ports, 'POST', '/v1/leases', input);
  assert.equal(created.status, 200); assert.equal(created.data.state, 'pending'); assert.equal(created.data.password, undefined);
  const device = await connectDevice(ports); const received = []; device.on('data', (part) => received.push(part));
  device.write(frame().subarray(0, 13)); device.write(Buffer.concat([frame().subarray(13), Buffer.from('RFB 003.008\n')]));
  await until(() => gateway.relay.get(input.sessionId).state === 'ready');
  const viewer = await connectViewer(created.data.port); const fromDevice = [];
  viewer.on('data', (part) => fromDevice.push(part));
  await until(() => Buffer.concat(fromDevice).toString() === 'RFB 003.008\n');
  viewer.write('synthetic-viewer'); await until(() => Buffer.concat(received).toString() === 'synthetic-viewer');
  const active = await request(ports, 'GET', `/v1/leases/${input.sessionId}`);
  assert.equal(active.data.state, 'connected'); assert.equal(active.data.password, password); assert.ok(active.data.connectedAt);
  assert.equal(active.headers['cache-control'], 'no-store');
  const journal = fs.readFileSync(config.journal, 'utf8');
  for (const secret of [password, 'synthetic-viewer', 'RFB 003.008', certificates.device.key.toString()]) assert.ok(!journal.includes(secret));
  const deviceClosed = once(device, 'close'); const viewerClosed = once(viewer, 'close');
  const ended = await request(ports, 'DELETE', `/v1/leases/${input.sessionId}`);
  await Promise.all([deviceClosed, viewerClosed]); assert.equal(ended.data.state, 'closed'); assert.equal(ended.data.closeReason, 'revoked');
  assert.equal((await request(ports, 'GET', `/v1/leases/${input.sessionId}`)).data.password, undefined);
});

test('certificado do caixa não autoriza API de controle; controle não autoriza caixa', async (t) => {
  const { ports } = await fixture(t);
  await assert.rejects(request(ports, 'POST', '/v1/leases', body(), certificates.device));
  await assert.rejects(request(ports, 'POST', '/v1/leases', body(), {}));
  assert.equal((await request(ports, 'POST', '/v1/leases', body(), certificates.control2)).status, 403);
  const socket = await connectDevice(ports, certificates.control); const closed = once(socket, 'close'); socket.write(frame()); await closed;
});

test('CA comum de dispositivos não basta: fingerprint e ID vinculados são obrigatórios', async (t) => {
  const { gateway, ports } = await fixture(t); const input = body();
  await request(ports, 'POST', '/v1/leases', input);
  const wrongCertificate = await connectDevice(ports, certificates.device2); const wrongClosed = once(wrongCertificate, 'close'); wrongCertificate.write(frame()); await wrongClosed;
  const wrongId = await connectDevice(ports); const idClosed = once(wrongId, 'close'); wrongId.write(frame('490002')); await idClosed;
  assert.equal(gateway.relay.get(input.sessionId).state, 'pending');
});

test('rejeita dispositivo sem lease e frame com padding/byte alterado', async (t) => {
  const { gateway, ports } = await fixture(t);
  const unrequested = await connectDevice(ports); const earlyClosed = once(unrequested, 'close'); unrequested.write(frame()); await earlyClosed;
  const input = body(); await request(ports, 'POST', '/v1/leases', input);
  for (const value of [Buffer.alloc(250, 65), (() => { const f = frame(); f[30] = 1; return f; })(), (() => { const f = frame(); f[0] |= 0x80; return f; })(), Buffer.alloc(4097)]) {
    const socket = await connectDevice(ports); const closed = once(socket, 'close'); socket.write(value); await closed;
  }
  assert.equal(gateway.relay.get(input.sessionId).state, 'pending');
});

test('TTL próprio fecha ambos os transportes sem depender da API', async (t) => {
  const { gateway, ports } = await fixture(t); const input = body(650);
  const { data } = await request(ports, 'POST', '/v1/leases', input);
  const device = await connectDevice(ports); device.write(frame());
  await until(() => gateway.relay.get(input.sessionId).state === 'ready');
  const viewer = await connectViewer(data.port); const closed = [once(device, 'close'), once(viewer, 'close')];
  await Promise.all(closed); assert.equal(gateway.relay.get(input.sessionId).closeReason, 'expired');
  const replay = await request(ports, 'POST', '/v1/leases', input); assert.equal(replay.status, 200); assert.equal(replay.data.state, 'closed'); assert.equal(replay.data.port, null);
});

test('idempotência não renova nem reabre; payload divergente e ocupação são conflito', async (t) => {
  const { ports } = await fixture(t); const input = body();
  const first = await request(ports, 'POST', '/v1/leases', input);
  const repeated = await request(ports, 'POST', '/v1/leases', { certificateSha256: input.certificateSha256, expiresAt: input.expiresAt, repeaterId, agentId, sessionId: input.sessionId });
  assert.equal(repeated.data.port, first.data.port);
  assert.equal((await request(ports, 'POST', '/v1/leases', { ...input, expiresAt: new Date(Date.now() + 20000).toISOString() })).status, 409);
  assert.equal((await request(ports, 'POST', '/v1/leases', body())).status, 409);
  await request(ports, 'DELETE', `/v1/leases/${input.sessionId}`);
  assert.equal((await request(ports, 'POST', '/v1/leases', input)).data.state, 'closed');
  const unknown = body(); const ended = await request(ports, 'DELETE', `/v1/leases/${unknown.sessionId}`);
  assert.equal(ended.data.connectedAt, null); assert.equal(ended.data.closeReason, 'revoked_unknown');
  assert.equal((await request(ports, 'POST', '/v1/leases', unknown)).status, 409);
});

test('limites: duração, binding, tamanho, shape e content type', async (t) => {
  const { ports } = await fixture(t);
  for (const input of [body(901000), body(-1000), { ...body(), hostname: 'attacker' }, { ...body(), repeaterId: 490001 }]) assert.equal((await request(ports, 'POST', '/v1/leases', input)).status, 400);
  assert.equal((await request(ports, 'POST', '/v1/leases', { ...body(), agentId: agent2 })).status, 403);
  assert.equal((await request(ports, 'POST', '/v1/leases', { ...body(), certificateSha256: 'a'.repeat(64) })).status, 403);
  assert.equal((await request(ports, 'POST', '/v1/leases', { payload: 'x'.repeat(5000) })).status, 413);
  assert.equal((await request(ports, 'GET', '/v1/leases/00000000-0000-4000-8000-000000000000')).status, 404);
});

test('porta privada rejeita leitor antes do caixa e segundo visualizador', async (t) => {
  const { gateway, ports } = await fixture(t); const input = body(); const { data } = await request(ports, 'POST', '/v1/leases', input);
  const early = await connectViewer(data.port); await once(early, 'close');
  const device = await connectDevice(ports); device.write(frame()); await until(() => gateway.relay.get(input.sessionId).state === 'ready');
  const first = await connectViewer(data.port); await until(() => gateway.relay.get(input.sessionId).state === 'connected');
  const second = await connectViewer(data.port); await once(second, 'close');
  assert.equal(first.destroyed, false); await request(ports, 'DELETE', `/v1/leases/${input.sessionId}`);
});

test('allowlist de IP protege o listener interno', async (t) => {
  const { gateway, ports } = await fixture(t, { viewerIps: ['127.0.0.2'] }); const input = body(); const { data } = await request(ports, 'POST', '/v1/leases', input);
  const device = await connectDevice(ports); device.write(frame()); await until(() => gateway.relay.get(input.sessionId).state === 'ready');
  const denied = await connectViewer(data.port); await once(denied, 'close'); assert.equal(gateway.relay.get(input.sessionId).state, 'ready');
});

test('reinício fecha leases, preserva tombstone e não ressuscita sessão', async (t) => {
  const { gateway, config } = await fixture(t); const input = body(); await gateway.relay.create(input);
  // Simula journal deixado por interrupção brusca; não retoma listener de outra instância.
  const recovered = new AuthorizedRelay(config);
  assert.equal(recovered.get(input.sessionId).state, 'closed'); assert.equal(recovered.get(input.sessionId).closeReason, 'gateway_restart');
  assert.equal((await recovered.create(input)).state, 'closed'); assert.equal(recovered.live.size, 0); recovered.shutdown();
});

test('endpoint antigo nunca é reutilizado, inclusive após reinício e tombstone expirado', async () => {
  const config = options(); const first = new AuthorizedRelay(config); const request1 = body();
  const created = await first.create(request1); first.close(request1.sessionId); first.shutdown();
  // Restringir novo allocator à única porta antiga reproduz replay de contexto Guacamole.
  const second = new AuthorizedRelay({ ...config, portRange: [created.port, created.port] });
  await assert.rejects(second.create(body()), /NoViewerPort/); assert.equal(second.live.size, 0);
  second.shutdown();
  const journal = JSON.parse(fs.readFileSync(config.journal));
  for (const row of journal.leases) row.closedAt = new Date(Date.now() - 86400001).toISOString();
  fs.writeFileSync(config.journal, JSON.stringify(journal));
  const third = new AuthorizedRelay({ ...config, portRange: [created.port, created.port] });
  assert.equal(third.rows.size, 0); assert.ok(third.usedPorts.has(created.port));
  await assert.rejects(third.create(body()), /NoViewerPort/); third.shutdown();
});

test('somente um processo pode escrever o journal de produção', async (t) => {
  const { config } = await fixture(t);
  assert.throws(() => createGateway(config), /EEXIST/);
});

test('falha de persistência derruba conexão e impede novas leases', async (t) => {
  const { gateway, ports, config } = await fixture(t); const input = body(); await gateway.relay.create(input);
  const device = await connectDevice(ports); device.write(frame()); await until(() => gateway.relay.get(input.sessionId).state === 'ready');
  const closed = once(device, 'close'); const originalDirectory = path.dirname(config.journal); fs.renameSync(originalDirectory, `${originalDirectory}-moved`);
  assert.throws(() => gateway.relay.close(input.sessionId), /JournalUnavailable/); await closed;
  assert.equal(gateway.relay.healthy, false); await assert.rejects(gateway.relay.create(body()), /GatewayUnavailable/);
});

test('cancelamento durante bind assíncrono não deixa listener ou sessão aberta', async () => {
  const relay = new AuthorizedRelay(options()); const original = relay.listenViewer.bind(relay); let release; let port;
  relay.listenViewer = async (row) => { const server = await original(row); port = server.address().port; await new Promise((resolve) => { release = resolve; }); return server; };
  const input = body(); const creating = relay.create(input); await until(() => Boolean(release)); relay.close(input.sessionId); release();
  await assert.rejects(creating, /LeaseClosed/); assert.equal(relay.live.size, 0); assert.equal(relay.get(input.sessionId).state, 'closed');
  await assert.rejects(new Promise((resolve, reject) => { const socket = net.connect({ host: '127.0.0.1', port }); socket.on('connect', () => { socket.destroy(); resolve(); }); socket.on('error', reject); }));
  relay.shutdown();
});

test('journal inválido ou symlink e configuração insegura impedem startup', () => {
  const config = options(); fs.writeFileSync(config.journal, '{"schemaVersion":1,"leases":[{"bad":"secret"}]}'); assert.throws(() => new AuthorizedRelay(config));
  fs.unlinkSync(config.journal); fs.symlinkSync(path.join(directory, 'server-ca.crt'), config.journal); assert.throws(() => new AuthorizedRelay(config), /JournalInvalid/);
  assert.throws(() => new AuthorizedRelay(options({ viewerIps: ['0.0.0.0'] })), /InvalidConfiguration/);
  assert.throws(() => createGateway(options({ deviceTls: { ...certificates.server, ca: read('control-ca.crt') } })), /SeparateCertificateAuthoritiesRequired/);
  assert.throws(() => createGateway(options({ deviceTls: { ...certificates.server, ca: Buffer.from(`\n${read('control-ca.crt').toString()}\n`) } })), /SeparateCertificateAuthoritiesRequired/);
  assert.throws(() => createGateway(options({ deviceTls: { ...certificates.server, ca: Buffer.concat([read('device-ca.crt'), read('control-ca.crt')]) } })), /SingleSelfSignedAuthorityRequired/);
  assert.throws(() => createGateway(options({ controlClientSha256: '' })), /ControlClientPinRequired/);
  assert.throws(() => fromFiles({ enabled: false }), /PilotDisabled/);
  assert.throws(() => fromFiles({ enabled: true, portRange: [24000, 24099], files: { journal: path.join(directory, 'missing.json') } }), /JournalMustBeInitializedOffline/);
});

test('bootstrap offline é explícito, privado e nunca sobrescreve estado existente', () => {
  const folder = fs.mkdtempSync(path.join(directory, 'bootstrap-')); const target = path.join(folder, 'leases.json');
  assert.throws(() => initialize(target), /OfflineMaintenanceConfirmationRequired/);
  initialize(target, '--guacamole-and-guacd-stopped-json-key-rotated');
  assert.deepEqual(JSON.parse(fs.readFileSync(target)), { schemaVersion: 2, leases: [], usedPorts: [] });
  assert.throws(() => initialize(target, '--guacamole-and-guacd-stopped-json-key-rotated'), /EEXIST/);
});

test('stop fecha TLS incompleto e mantém desligamento limitado', async () => {
  const gateway = createGateway(options()); const ports = await gateway.listen(); const socket = net.connect({ host: '127.0.0.1', port: ports.devicePort }); socket.on('error', () => {}); await once(socket, 'connect');
  await Promise.race([gateway.stop(), pause(1500).then(() => { throw new Error('Shutdown timeout'); })]); assert.equal(gateway.relay.stopped, true); socket.destroy();
});

test('cliente real de controle da API fala com gateway mTLS sem iniciar app/banco', { skip: !process.env.PDV_REMOTE_BACKEND_SOURCE }, async (t) => {
  const { createRemoteGateway } = require(path.join(process.env.PDV_REMOTE_BACKEND_SOURCE, 'src/services/pdvMonitorRemoteGateway.js'));
  const { ports } = await fixture(t);
  const client = createRemoteGateway({ config: { configured: true, gatewayUrl: new URL(`https://127.0.0.1:${ports.controlPort}`), files: { ca: path.join(directory, 'server-ca.crt'), cert: path.join(directory, 'conecta-api.crt'), key: path.join(directory, 'conecta-api.key') } } });
  const input = body(); const result = await client.create(input);
  assert.equal(result.leaseId, input.sessionId); assert.equal(result.state, 'pending'); assert.equal(result.password, undefined);
  assert.equal((await client.get(input.sessionId)).password, password);
  assert.equal((await client.close(input.sessionId)).state, 'closed');
  assert.equal((await client.get(input.sessionId)).password, undefined);
});

const webFixture = async (t, overrides = {}) => {
  const jsonKey = crypto.randomBytes(16); const authToken = crypto.randomBytes(32).toString('hex');
  const tunnelToken = Buffer.alloc(33, 255).toString('base64'); const tunnelId = crypto.randomUUID(); const assets = Buffer.from('/* fixture only, not a real Guacamole client */');
  const observed = { documents: [], writes: [], revoked: 0, clients: [], tokenRequests: 0 }; let tunnel;
  const upstream = http.createServer(async (req, res) => {
    const parts = []; for await (const chunk of req) parts.push(chunk); const raw = Buffer.concat(parts);
    if (req.url === '/guacamole/guacamole-common-js/all.min.js') { res.end(assets); return; }
    if (req.url === '/guacamole/api/tokens' && req.method === 'POST') {
      observed.tokenRequests += 1;
      const data = Buffer.from(new URLSearchParams(raw.toString()).get('data'), 'base64');
      const decipher = crypto.createDecipheriv('aes-128-cbc', jsonKey, Buffer.alloc(16)); const decoded = Buffer.concat([decipher.update(data), decipher.final()]);
      assert.deepEqual(decoded.subarray(0, 32), crypto.createHmac('sha256', jsonKey).update(decoded.subarray(32)).digest());
      const doc = JSON.parse(decoded.subarray(32)); observed.documents.push(doc);
      res.setHeader('Content-Type', 'application/json'); res.end(JSON.stringify({ authToken, dataSource: 'json', availableDataSources: ['json'] })); return;
    }
    if (req.url === `/guacamole/api/tokens/${authToken}` && req.method === 'DELETE') { observed.revoked += 1; res.writeHead(204); res.end(); return; }
    if (req.url === '/guacamole/tunnel?connect' && req.method === 'POST') {
      const values = new URLSearchParams(raw.toString()); assert.equal(values.get('token'), authToken); assert.equal(values.get('GUAC_TYPE'), 'c'); assert.equal(values.get('GUAC_DATA_SOURCE'), 'json');
      const document = observed.documents.at(-1); const parameters = document.connections[values.get('GUAC_ID')].parameters;
      tunnel = await connectViewer(Number(parameters.port)); observed.clients.push(tunnel);
      res.setHeader('Guacamole-Tunnel-Token', tunnelToken); res.end(tunnelId); return;
    }
    if (req.url === `/guacamole/tunnel?read:${tunnelId}:0`) { assert.equal(req.headers['guacamole-tunnel-token'], tunnelToken); res.end('3.nop;0.;'); return; }
    if (req.url === `/guacamole/tunnel?write:${tunnelId}`) { assert.equal(req.headers['guacamole-tunnel-token'], tunnelToken); observed.writes.push(raw.toString()); res.end(); return; }
    res.writeHead(404); res.end();
  });
  await new Promise((resolve) => upstream.listen({ host: '127.0.0.1', port: 0 }, resolve));
  const config = { enabled: true, publicOrigin: 'https://viewer.example', conectaOrigin: 'https://conecta.example', guacamoleUrl: `http://127.0.0.1:${upstream.address().port}/guacamole/`, allowPrivateHttp: true, commonJsSha256: crypto.createHash('sha256').update(assets).digest('hex'), jsonKey: jsonKey.toString('hex'), tls: certificates.server, ...overrides };
  const result = await fixture(t, { web: config, ...(overrides.gatewayNow ? { now: overrides.gatewayNow } : {}) });
  t.after(async () => { for (const socket of observed.clients) socket.destroy(); upstream.closeAllConnections(); await new Promise((resolve) => upstream.close(resolve)); });
  return { ...result, observed, authToken, tunnelToken, tunnelId, config };
};
const publicRequest = (ports, method, route, value, headers = {}) => new Promise((resolve, reject) => {
  const req = https.request({ host: '127.0.0.1', servername: 'localhost', port: ports.browserPort, path: route, method, agent: false, ca: read('server-ca.crt'), headers: { Host: 'viewer.example', ...headers }, timeout: 3000 }, (res) => {
    const parts = []; res.on('data', (chunk) => parts.push(chunk)); res.once('end', () => resolve({ status: res.statusCode, headers: res.headers, data: Buffer.concat(parts).toString() }));
  }); req.on('timeout', () => req.destroy(new Error('timeout'))); req.on('error', reject); req.end(value);
});
const readyWebLease = async (t, overrides) => {
  const result = await webFixture(t, overrides); const input = body(); await request(result.ports, 'POST', '/v1/leases', input);
  const device = await connectDevice(result.ports); device.write(Buffer.concat([frame(), Buffer.from('RFB 003.008\n')]));
  await until(() => result.gateway.relay.get(input.sessionId).state === 'ready');
  return { ...result, input, device };
};

test('viewer integrado: ticket POST único, cookie HttpOnly e Guac HTTP com segredos só no servidor', async (t) => {
  const { gateway, ports, input, observed, authToken, tunnelToken, tunnelId, config } = await readyWebLease(t);
  const issued = await request(ports, 'POST', `/v1/leases/${input.sessionId}/viewer`, { sessionId: input.sessionId });
  assert.equal(issued.status, 200); assert.equal(issued.data.state, 'viewer_ready'); assert.ok(/^[A-Za-z0-9_-]{43}$/.test(issued.data.ticket));
  assert.equal(new URL(issued.data.viewerUrl).search, '');
  const post = new URLSearchParams({ sessionId: input.sessionId, ticket: issued.data.ticket }).toString();
  const opened = await publicRequest(ports, 'POST', '/pdv-remote/open', post, { Origin: config.conectaOrigin, 'Content-Type': 'application/x-www-form-urlencoded' });
  assert.equal(opened.status, 200); assert.equal(opened.headers.location, `/pdv-remote/s/${input.sessionId}/`); assert.match(opened.data, /assets\/open.js/);
  const fullCookie = opened.headers['set-cookie'][0]; assert.match(fullCookie, /HttpOnly/); assert.match(fullCookie, /Secure/); assert.match(fullCookie, /SameSite=Strict/);
  const cookie = fullCookie.split(';')[0]; const route = opened.headers.location;
  const page = await publicRequest(ports, 'GET', route, undefined, { Cookie: cookie });
  assert.equal(page.status, 200); for (const secret of [issued.data.ticket, authToken, password, config.jsonKey]) assert.ok(!page.data.includes(secret));
  const state = await publicRequest(ports, 'GET', `${route}state`, undefined, { Cookie: cookie }); const csrf = JSON.parse(state.data).csrf;
  const common = await publicRequest(ports, 'GET', '/pdv-remote/assets/guacamole-common-js.js'); assert.equal(common.status, 200);
  const connect = await publicRequest(ports, 'POST', `${route}tunnel?connect`, 'width=1280&height=800', { Cookie: cookie, Origin: config.publicOrigin, 'X-PDV-Remote-CSRF': csrf });
  assert.equal(connect.status, 200); assert.equal(connect.data, tunnelId); assert.equal(observed.clients.length, 1);
  const browserToken = connect.headers['guacamole-tunnel-token']; assert.ok(browserToken); assert.notEqual(browserToken, tunnelToken); assert.notEqual(browserToken, authToken);
  const clientHeaders = { Cookie: cookie, 'X-PDV-Remote-CSRF': csrf, 'Guacamole-Tunnel-Token': browserToken };
  const reading = await publicRequest(ports, 'GET', `${route}tunnel?read:${connect.data}:0`, undefined, clientHeaders); assert.equal(reading.data, '3.nop;0.;');
  const writing = await publicRequest(ports, 'POST', `${route}tunnel?write:${connect.data}`, '3.nop;', { ...clientHeaders, Origin: config.publicOrigin }); assert.equal(writing.status, 200); assert.deepEqual(observed.writes, ['3.nop;']);
  assert.equal(observed.documents[0].singleUse, true); assert.equal(observed.documents[0].connections[input.sessionId].singleUse, true);
  assert.equal(observed.documents[0].connections[input.sessionId].parameters['disable-copy'], 'true');
  assert.equal((await publicRequest(ports, 'POST', '/pdv-remote/open', post, { Origin: config.conectaOrigin, 'Content-Type': 'application/x-www-form-urlencoded' })).status, 403);
  const ended = await publicRequest(ports, 'POST', `${route}end`, '', { Cookie: cookie, Origin: config.publicOrigin, 'X-PDV-Remote-CSRF': csrf }); assert.equal(ended.status, 200);
  assert.match(ended.headers['set-cookie'][0], /Max-Age=0/);
  assert.equal((await publicRequest(ports, 'POST', `${route}end`, '', { Cookie: cookie, Origin: config.publicOrigin, 'X-PDV-Remote-CSRF': csrf })).status, 200);
  assert.equal(gateway.relay.get(input.sessionId).state, 'closed'); await until(() => observed.revoked === 1);
  assert.equal((await publicRequest(ports, 'GET', `${route}state`, undefined, { Cookie: cookie })).status, 401);
});

test('viewer recusa origem, ticket, cookie cruzado, CSRF e destino enviados pelo browser', async (t) => {
  const { ports, input, config } = await readyWebLease(t);
  const issued = (await request(ports, 'POST', `/v1/leases/${input.sessionId}/viewer`, { sessionId: input.sessionId })).data;
  const data = new URLSearchParams({ sessionId: input.sessionId, ticket: issued.ticket }).toString();
  assert.equal((await publicRequest(ports, 'POST', '/pdv-remote/open', data, { Origin: 'https://evil.example', 'Content-Type': 'application/x-www-form-urlencoded' })).status, 403);
  assert.equal((await publicRequest(ports, 'GET', `/pdv-remote/open?ticket=${issued.ticket}`)).status, 403);
  const opened = await publicRequest(ports, 'POST', '/pdv-remote/open', data, { Origin: config.conectaOrigin, 'Content-Type': 'application/x-www-form-urlencoded' }); const cookie = opened.headers['set-cookie'][0].split(';')[0]; const route = opened.headers.location;
  assert.equal((await publicRequest(ports, 'GET', `/pdv-remote/s/${crypto.randomUUID()}/state`, undefined, { Cookie: cookie })).status, 401);
  assert.equal((await publicRequest(ports, 'POST', `${route}tunnel?connect`, '', { Cookie: cookie, Origin: config.publicOrigin })).status, 403);
  const csrf = JSON.parse((await publicRequest(ports, 'GET', `${route}state`, undefined, { Cookie: cookie })).data).csrf;
  const malicious = await publicRequest(ports, 'POST', `${route}tunnel?connect`, 'hostname=other&token=other', { Cookie: cookie, Origin: config.publicOrigin, 'X-PDV-Remote-CSRF': csrf }); assert.equal(malicious.status, 400);
});

test('viewer não libera janela sem dispositivo ready e verifica hash da biblioteca', async (t) => {
  const { ports } = await webFixture(t, { commonJsSha256: 'a'.repeat(64) }); const input = body(); await request(ports, 'POST', '/v1/leases', input);
  assert.equal((await request(ports, 'POST', `/v1/leases/${input.sessionId}/viewer`, { sessionId: input.sessionId })).status, 409);
  assert.equal((await publicRequest(ports, 'GET', '/pdv-remote/assets/guacamole-common-js.js')).status, 503);
});

test('ticket expira sem autenticar Guacamole e revogação o invalida imediatamente', async (t) => {
  let offset = 0;
  const { gateway, ports, observed, config } = await webFixture(t, { gatewayNow: () => Date.now() + offset });
  const input = body(60000); await request(ports, 'POST', '/v1/leases', input);
  const device = await connectDevice(ports); device.write(frame()); await until(() => gateway.relay.get(input.sessionId).state === 'ready');
  const issued = (await request(ports, 'POST', `/v1/leases/${input.sessionId}/viewer`, { sessionId: input.sessionId })).data;
  offset = 31000;
  const post = new URLSearchParams({ sessionId: input.sessionId, ticket: issued.ticket }).toString();
  assert.equal((await publicRequest(ports, 'POST', '/pdv-remote/open', post, { Origin: config.conectaOrigin, 'Content-Type': 'application/x-www-form-urlencoded' })).status, 403);
  assert.equal(observed.tokenRequests, 0); assert.equal(gateway.relay.get(input.sessionId).state, 'ready');
  const second = (await request(ports, 'POST', `/v1/leases/${input.sessionId}/viewer`, { sessionId: input.sessionId })).data;
  await request(ports, 'DELETE', `/v1/leases/${input.sessionId}`);
  assert.equal((await publicRequest(ports, 'POST', '/pdv-remote/open', new URLSearchParams({ sessionId: input.sessionId, ticket: second.ticket }).toString(), { Origin: config.conectaOrigin, 'Content-Type': 'application/x-www-form-urlencoded' })).status, 403);
  assert.equal(observed.tokenRequests, 0);
});

test('configuração web inválida não deixa lock órfão antes de ouvir portas', async () => {
  const config = options({ web: { enabled: true, tls: certificates.server, publicOrigin: 'http://invalid' } });
  assert.throws(() => createGateway(config)); assert.equal(fs.existsSync(`${config.journal}.lock`), false);
  const retry = createGateway({ ...config, web: { enabled: false } }); await retry.stop();
});

test('uploads concorrentes reservam limite antes de ler; encerrar interrompe corpo e não escreve no Guac', async (t) => {
  const { gateway, ports, input, config, observed } = await readyWebLease(t);
  const ticket = (await request(ports, 'POST', `/v1/leases/${input.sessionId}/viewer`, { sessionId: input.sessionId })).data;
  const opened = await publicRequest(ports, 'POST', '/pdv-remote/open', new URLSearchParams({ sessionId: input.sessionId, ticket: ticket.ticket }).toString(), { Origin: config.conectaOrigin, 'Content-Type': 'application/x-www-form-urlencoded' });
  const cookie = opened.headers['set-cookie'][0].split(';')[0]; const route = opened.headers.location;
  const csrf = JSON.parse((await publicRequest(ports, 'GET', `${route}state`, undefined, { Cookie: cookie })).data).csrf;
  const connected = await publicRequest(ports, 'POST', `${route}tunnel?connect`, '', { Cookie: cookie, Origin: config.publicOrigin, 'X-PDV-Remote-CSRF': csrf });
  const headers = { Host: 'viewer.example', Cookie: cookie, Origin: config.publicOrigin, 'X-PDV-Remote-CSRF': csrf, 'Guacamole-Tunnel-Token': connected.headers['guacamole-tunnel-token'], 'Content-Length': '6' };
  const unfinished = []; let uploads = 0;
  gateway.browser.on('request', (req) => { if (req.url === `${route}tunnel?write:${connected.data}`) uploads += 1; });
  const partial = () => new Promise((resolve) => {
    const req = https.request({ host: '127.0.0.1', servername: 'localhost', port: ports.browserPort, path: `${route}tunnel?write:${connected.data}`, method: 'POST', ca: read('server-ca.crt'), headers, agent: false }, (res) => { res.resume(); res.once('end', () => resolve(res.statusCode)); });
    req.once('error', () => resolve('closed')); req.write('3.no'); unfinished.push(req);
  });
  const waiting = [partial(), partial(), partial(), partial()]; await until(() => uploads === 4);
  const fifth = partial(); assert.equal(await fifth, 429);
  const end = await publicRequest(ports, 'POST', `${route}end`, '', { Cookie: cookie, Origin: config.publicOrigin, 'X-PDV-Remote-CSRF': csrf }); assert.equal(end.status, 200);
  assert.deepEqual(await Promise.all(waiting), ['closed', 'closed', 'closed', 'closed']);
  assert.equal(observed.writes.length, 0); for (const req of unfinished) req.destroy();
});


test('provisionamento é desabilitado por padrão e exige o mesmo certificado de controle pinado', async (t) => {
  const { ports } = await fixture(t);
  const input = { requestId: crypto.randomUUID(), agentId, repeaterId, csrPem: read('enrolling.csr').toString(), previousCertificateSha256: null };
  assert.equal((await request(ports, 'POST', '/v1/devices/enrollments', input)).status, 503);
  assert.equal((await request(ports, 'POST', '/v1/devices/enrollments', input, certificates.control2)).status, 403);
  await assert.rejects(request(ports, 'POST', '/v1/devices/enrollments', input, certificates.device));
});

test('TLS real: cadastro por CSR gera vínculo individual; revogação encerra sessão e bloqueia fingerprint', async (t) => {
  const folder = fs.mkdtempSync(path.join(directory, 'enrollment-')); fs.chmodSync(folder, 0o700);
  const journal = path.join(folder, 'devices.json'); initializeEnrollmentState(journal, '--gateway-stopped');
  const opensslPath = process.env.OPENSSL || (process.platform === 'darwin' ? execFileSync('/usr/bin/which', ['openssl'], { encoding: 'utf8' }).trim() : '/usr/bin/openssl');
  const { gateway, ports } = await fixture(t, { bindings: [], passwords: {}, enrollment: { enabled: true, journal, issuer: { enabled: true, openssl: opensslPath, caCertificateFile: path.join(directory, 'issuing-ca.crt'), caPrivateKeyFile: path.join(directory, 'issuing-ca.key'), validityDays: 1 } } });
  const input = { requestId: crypto.randomUUID(), agentId, repeaterId, csrPem: read('enrolling.csr').toString(), previousCertificateSha256: null };
  const created = await request(ports, 'POST', '/v1/devices/enrollments', input);
  assert.equal(created.status, 200); assert.equal(created.data.password, undefined); assert.equal(created.data.certificatePem.match(/BEGIN CERTIFICATE/g).length, 2);
  assert.deepEqual((await request(ports, 'POST', '/v1/devices/enrollments', input)).data, created.data);
  const lease = { ...body(), certificateSha256: created.data.certificateSha256 };
  assert.equal((await request(ports, 'POST', '/v1/leases', lease)).status, 200);
  assert.equal((await request(ports, 'POST', '/v1/devices/enrollments', { ...input, requestId: crypto.randomUUID(), previousCertificateSha256: created.data.certificateSha256 })).status, 409);
  const device = await connectDevice(ports, { key: read('enrolling.key'), cert: created.data.certificatePem }); device.write(frame());
  await until(() => gateway.relay.get(lease.sessionId).state === 'ready');
  const closed = once(device, 'close');
  const revoked = await request(ports, 'DELETE', `/v1/devices/${agentId}`); await closed;
  assert.equal(revoked.status, 200); assert.deepEqual(revoked.data, { agentId, revoked: true });
  assert.equal(gateway.relay.get(lease.sessionId).closeReason, 'revoked');
  assert.equal(gateway.relay.bindings.has(agentId), false); assert.equal(gateway.relay.certificates.has(created.data.certificateSha256), false);
  assert.deepEqual((await request(ports, 'DELETE', `/v1/devices/${agentId}`)).data, revoked.data);
  assert.equal((await request(ports, 'POST', '/v1/devices/enrollments', input)).status, 403);
  assert.equal((await request(ports, 'POST', '/v1/leases', { ...lease, sessionId: crypto.randomUUID() })).status, 403);
});

test('adapter real da API: enrollment mTLS, validação de cadeia, replay e erros definitivos sem app/banco', { skip: !process.env.PDV_REMOTE_BACKEND_SOURCE }, async (t) => {
  const backend = process.env.PDV_REMOTE_BACKEND_SOURCE;
  const { createRemoteGateway } = require(path.join(backend, 'src/services/pdvMonitorRemoteGateway.js'));
  const { validateIssuedCertificate } = require(path.join(backend, 'src/utils/pdvMonitorRemoteEnrollment.js'));
  const folder = fs.mkdtempSync(path.join(directory, 'adapter-enrollment-')); fs.chmodSync(folder, 0o700);
  const journal = path.join(folder, 'devices.json'); initializeEnrollmentState(journal, '--gateway-stopped');
  const opensslPath = process.env.OPENSSL || (process.platform === 'darwin' ? execFileSync('/usr/bin/which', ['openssl'], { encoding: 'utf8' }).trim() : '/usr/bin/openssl');
  const { gateway, ports } = await fixture(t, { bindings: [], passwords: {}, enrollment: { enabled: true, journal, issuer: { enabled: true, openssl: opensslPath, caCertificateFile: path.join(directory, 'issuing-ca.crt'), caPrivateKeyFile: path.join(directory, 'issuing-ca.key'), validityDays: 1 } } });
  const config = { configured: true, gatewayUrl: new URL(`https://127.0.0.1:${ports.controlPort}`), files: { ca: path.join(directory, 'server-ca.crt'), cert: path.join(directory, 'conecta-api.crt'), key: path.join(directory, 'conecta-api.key') } };
  const client = createRemoteGateway({ config });
  const input = { requestId: crypto.randomUUID(), agentId, repeaterId, csrPem: read('enrolling.csr').toString(), previousCertificateSha256: null };
  const issued = await client.enrollDevice(input);
  const validated = validateIssuedCertificate(issued, input, { deviceCaFile: path.join(directory, 'device-ca.crt') }, Date.now());
  assert.equal(validated.certificateSha256, gateway.relay.bindings.get(agentId).certificateSha256);
  assert.equal(validated.certificatePem.match(/BEGIN CERTIFICATE/g).length, 2);
  assert.ok(new crypto.X509Certificate(validated.certificatePem).checkPrivateKey(crypto.createPrivateKey(read('enrolling.key'))));
  assert.equal(issued.password, undefined); assert.equal(issued.privateKey, undefined);
  assert.deepEqual(await client.enrollDevice(input), issued);
  await assert.rejects(client.enrollDevice({ ...input, requestId: crypto.randomUUID() }), { statusCode: 409 });
  await assert.rejects(client.enrollDevice({ ...input, requestId: crypto.randomUUID(), csrPem: 'x'.repeat(4097) }), { statusCode: 400 });
  await assert.rejects(client.enrollDevice({ ...input, requestId: crypto.randomUUID(), csrPem: 'x'.repeat(9000) }), { statusCode: 503 });
  const wrongControl = createRemoteGateway({ config: { ...config, files: { ...config.files, cert: path.join(directory, 'other-api.crt'), key: path.join(directory, 'other-api.key') } } });
  await assert.rejects(wrongControl.enrollDevice(input), { statusCode: 503 });
  assert.equal(gateway.enrollment.document.devices.length, 1); assert.equal(gateway.enrollment.document.requests.length, 1);
  assert.equal(gateway.relay.live.size, 0); assert.equal(gateway.relay.rows.size, 0);
});
