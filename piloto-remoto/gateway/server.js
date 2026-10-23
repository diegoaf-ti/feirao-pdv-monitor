'use strict';

const fs = require('node:fs');
const https = require('node:https');
const tls = require('node:tls');
const crypto = require('node:crypto');
const { AuthorizedRelay, RelayError } = require('./relay');
const { createWebViewer } = require('./web-viewer');
const { CertificateIssuer, DeviceEnrollment } = require('./enrollment');

const send = (response, status, value) => {
  response.writeHead(status, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' });
  response.end(JSON.stringify(value));
};
const readBody = async (request, limit = 4096) => {
  if (request.headers['content-type']?.split(';')[0].trim() !== 'application/json' || request.headers['content-encoding']) throw new RelayError('UnsupportedMediaType', 415);
  let bytes = 0; const chunks = [];
  for await (const chunk of request) { bytes += chunk.length; if (bytes > limit) throw new RelayError('BodyTooLarge', 413); chunks.push(chunk); }
  try { return JSON.parse(Buffer.concat(chunks).toString('utf8')); } catch { throw new RelayError('InvalidJson'); }
};
const createGateway = (options) => {
  const rootCertificate = (pem) => {
    const match = /^\s*(-----BEGIN CERTIFICATE-----[\s\S]+?-----END CERTIFICATE-----)\s*$/.exec(Buffer.from(pem).toString('utf8'));
    if (!match || (match[1].match(/-----BEGIN CERTIFICATE-----/g) || []).length !== 1) throw new RelayError('SingleSelfSignedAuthorityRequired');
    const certificate = new crypto.X509Certificate(match[1]);
    if (!certificate.ca || !certificate.checkIssued(certificate) || !certificate.verify(certificate.publicKey)) throw new RelayError('SingleSelfSignedAuthorityRequired');
    return certificate;
  };
  const controlCa = rootCertificate(options.controlTls.ca); const deviceCa = rootCertificate(options.deviceTls.ca);
  if (controlCa.fingerprint256 === deviceCa.fingerprint256) throw new RelayError('SeparateCertificateAuthoritiesRequired');
  const controlPin = String(options.controlClientSha256 || '').replace(/:/g, '').toLowerCase();
  if (!/^[a-f0-9]{64}$/.test(controlPin) || options.bindings.some((binding) => binding.certificateSha256.replace(/:/g, '').toLowerCase() === controlPin)) throw new RelayError('ControlClientPinRequired');
  for (const identity of [options.controlTls, options.deviceTls, ...(options.web?.enabled === true ? [options.web.tls] : [])]) { if (!identity?.key || !identity?.cert) throw new RelayError('TlsIdentityRequired'); tls.createSecureContext(identity); }
  // Sem recuperação automática de lock após crash: exige revisão do journal.
  // Evita dois processos sobrescrevendo a lista de endpoints já consumidos.
  const lock = `${options.journal}.lock`; let locked = false;
  let relay;
  try {
    const descriptor = fs.openSync(lock, fs.constants.O_CREAT | fs.constants.O_EXCL | fs.constants.O_WRONLY, 0o600); locked = true;
    try { fs.writeFileSync(descriptor, String(process.pid)); fs.fsyncSync(descriptor); } finally { fs.closeSync(descriptor); }
    relay = new AuthorizedRelay(options);
  } catch (error) { if (locked) fs.unlinkSync(lock); throw error; }
  const sockets = new Set();
  let web; let enrollment;
  try {
    if (options.enrollment?.enabled === true) {
      const issuer = new CertificateIssuer({ ...options.enrollment.issuer, deviceCaPem: options.deviceTls.ca, now: options.now });
      enrollment = new DeviceEnrollment({ enabled: true, journal: options.enrollment.journal, issuer, now: options.now, canInstall: relay.checkDeviceBinding.bind(relay), install: relay.installDeviceBinding.bind(relay), revoke: relay.revokeDeviceBinding.bind(relay), failClosed: relay.failClosed.bind(relay) });
    }
    web = options.web?.enabled === true ? createWebViewer({ relay, config: options.web, now: options.now }) : null; }
  catch (error) { enrollment?.stop(); relay.shutdown(); if (locked) { fs.unlinkSync(lock); locked = false; } throw error; }
  if (web) relay.onClosed = (id) => web.invalidate(id);
  // CAs separadas: certificado de caixa não permite criar/revogar leases.
  const control = https.createServer({ ...options.controlTls, minVersion: 'TLSv1.2', requestCert: true, rejectUnauthorized: true, handshakeTimeout: 5000 }, async (request, response) => {
    try {
      const peerPin = String(request.socket.getPeerCertificate().fingerprint256 || '').replace(/:/g, '').toLowerCase();
      if (!request.socket.authorized || peerPin !== controlPin) throw new RelayError('ControlNotAuthorized', 403);
      if (request.url === '/v1/devices/enrollments' && request.method === 'POST') {
        if (!enrollment) throw new RelayError('EnrollmentDisabled', 503);
        send(response, 200, enrollment.enroll(await readBody(request, 8192))); return;
      }
      const deviceMatch = /^\/v1\/devices\/([0-9a-f-]{36})$/.exec(request.url || '');
      if (deviceMatch && request.method === 'DELETE') {
        if (!enrollment) throw new RelayError('EnrollmentDisabled', 503);
        send(response, 200, enrollment.revoke(deviceMatch[1])); return;
      }
      if (request.url === '/v1/leases' && request.method === 'POST') {
        const result = await relay.create(await readBody(request)); send(response, 200, result); return;
      }
      const viewerMatch = /^\/v1\/leases\/([0-9a-f-]{36})\/viewer$/.exec(request.url || '');
      if (viewerMatch && request.method === 'POST') {
        if (!web) throw new RelayError('ViewerDisabled', 503);
        send(response, 200, web.issue(viewerMatch[1], await readBody(request))); return;
      }
      const match = /^\/v1\/leases\/([0-9a-f-]{36})$/.exec(request.url || '');
      if (match && request.method === 'GET') { send(response, 200, relay.get(match[1])); return; }
      if (match && request.method === 'DELETE') { send(response, 200, relay.close(match[1])); return; }
      throw new RelayError('NotFound', 404);
    } catch (error) { send(response, error instanceof RelayError ? error.status : 500, { error: error instanceof RelayError ? error.code : 'GatewayFailure' }); }
  });
  control.requestTimeout = 5000; control.headersTimeout = 5000; control.maxConnections = 16;
  const device = tls.createServer({ ...options.deviceTls, minVersion: 'TLSv1.2', requestCert: true, rejectUnauthorized: true, handshakeTimeout: 5000 }, (socket) => relay.attachAgent(socket));
  const browser = web ? https.createServer({ ...options.web.tls, minVersion: 'TLSv1.2', handshakeTimeout: 5000 }, web.handler) : null;
  device.maxConnections = 64;
  device.on('tlsClientError', (_error, socket) => socket.destroy());
  control.on('tlsClientError', (_error, socket) => socket.destroy());
  if (browser) { browser.requestTimeout = 10000; browser.headersTimeout = 5000; browser.maxConnections = 64; browser.on('tlsClientError', (_error, socket) => socket.destroy()); }
  const servers = [control, device, ...(browser ? [browser] : [])];
  for (const server of servers) server.on('connection', (socket) => { sockets.add(socket); socket.once('close', () => sockets.delete(socket)); });
  return {
    relay, enrollment, control, device, browser,
    async listen({ controlHost = '127.0.0.1', controlPort = 0, deviceHost = '127.0.0.1', devicePort = 0, browserHost = '127.0.0.1', browserPort = 0 } = {}) {
      const listen = (server, host, port) => new Promise((resolve, reject) => {
        const failed = (error) => reject(error);
        server.once('error', failed); server.listen({ host, port }, () => { server.removeListener('error', failed); resolve(); });
      });
      try { await listen(control, controlHost, controlPort); await listen(device, deviceHost, devicePort); if (browser) await listen(browser, browserHost, browserPort); }
      catch (error) { web?.stop(); enrollment?.stop(); relay.shutdown(); for (const socket of sockets) socket.destroy(); for (const server of servers) server.close(); throw error; }
      return { controlPort: control.address().port, devicePort: device.address().port, ...(browser ? { browserPort: browser.address().port } : {}) };
    },
    async stop() {
      web?.stop(); enrollment?.stop(); relay.shutdown(); control.closeAllConnections(); browser?.closeAllConnections();
      for (const socket of sockets) socket.destroy();
      await Promise.all(servers.map((server) => new Promise((resolve) => server.close(resolve))));
      if (locked && relay.healthy) { fs.unlinkSync(lock); locked = false; }
    },
  };
};

const fromFiles = (config) => {
  if (config.enabled !== true) throw new RelayError('PilotDisabled', 503);
  if (!Array.isArray(config.portRange) || config.portRange[0] === 0) throw new RelayError('FixedPrivatePortRangeRequired');
  if (!config.files?.journal || !fs.existsSync(config.files.journal)) throw new RelayError('JournalMustBeInitializedOffline');
  const read = (name) => {
    const target = config.files[name]; const stat = fs.lstatSync(target);
    if (!stat.isFile() || stat.size > 1048576) throw new RelayError('InvalidProtectedFile');
    if (['serverKey', 'viewerServerKey', 'guacamoleJsonKey', 'devicePasswords'].includes(name) && process.platform !== 'win32' && (stat.mode & 0o077)) throw new RelayError('PrivateFilePermissionsRequired');
    return fs.readFileSync(target);
  };
  return createGateway({
    hostname: config.hostname, viewerHost: config.viewerHost, viewerIps: config.viewerIps,
    portRange: config.portRange, journal: config.files.journal, maxLeases: config.maxLeases,
    controlClientSha256: config.controlClientSha256,
    enrollment: config.enrollment?.enabled === true ? config.enrollment : { enabled: false },
    bindings: JSON.parse(read('bindings')), passwords: JSON.parse(read('devicePasswords')),
    controlTls: { key: read('serverKey'), cert: read('serverCert'), ca: read('controlCa') },
    deviceTls: { key: read('serverKey'), cert: read('serverCert'), ca: read('deviceCa') },
    web: config.web?.enabled === true ? { ...config.web, jsonKey: read('guacamoleJsonKey').toString('utf8').trim(), tls: { key: read('viewerServerKey'), cert: read('viewerServerCert') }, ...(config.files.guacamoleCa ? { upstreamCa: read('guacamoleCa') } : {}) } : { enabled: false },
  });
};

if (require.main === module) {
  let gateway;
  try {
    if (!process.env.PDV_REMOTE_GATEWAY_CONFIG) throw new RelayError('ConfigurationRequired');
    const config = JSON.parse(fs.readFileSync(process.env.PDV_REMOTE_GATEWAY_CONFIG, 'utf8'));
    gateway = fromFiles(config);
    gateway.listen(config.listen).then(() => { process.stdout.write('Remote pilot gateway listening; no session is authorized by startup.\n'); }).catch(() => { process.stderr.write('Remote pilot gateway failed to listen.\n'); process.exitCode = 1; });
    for (const signal of ['SIGINT', 'SIGTERM']) process.once(signal, () => { gateway.stop().then(() => { process.exitCode = 0; }); });
  } catch { process.stderr.write('Remote pilot gateway unavailable; verify local configuration and protected files.\n'); process.exitCode = 1; }
}

module.exports = { createGateway, fromFiles };
