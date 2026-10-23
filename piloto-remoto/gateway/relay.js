'use strict';

const crypto = require('node:crypto');
const fs = require('node:fs');
const net = require('node:net');
const path = require('node:path');

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
const ID = /^[1-9][0-9]{0,8}$/;
const CLOSE_REASONS = new Set(['revoked', 'revoked_unknown', 'expired', 'gateway_restart', 'gateway_shutdown', 'journal_unavailable', 'listener_unavailable', 'listener_error', 'agent_disconnected', 'viewer_disconnected', 'certificate_expired']);
const fingerprint = (value) => String(value || '').replace(/:/g, '').toLowerCase();
const ip = (value) => String(value || '').replace(/^::ffff:/, '');
class RelayError extends Error {
  constructor(code, status = 400) { super(code); this.code = code; this.status = status; }
}
const exact = (value, keys) => {
  if (!value || typeof value !== 'object' || Array.isArray(value) || Object.keys(value).some((key) => !keys.includes(key)) || keys.some((key) => !Object.hasOwn(value, key))) throw new RelayError('InvalidShape');
};
const copy = (value) => JSON.parse(JSON.stringify(value));

// O relay só encaminha bytes. Não interpreta nem registra tela, arquivos,
// teclas, clipboard ou senha do protocolo VNC.
class AuthorizedRelay {
  constructor(options) {
    this.now = options.now || Date.now;
    this.bindings = new Map(); this.certificates = new Map(); this.rows = new Map(); this.live = new Map(); this.usedPorts = new Set();
    this.hostname = options.hostname;
    this.viewerHost = options.viewerHost || '127.0.0.1';
    this.viewerIps = new Set((options.viewerIps || []).map(ip));
    this.journal = options.journal;
    this.maxLeases = options.maxLeases || 8;
    this.portRange = options.portRange || [0, 0];
    this.stopped = false; this.healthy = true;
    this.onClosed = () => {};
    if (!/^[a-zA-Z0-9][a-zA-Z0-9.-]{0,252}$/.test(this.hostname) || !this.viewerIps.size || this.viewerIps.size > 16 || [...this.viewerIps].some((value) => !net.isIP(value) || value === '0.0.0.0' || value === '::') || !this.journal || !path.isAbsolute(this.journal) || !Number.isInteger(this.maxLeases) || this.maxLeases < 1 || this.maxLeases > 32 || !Array.isArray(options.bindings) || options.bindings.length > 1024) throw new RelayError('InvalidConfiguration');
    const [low, high] = this.portRange;
    if (!Number.isInteger(low) || !Number.isInteger(high) || !((low === 0 && high === 0) || (low >= 1024 && high >= low && high <= 65535 && high - low <= 4095))) throw new RelayError('InvalidPortRange');
    for (const binding of options.bindings) {
      exact(binding, ['agentId', 'repeaterId', 'certificateSha256']);
      const hash = fingerprint(binding.certificateSha256);
      if (!UUID.test(binding.agentId) || !ID.test(binding.repeaterId) || !/^[a-f0-9]{64}$/.test(hash) || this.bindings.has(binding.agentId) || this.certificates.has(hash) || [...this.bindings.values()].some((item) => item.repeaterId === binding.repeaterId)) throw new RelayError('InvalidBinding');
      const password = options.passwords[binding.agentId];
      if (typeof password !== 'string' || !/^[\x21-\x7e]{8}$/.test(password)) throw new RelayError('InvalidDeviceCredential');
      const value = { ...binding, certificateSha256: hash, password };
      this.bindings.set(binding.agentId, value); this.certificates.set(hash, value);
    }
    this.load();
  }

  checkDeviceBinding(binding, previousHash, restoring = false) {
    if (!this.healthy || this.stopped) throw new RelayError('GatewayUnavailable', 503);
    if (!binding || !UUID.test(binding.agentId) || !ID.test(binding.repeaterId)) throw new RelayError('InvalidBinding');
    const current = this.bindings.get(binding.agentId);
    if (restoring) {
      if (current && (current.certificateSha256 !== binding.certificateSha256 || current.repeaterId !== binding.repeaterId || current.password !== binding.password)) throw new RelayError('DeviceEnrollmentConflict', 409);
    } else if ((current?.certificateSha256 || null) !== previousHash) throw new RelayError('DeviceEnrollmentConflict', 409);
    if ([...this.bindings.values()].some((row) => row.agentId !== binding.agentId && (row.repeaterId === binding.repeaterId || (binding.certificateSha256 && row.certificateSha256 === binding.certificateSha256)))) throw new RelayError('DeviceEnrollmentConflict', 409);
    for (const row of this.rows.values()) if (row.agentId === binding.agentId && row.state !== 'closed') { this.view(row); if (row.state !== 'closed') throw new RelayError('DeviceBusy', 409); }
  }

  installDeviceBinding(binding) {
    if (!/^[a-f0-9]{64}$/.test(binding.certificateSha256) || typeof binding.password !== 'string' || !/^[\x21-\x7e]{8}$/.test(binding.password)) throw new RelayError('InvalidDeviceCredential');
    this.checkDeviceBinding(binding, this.bindings.get(binding.agentId)?.certificateSha256 || null);
    const previous = this.bindings.get(binding.agentId); if (previous) this.certificates.delete(previous.certificateSha256);
    const value = { agentId: binding.agentId, repeaterId: binding.repeaterId, certificateSha256: binding.certificateSha256, password: binding.password };
    this.bindings.set(value.agentId, value); this.certificates.set(value.certificateSha256, value);
  }

  revokeDeviceBinding(agentId) {
    if (!UUID.test(agentId)) throw new RelayError('InvalidAgentId');
    for (const row of this.rows.values()) if (row.agentId === agentId && row.state !== 'closed') this.close(row.leaseId, 'revoked');
    const binding = this.bindings.get(agentId);
    if (binding) this.certificates.delete(binding.certificateSha256);
    this.bindings.delete(agentId);
  }

  load() {
    const directory = path.dirname(this.journal);
    const directoryStat = fs.lstatSync(directory);
    if (!directoryStat.isDirectory() || (process.platform !== 'win32' && ((directoryStat.mode & 0o022) || directoryStat.uid !== process.getuid()))) throw new RelayError('JournalDirectoryInvalid');
    if (fs.existsSync(this.journal)) {
      const stat = fs.lstatSync(this.journal);
      if (!stat.isFile() || stat.size > 1048576 || (process.platform !== 'win32' && ((stat.mode & 0o077) || stat.uid !== process.getuid()))) throw new RelayError('JournalInvalid');
      const doc = JSON.parse(fs.readFileSync(this.journal, 'utf8'));
      exact(doc, ['schemaVersion', 'leases', 'usedPorts']);
      if (doc.schemaVersion !== 2 || !Array.isArray(doc.leases) || doc.leases.length > 2048 || !Array.isArray(doc.usedPorts) || doc.usedPorts.length > 64512) throw new RelayError('JournalInvalid');
      for (const port of doc.usedPorts) { if (!Number.isInteger(port) || port < 1024 || port > 65535 || this.usedPorts.has(port)) throw new RelayError('JournalInvalid'); this.usedPorts.add(port); }
      for (const row of doc.leases) {
        exact(row, ['leaseId', 'agentId', 'repeaterId', 'expiresAt', 'createdAt', 'connectedAt', 'closedAt', 'closeReason', 'state', 'requestHash']);
        if (!UUID.test(row.leaseId) || (row.agentId !== null && !UUID.test(row.agentId)) || (row.repeaterId !== null && !ID.test(row.repeaterId)) || !['creating', 'pending', 'ready', 'connected', 'closed'].includes(row.state) || !/^[a-f0-9]{64}$/.test(row.requestHash) || this.rows.has(row.leaseId)) throw new RelayError('JournalInvalid');
        for (const key of ['expiresAt', 'createdAt', 'connectedAt', 'closedAt']) if (row[key] !== null && (!Number.isFinite(Date.parse(row[key])) || typeof row[key] !== 'string')) throw new RelayError('JournalInvalid');
        if (row.createdAt === null || row.expiresAt === null || (row.state === 'closed' && (row.closedAt === null || !CLOSE_REASONS.has(row.closeReason))) || (row.state !== 'closed' && (row.closeReason !== null || row.closedAt !== null || row.agentId === null || row.repeaterId === null))) throw new RelayError('JournalInvalid');
        if (row.state !== 'closed') { row.state = 'closed'; row.closedAt = this.iso(); row.closeReason = 'gateway_restart'; }
        this.rows.set(row.leaseId, row);
      }
    }
    this.save();
  }

  iso() { return new Date(this.now()).toISOString(); }
  failClosed() {
    this.healthy = false;
    for (const [id, live] of this.live) {
      const row = this.rows.get(id); row.state = 'closed'; row.closedAt = this.iso(); row.closeReason = 'journal_unavailable';
      live.agent?.destroy(); live.viewer?.destroy(); live.server?.close(); clearTimeout(live.timer);
      this.onClosed(id);
    }
    this.live.clear();
  }
  safeClose(id, reason) { try { this.close(id, reason); } catch { this.failClosed(); } }
  save() {
    // IDs consumidos persistem por pelo menos 24h. Nenhum segredo integra o journal.
    const cutoff = this.now() - 86400000;
    for (const [id, row] of this.rows) if (row.state === 'closed' && Date.parse(row.closedAt) < cutoff) this.rows.delete(id);
    if (this.rows.size > 2048) { this.failClosed(); throw new RelayError('JournalCapacity', 503); }
    const leases = [...this.rows.values()].map((row) => copy(row));
    // O contexto Guacamole pode sobreviver à validade do JSON de login.
    // Portanto endpoints privados NUNCA são reaproveitados automaticamente.
    const content = JSON.stringify({ schemaVersion: 2, leases, usedPorts: [...this.usedPorts] });
    if (Buffer.byteLength(content) > 1048576) { this.failClosed(); throw new RelayError('JournalCapacity', 503); }
    const temporary = `${this.journal}.${crypto.randomUUID()}.tmp`;
    let descriptor;
    try {
      descriptor = fs.openSync(temporary, fs.constants.O_CREAT | fs.constants.O_EXCL | fs.constants.O_WRONLY, 0o600);
      fs.writeFileSync(descriptor, content); fs.fsyncSync(descriptor); fs.closeSync(descriptor); descriptor = undefined;
      fs.renameSync(temporary, this.journal);
      const directory = fs.openSync(path.dirname(this.journal), fs.constants.O_RDONLY);
      try { fs.fsyncSync(directory); } finally { fs.closeSync(directory); }
    } catch {
      this.failClosed();
      throw new RelayError('JournalUnavailable', 503);
    } finally {
      try { if (descriptor !== undefined) fs.closeSync(descriptor); } catch { /* Fail closed acima. */ }
      try { if (fs.existsSync(temporary)) fs.unlinkSync(temporary); } catch { /* Arquivo temporário não autoriza conexões. */ }
    }
  }

  view(row, includeCredential = false) {
    if (row.state !== 'closed' && Date.parse(row.expiresAt) <= this.now()) this.close(row.leaseId, 'expired');
    const live = this.live.get(row.leaseId);
    const result = { leaseId: row.leaseId, agentId: row.agentId, repeaterId: row.repeaterId, state: row.state, hostname: this.hostname, port: live?.port || null, expiresAt: row.expiresAt, createdAt: row.createdAt, connectedAt: row.connectedAt, closedAt: row.closedAt, closeReason: row.closeReason };
    if (includeCredential && row.state !== 'closed' && this.healthy && !this.stopped) result.password = this.bindings.get(row.agentId)?.password;
    return result;
  }

  get(id) {
    if (!UUID.test(id)) throw new RelayError('InvalidLeaseId');
    const row = this.rows.get(id); if (!row) throw new RelayError('LeaseNotFound', 404);
    return this.view(row, true);
  }

  async create(body) {
    exact(body, ['sessionId', 'agentId', 'repeaterId', 'expiresAt', 'certificateSha256']);
    if (!this.healthy || this.stopped) throw new RelayError('GatewayUnavailable', 503);
    const now = this.now(); const until = Date.parse(body.expiresAt);
    if (!UUID.test(body.sessionId) || !UUID.test(body.agentId) || typeof body.repeaterId !== 'string' || !ID.test(body.repeaterId) || !/^[a-f0-9]{64}$/.test(body.certificateSha256) || typeof body.expiresAt !== 'string' || !Number.isFinite(until) || !/(?:Z|[+-]\d\d:\d\d)$/.test(body.expiresAt)) throw new RelayError('InvalidLease');
    const binding = this.bindings.get(body.agentId);
    if (!binding || binding.repeaterId !== body.repeaterId || binding.certificateSha256 !== body.certificateSha256) throw new RelayError('DeviceNotAuthorized', 403);
    const requestHash = crypto.createHash('sha256').update(JSON.stringify({ sessionId: body.sessionId, agentId: body.agentId, repeaterId: body.repeaterId, expiresAt: body.expiresAt, certificateSha256: body.certificateSha256 })).digest('hex');
    const previous = this.rows.get(body.sessionId);
    if (previous) { if (previous.requestHash !== requestHash) throw new RelayError('LeaseConflict', 409); return this.view(previous); }
    if (until <= now || until > now + 900000) throw new RelayError('InvalidLease');
    for (const row of this.rows.values()) if (row.agentId === body.agentId && row.state !== 'closed') { this.view(row); if (row.state !== 'closed') throw new RelayError('DeviceBusy', 409); }
    if (this.live.size >= this.maxLeases) throw new RelayError('GatewayCapacity', 503);
    const row = { leaseId: body.sessionId, agentId: body.agentId, repeaterId: body.repeaterId, expiresAt: new Date(until).toISOString(), createdAt: this.iso(), connectedAt: null, closedAt: null, closeReason: null, state: 'creating', requestHash };
    this.rows.set(row.leaseId, row); this.save();
    const live = { agent: null, viewer: null, initial: null, server: null, port: null, timer: null };
    this.live.set(row.leaseId, live);
    try {
      live.server = await this.listenViewer(row);
      if (this.stopped || !this.healthy || this.live.get(row.leaseId) !== live || row.state !== 'creating') { live.server.close(); throw new RelayError('LeaseClosed', 409); }
      live.port = live.server.address().port; row.state = 'pending'; this.save();
      live.timer = setTimeout(() => this.safeClose(row.leaseId, 'expired'), Math.max(1, until - this.now())); live.timer.unref();
      return this.view(row);
    } catch (error) { this.close(row.leaseId, 'listener_unavailable'); throw error instanceof RelayError ? error : new RelayError('ListenerUnavailable', 503); }
  }

  async listenViewer(row) {
    const [low, high] = this.portRange;
    const ephemeral = low === 0;
    for (let attempt = 0, port = low; ephemeral ? attempt < 32 : port <= high; attempt += 1, port += ephemeral ? 0 : 1) {
      if (!ephemeral && this.usedPorts.has(port)) continue;
      if (!ephemeral) { this.usedPorts.add(port); this.save(); }
      const server = net.createServer((socket) => this.attachViewer(row, socket));
      try {
        await new Promise((resolve, reject) => { server.once('error', reject); server.listen({ host: this.viewerHost, port }, resolve); });
        const allocated = server.address().port;
        if (ephemeral && this.usedPorts.has(allocated)) { server.close(); continue; }
        if (ephemeral) { this.usedPorts.add(allocated); this.save(); }
        server.removeAllListeners('error'); server.on('error', () => this.safeClose(row.leaseId, 'listener_error'));
        return server;
      } catch (error) { server.close(); if (error.code !== 'EADDRINUSE' || (!ephemeral && port === high)) throw error; }
    }
    throw new RelayError('NoViewerPort', 503);
  }

  attachAgent(socket) {
    socket.on('error', () => {});
    if (!socket.authorized || !this.healthy || this.stopped) { socket.destroy(); return; }
    const certificate = socket.getPeerCertificate();
    const binding = this.certificates.get(fingerprint(certificate.fingerprint256));
    if (!binding || !Number.isFinite(Date.parse(certificate.valid_to)) || Date.parse(certificate.valid_to) <= this.now()) { socket.destroy(); return; }
    const row = [...this.rows.values()].find((item) => item.agentId === binding.agentId && item.state === 'pending');
    if (!row || Date.parse(row.expiresAt) <= this.now()) { socket.destroy(); return; }
    let buffer = Buffer.alloc(0); let finished = false;
    socket.setTimeout(5000, () => socket.destroy());
    const receive = (chunk) => {
      buffer = Buffer.concat([buffer, chunk]);
      if (buffer.length > 4096) { socket.destroy(); return; }
      if (buffer.length < 250) return;
      const frame = buffer.subarray(0, 250); const end = frame.indexOf(0);
      if (end < 0 || frame.subarray(end).some((value) => value !== 0) || !frame.subarray(0, end).equals(Buffer.from(`ID:${binding.repeaterId}`, 'ascii'))) { socket.destroy(); return; }
      const live = this.live.get(row.leaseId);
      if (!live || row.state !== 'pending' || live.agent || !this.healthy || Date.parse(row.expiresAt) <= this.now()) { socket.destroy(); return; }
      finished = true; socket.removeListener('data', receive); socket.setTimeout(0); socket.pause();
      live.agent = socket; live.initial = buffer.subarray(250); row.state = 'ready';
      try { this.save(); } catch { socket.destroy(); return; }
      const remaining = Date.parse(certificate.valid_to) - this.now();
      if (remaining < Date.parse(row.expiresAt) - this.now()) { clearTimeout(live.timer); live.timer = setTimeout(() => this.safeClose(row.leaseId, 'certificate_expired'), Math.max(1, remaining)); live.timer.unref(); }
      socket.once('close', () => this.safeClose(row.leaseId, 'agent_disconnected'));
    };
    socket.on('data', receive);
    socket.once('close', () => { if (!finished) buffer = Buffer.alloc(0); });
  }

  attachViewer(row, socket) {
    socket.on('error', () => {});
    const live = this.live.get(row.leaseId);
    if (!this.viewerIps.has(ip(socket.remoteAddress)) || !live?.agent || live.viewer || row.state !== 'ready' || !this.healthy || Date.parse(row.expiresAt) <= this.now()) { socket.destroy(); return; }
    socket.pause(); live.viewer = socket; row.state = 'connected'; row.connectedAt = this.iso();
    try { this.save(); } catch { socket.destroy(); return; }
    socket.once('close', () => this.safeClose(row.leaseId, 'viewer_disconnected'));
    if (live.initial?.length) socket.write(live.initial);
    live.initial = null;
    live.agent.pipe(socket); socket.pipe(live.agent); socket.resume(); live.agent.resume();
  }

  close(id, reason = 'revoked') {
    if (!UUID.test(id)) throw new RelayError('InvalidLeaseId');
    if (!CLOSE_REASONS.has(reason)) throw new RelayError('InvalidCloseReason');
    let row = this.rows.get(id);
    if (!row) {
      row = { leaseId: id, agentId: null, repeaterId: null, expiresAt: this.iso(), createdAt: this.iso(), connectedAt: null, closedAt: this.iso(), closeReason: 'revoked_unknown', state: 'closed', requestHash: '0'.repeat(64) };
      this.rows.set(id, row);
    }
    if (row.state !== 'closed') { row.state = 'closed'; row.closedAt = this.iso(); row.closeReason = reason; }
    const live = this.live.get(id);
    if (live) { clearTimeout(live.timer); live.agent?.destroy(); live.viewer?.destroy(); live.server?.close(); this.live.delete(id); }
    this.onClosed(id);
    this.save(); return this.view(row);
  }

  shutdown() {
    this.stopped = true;
    for (const id of [...this.live.keys()]) this.safeClose(id, 'gateway_shutdown');
  }
}

module.exports = { AuthorizedRelay, RelayError };
