'use strict';

// Provisionamento opt-in, alcançável somente pela API de controle mTLS.
// O cliente gera sua chave; o emissor recebe apenas o CSR público.
const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { execFileSync } = require('node:child_process');
const { RelayError } = require('./relay');

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
const REPEATER = /^[1-9][0-9]{0,8}$/;
const HASH = /^[a-f0-9]{64}$/;
const MAX_JOURNAL_BYTES = 32 * 1024 * 1024;
const RENEWAL_PREPARE_MS = 24 * 60 * 60 * 1000;
const RENEWAL_REQUEST_MS = 5 * 60 * 1000;
const canonicalDate = (value) => typeof value === 'string' && Number.isFinite(Date.parse(value)) && new Date(value).toISOString() === value;
const copy = (value) => JSON.parse(JSON.stringify(value));
const fingerprint = (cert) => cert.fingerprint256.replace(/:/g, '').toLowerCase();
const exact = (value, fields) => {
  if (!value || typeof value !== 'object' || Array.isArray(value) || Object.keys(value).length !== fields.length || fields.some((field) => !Object.hasOwn(value, field))) throw new RelayError('InvalidEnrollmentShape');
};
const privateFile = (target, maximum) => {
  if (!path.isAbsolute(target)) throw new RelayError('AbsoluteEnrollmentPathRequired');
  const stat = fs.lstatSync(target);
  if (!stat.isFile() || stat.size > maximum || (process.platform !== 'win32' && ((stat.mode & 0o077) || stat.uid !== process.getuid()))) throw new RelayError('ProtectedEnrollmentFileRequired');
  return fs.readFileSync(target);
};
const ownedDirectory = (target) => {
  if (!path.isAbsolute(target)) throw new RelayError('AbsoluteEnrollmentPathRequired');
  const stat = fs.lstatSync(target);
  if (!stat.isDirectory() || (process.platform !== 'win32' && ((stat.mode & 0o077) || stat.uid !== process.getuid()))) throw new RelayError('ProtectedEnrollmentDirectoryRequired');
};
const initializeEnrollmentState = (target, confirmation) => {
  if (confirmation !== '--gateway-stopped') throw new RelayError('OfflineEnrollmentInitializationRequired');
  ownedDirectory(path.dirname(target));
  const descriptor = fs.openSync(target, fs.constants.O_CREAT | fs.constants.O_EXCL | fs.constants.O_WRONLY, 0o600);
  try { fs.writeFileSync(descriptor, JSON.stringify({ schemaVersion: 1, devices: [], requests: [] })); fs.fsyncSync(descriptor); }
  finally { fs.closeSync(descriptor); }
};

class CertificateIssuer {
  constructor(options) {
    if (options?.enabled !== true) throw new RelayError('EnrollmentIssuerDisabled', 503);
    this.openssl = options.openssl || '/usr/bin/openssl';
    if (!path.isAbsolute(this.openssl)) throw new RelayError('AbsoluteOpenSslPathRequired');
    this.validityDays = options.validityDays ?? 90;
    if (!Number.isInteger(this.validityDays) || this.validityDays < 1 || this.validityDays > 90) throw new RelayError('InvalidCertificateLifetime');
    this.now = options.now || Date.now;
    this.caKeyFile = options.caPrivateKeyFile || options.caKeyFile;
    this.caCertFile = options.caCertificateFile || options.caCertFile;
    try {
      if (!/^OpenSSL 3\./.test(this.command(['version']))) throw new Error('OpenSsl3Required');
      const issuerPem = privateFile(this.caCertFile, 16384).toString('utf8');
      const rootPem = Buffer.from(options.deviceCaPem || '').toString('utf8');
      const single = (pem) => /^\s*-----BEGIN CERTIFICATE-----[A-Za-z0-9+/=\r\n]+-----END CERTIFICATE-----\s*$/.test(pem);
      if (!single(issuerPem) || !single(rootPem)) throw new Error('SingleAuthorityRequired');
      this.ca = new crypto.X509Certificate(issuerPem); const root = new crypto.X509Certificate(rootPem);
      const key = crypto.createPrivateKey(privateFile(this.caKeyFile, 32768));
      const minimumExpiry = this.now() + this.validityDays * 86400000;
      if (!root.ca || !root.verify(root.publicKey) || !root.checkIssued(root) || !this.ca.ca || !this.ca.checkPrivateKey(key) || key.asymmetricKeyType !== 'rsa' || key.asymmetricKeyDetails.modulusLength < 2048 || Date.parse(this.ca.validFrom) > this.now() || Date.parse(root.validFrom) > this.now() || Date.parse(this.ca.validTo) < minimumExpiry || Date.parse(root.validTo) < minimumExpiry) throw new Error('InvalidAuthority');
      this.rootPem = rootPem; this.intermediatePem = '';
      if (fingerprint(this.ca) !== fingerprint(root)) {
        if (!this.ca.checkIssued(root) || !this.ca.verify(root.publicKey) || Date.parse(this.ca.validTo) > Date.parse(root.validTo)) throw new Error('WrongAuthority');
        const rootDirectory = fs.mkdtempSync(path.join(os.tmpdir(), 'pdv-authority-')); fs.chmodSync(rootDirectory, 0o700);
        let rootDetails;
        try { const rootFile = path.join(rootDirectory, 'root.pem'); fs.writeFileSync(rootFile, rootPem, { mode: 0o600 }); rootDetails = this.command(['x509', '-in', rootFile, '-noout', '-text']); }
        finally { fs.rmSync(rootDirectory, { recursive: true, force: true }); }
        const rootLimit = /CA:TRUE, pathlen:([0-9]+)/.exec(rootDetails);
        if (rootLimit && Number(rootLimit[1]) < 1) throw new Error('RootDoesNotAllowIntermediate');
        const details = this.command(['x509', '-in', this.caCertFile, '-noout', '-text']);
        if (!/CA:TRUE, pathlen:0/.test(details)) throw new Error('RestrictedIntermediateRequired');
        this.intermediatePem = `${issuerPem.trim()}\n`;
      } else throw new Error('IntermediateIssuerRequired');
    } catch { throw new RelayError('InvalidDeviceIssuingAuthority', 503); }
  }

  command(args) {
    try { return execFileSync(this.openssl, args, { encoding: 'utf8', timeout: 8000, maxBuffer: 65536, stdio: ['ignore', 'pipe', 'pipe'], env: { PATH: '/usr/bin:/bin' } }); }
    catch { throw new RelayError('CertificateOperationFailed', 503); }
  }

  sign(csrPem, agentId) {
    if (!UUID.test(agentId) || typeof csrPem !== 'string' || Buffer.byteLength(csrPem) > 4096 || !/^-----BEGIN CERTIFICATE REQUEST-----\r?\n[A-Za-z0-9+/=\r\n]+-----END CERTIFICATE REQUEST-----\r?\n?$/.test(csrPem)) throw new RelayError('InvalidCertificateRequest');
    const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'pdv-csr-')); fs.chmodSync(directory, 0o700);
    const csr = path.join(directory, 'request.pem'); const extensions = path.join(directory, 'extensions.conf');
    try {
      fs.writeFileSync(csr, csrPem, { mode: 0o600 });
      let publicKey;
      try {
        this.command(['req', '-in', csr, '-verify', '-noout']);
        if (this.command(['req', '-in', csr, '-noout', '-subject', '-nameopt', 'RFC2253']).trim() !== `subject=CN=pdv-${agentId}`) throw new Error('SubjectMismatch');
        const details = this.command(['req', '-in', csr, '-noout', '-text']);
        if (!/Signature Algorithm: sha256WithRSAEncryption\s/.test(details)) throw new Error('WeakSignature');
        publicKey = crypto.createPublicKey(this.command(['req', '-in', csr, '-pubkey', '-noout']));
        const keyDetails = publicKey.asymmetricKeyDetails || {};
        if (publicKey.asymmetricKeyType === 'rsa') {
          if (keyDetails.modulusLength < 2048 || keyDetails.modulusLength > 4096 || keyDetails.publicExponent !== 65537n) throw new Error('WeakKey');
        } else throw new Error('UnsupportedKey');
      } catch { throw new RelayError('InvalidCertificateRequest'); }
      // Nenhuma extensão ou subject do CSR é copiado. Nunca emite CA/serverAuth.
      fs.writeFileSync(extensions, `basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=clientAuth\n`, { mode: 0o600 });
      const serial = crypto.randomBytes(20); serial[0] = (serial[0] & 0x7f) || 1;
      const certificatePem = this.command(['x509', '-req', '-in', csr, '-CA', this.caCertFile, '-CAkey', this.caKeyFile, '-set_serial', `0x${serial.toString('hex')}`, '-days', String(this.validityDays), '-sha256', '-subj', `/CN=pdv-${agentId}`, '-extfile', extensions]);
      const certificate = new crypto.X509Certificate(certificatePem);
      if (certificate.ca || !certificate.verify(this.ca.publicKey) || !certificate.publicKey.export({ type: 'spki', format: 'der' }).equals(publicKey.export({ type: 'spki', format: 'der' })) || Date.parse(certificate.validTo) > Date.parse(this.ca.validTo) || !certificate.keyUsage?.includes('1.3.6.1.5.5.7.3.2')) throw new RelayError('InvalidIssuedCertificate', 503);
      const rootFile = path.join(directory, 'root.pem'); const leafFile = path.join(directory, 'leaf.pem');
      fs.writeFileSync(rootFile, this.rootPem, { mode: 0o600 }); fs.writeFileSync(leafFile, certificatePem, { mode: 0o600 });
      this.command(['verify', '-CAfile', rootFile, ...(this.intermediatePem ? ['-untrusted', this.caCertFile] : []), '-purpose', 'sslclient', leafFile]);
      return { certificatePem: `${certificatePem.trim()}\n${this.intermediatePem}`, certificateSha256: fingerprint(certificate), expiresAt: new Date(certificate.validTo).toISOString() };
    } finally { fs.rmSync(directory, { recursive: true, force: true }); }
  }
}

class DeviceEnrollment {
  constructor(options) {
    if (options?.enabled !== true) throw new RelayError('EnrollmentDisabled', 503);
    if (!options.issuer || typeof options.issuer.sign !== 'function' || typeof options.canInstall !== 'function' || typeof options.install !== 'function' || typeof options.failClosed !== 'function' || typeof options.revoke !== 'function') throw new RelayError('InvalidEnrollmentConfiguration');
    this.issuer = options.issuer; this.canInstall = options.canInstall; this.install = options.install; this.onFailure = options.failClosed; this.remove = options.revoke;
    this.journal = options.journal; this.now = options.now || Date.now;
    this.healthy = true; this.locked = false;
    ownedDirectory(path.dirname(this.journal));
    try {
      const descriptor = fs.openSync(`${this.journal}.lock`, fs.constants.O_CREAT | fs.constants.O_EXCL | fs.constants.O_WRONLY, 0o600); this.locked = true;
      try { fs.writeFileSync(descriptor, String(process.pid)); fs.fsyncSync(descriptor); } finally { fs.closeSync(descriptor); }
      this.document = JSON.parse(privateFile(this.journal, MAX_JOURNAL_BYTES)); this.validate();
      // Migração sem reescrever no startup: a próxima mutação durável grava v2.
      if (this.document.schemaVersion === 1) this.document = { ...this.document, schemaVersion: 2, renewals: [] };
      for (const binding of this.document.devices) { if (binding.revokedAt === null) { this.canInstall(binding, null, true); this.install(binding); } else this.remove(binding.agentId); }
    } catch (error) { if (this.locked) { fs.unlinkSync(`${this.journal}.lock`); this.locked = false; } throw error; }
  }

  validate() {
    exact(this.document, this.document.schemaVersion === 1 ? ['schemaVersion', 'devices', 'requests'] : ['schemaVersion', 'devices', 'requests', 'renewals']);
    if (![1, 2].includes(this.document.schemaVersion) || !Array.isArray(this.document.devices) || this.document.devices.length > 1024 || !Array.isArray(this.document.requests) || this.document.requests.length > 4096 || (this.document.schemaVersion === 2 && (!Array.isArray(this.document.renewals) || this.document.renewals.length > 4096))) throw new RelayError('EnrollmentStateInvalid', 503);
    const agents = new Set(); const repeaters = new Set(); const hashes = new Set(); const requests = new Set();
    for (const row of this.document.devices) {
      exact(row, ['agentId', 'repeaterId', 'certificatePem', 'certificateSha256', 'expiresAt', 'password', 'revokedAt']);
      if ((row.revokedAt !== null && (typeof row.revokedAt !== 'string' || !Number.isFinite(Date.parse(row.revokedAt)))) || !UUID.test(row.agentId) || !REPEATER.test(row.repeaterId) || !HASH.test(row.certificateSha256) || typeof row.password !== 'string' || !/^[\x21-\x7e]{8}$/.test(row.password) || agents.has(row.agentId) || repeaters.has(row.repeaterId) || hashes.has(row.certificateSha256)) throw new RelayError('EnrollmentStateInvalid', 503);
      const certificate = new crypto.X509Certificate(row.certificatePem);
      if (certificate.ca || fingerprint(certificate) !== row.certificateSha256 || new Date(certificate.validTo).toISOString() !== row.expiresAt) throw new RelayError('EnrollmentStateInvalid', 503);
      agents.add(row.agentId); repeaters.add(row.repeaterId); hashes.add(row.certificateSha256);
    }
    for (const row of this.document.requests) {
      exact(row, ['requestId', 'requestHash', 'result']);
      exact(row.result, ['requestId', 'agentId', 'repeaterId', 'certificatePem', 'certificateSha256', 'expiresAt']);
      if (!UUID.test(row.requestId) || !HASH.test(row.requestHash) || requests.has(row.requestId) || row.result.requestId !== row.requestId || !agents.has(row.result.agentId) || !UUID.test(row.result.agentId) || !REPEATER.test(row.result.repeaterId) || !HASH.test(row.result.certificateSha256)) throw new RelayError('EnrollmentStateInvalid', 503);
      const certificate = new crypto.X509Certificate(row.result.certificatePem);
      if (certificate.ca || fingerprint(certificate) !== row.result.certificateSha256 || new Date(certificate.validTo).toISOString() !== row.result.expiresAt) throw new RelayError('EnrollmentStateInvalid', 503);
      requests.add(row.requestId);
    }
    const pendingAgents = new Set();
    for (const row of this.document.renewals || []) {
      exact(row, ['requestId', 'requestHash', 'input', 'result', 'state']);
      exact(row.input, ['requestId', 'agentId', 'repeaterId', 'csrPem', 'previousCertificateSha256', 'requestedAt']);
      exact(row.result, ['requestId', 'agentId', 'repeaterId', 'previousCertificateSha256', 'certificatePem', 'certificateSha256', 'expiresAt', 'preparedUntil']);
      const input = row.input; const result = row.result;
      const requestHash = crypto.createHash('sha256').update(JSON.stringify(input)).digest('hex');
      if (!UUID.test(row.requestId) || requests.has(row.requestId) || !HASH.test(row.requestHash) || row.requestHash !== requestHash || !['prepared', 'committed', 'aborted'].includes(row.state) || row.requestId !== input.requestId || row.requestId !== result.requestId || !agents.has(input.agentId) || !UUID.test(input.agentId) || !REPEATER.test(input.repeaterId) || !HASH.test(input.previousCertificateSha256) || typeof input.csrPem !== 'string' || Buffer.byteLength(input.csrPem) > 4096 || !canonicalDate(input.requestedAt) || !canonicalDate(result.preparedUntil) || !canonicalDate(result.expiresAt) || result.agentId !== input.agentId || result.repeaterId !== input.repeaterId || result.previousCertificateSha256 !== input.previousCertificateSha256 || !HASH.test(result.certificateSha256) || result.certificateSha256 === input.previousCertificateSha256 || Date.parse(result.preparedUntil) <= Date.parse(input.requestedAt) || Date.parse(result.preparedUntil) > Date.parse(input.requestedAt) + RENEWAL_PREPARE_MS + RENEWAL_REQUEST_MS) throw new RelayError('EnrollmentStateInvalid', 503);
      const certificate = new crypto.X509Certificate(result.certificatePem);
      if (certificate.ca || fingerprint(certificate) !== result.certificateSha256 || new Date(certificate.validTo).toISOString() !== result.expiresAt || certificate.subject !== `CN=pdv-${input.agentId}`) throw new RelayError('EnrollmentStateInvalid', 503);
      if (row.state === 'prepared') {
        if (pendingAgents.has(input.agentId)) throw new RelayError('EnrollmentStateInvalid', 503);
        pendingAgents.add(input.agentId);
      }
      requests.add(row.requestId);
    }
  }

  compact(document) {
    const next = { ...document, schemaVersion: 2, renewals: document.renewals || [] };
    const devices = new Map(next.devices.map((row) => [row.agentId, row]));
    // Gerações antigas nunca são reinstaladas: o CAS atual ou o tombstone as recusa.
    const kept = new Map();
    next.requests = next.requests.slice().reverse().filter((row) => {
      const current = devices.get(row.result.agentId);
      const count = kept.get(row.result.agentId) || 0;
      if (!current || current.revokedAt !== null || count >= 2) return false;
      kept.set(row.result.agentId, count + 1); return true;
    }).reverse();
    next.renewals = next.renewals.filter((row) => {
      const current = devices.get(row.input.agentId);
      if (!current || current.revokedAt !== null) return false;
      if (row.state === 'committed') return current.certificateSha256 === row.result.certificateSha256;
      return Date.parse(row.result.preparedUntil) > this.now() && current.certificateSha256 === row.input.previousCertificateSha256;
    });
    return next;
  }

  save(next) {
    const target = `${this.journal}.${crypto.randomUUID()}.tmp`;
    let descriptor;
    try {
      next = this.compact(next);
      const content = JSON.stringify(next); if (Buffer.byteLength(content) > MAX_JOURNAL_BYTES || next.renewals.length > 4096) throw new Error('Capacity');
      descriptor = fs.openSync(target, fs.constants.O_CREAT | fs.constants.O_EXCL | fs.constants.O_WRONLY, 0o600);
      fs.writeFileSync(descriptor, content); fs.fsyncSync(descriptor); fs.closeSync(descriptor); descriptor = undefined;
      fs.renameSync(target, this.journal);
      const directory = fs.openSync(path.dirname(this.journal), fs.constants.O_RDONLY); try { fs.fsyncSync(directory); } finally { fs.closeSync(directory); }
      this.document = next;
    } catch {
      this.healthy = false; this.onFailure(); throw new RelayError('EnrollmentStateUnavailable', 503);
    } finally {
      try { if (descriptor !== undefined) fs.closeSync(descriptor); } catch { /* Fail closed acima. */ }
      try { if (fs.existsSync(target)) fs.unlinkSync(target); } catch { /* Não autoriza conexão. */ }
    }
  }

  enroll(body) {
    if (!this.healthy) throw new RelayError('EnrollmentUnavailable', 503);
    exact(body, ['requestId', 'agentId', 'repeaterId', 'csrPem', 'previousCertificateSha256']);
    if (!UUID.test(body.requestId) || !UUID.test(body.agentId) || (typeof body.repeaterId !== 'string' || !REPEATER.test(body.repeaterId)) || typeof body.csrPem !== 'string' || Buffer.byteLength(body.csrPem) > 4096 || (body.previousCertificateSha256 !== null && !HASH.test(body.previousCertificateSha256))) throw new RelayError('InvalidEnrollment');
    const requestHash = crypto.createHash('sha256').update(JSON.stringify({ requestId: body.requestId, agentId: body.agentId, repeaterId: body.repeaterId, csrPem: body.csrPem, previousCertificateSha256: body.previousCertificateSha256 })).digest('hex');
    const previous = this.document.requests.find((row) => row.requestId === body.requestId);
    if (previous) {
      if (previous.requestHash !== requestHash) throw new RelayError('EnrollmentConflict', 409);
      // Resposta de uma geração antiga não pode reinstalar o certificado antigo.
      const current = this.document.devices.find((row) => row.agentId === body.agentId);
      if (current.revokedAt !== null) throw new RelayError('DeviceRevoked', 403);
      if (current.certificateSha256 !== previous.result.certificateSha256) throw new RelayError('EnrollmentSuperseded', 409);
      return copy(previous.result);
    }
    if (this.document.renewals.some((row) => row.requestId === body.requestId)) throw new RelayError('EnrollmentConflict', 409);
    const current = this.document.devices.find((row) => row.agentId === body.agentId);
    if (current && current.revokedAt !== null) throw new RelayError('DeviceRevoked', 403);
    if ((current ? current.certificateSha256 : null) !== body.previousCertificateSha256 || (current && current.repeaterId !== body.repeaterId) || this.document.devices.some((row) => row.agentId !== body.agentId && row.repeaterId === body.repeaterId)) throw new RelayError('DeviceEnrollmentConflict', 409);
    if (!current && this.document.devices.length >= 1024) throw new RelayError('EnrollmentCapacity', 503);
    this.canInstall({ agentId: body.agentId, repeaterId: body.repeaterId }, body.previousCertificateSha256, false);
    const issued = this.issuer.sign(body.csrPem, body.agentId);
    const binding = { agentId: body.agentId, repeaterId: body.repeaterId, ...issued, revokedAt: null, password: current?.password || Array.from({ length: 8 }, () => String.fromCharCode(crypto.randomInt(33, 127))).join('') };
    const result = { requestId: body.requestId, agentId: body.agentId, repeaterId: body.repeaterId, ...issued };
    const next = { ...this.document, devices: [...this.document.devices.filter((row) => row.agentId !== body.agentId), binding], requests: [...this.document.requests, { requestId: body.requestId, requestHash, result }] };
    this.save(next);
    try { this.install(binding); }
    catch { this.healthy = false; this.onFailure(); throw new RelayError('DeviceBindingUnavailable', 503); }
    return copy(result);
  }

  currentDevice(agentId, repeaterId) {
    if (!this.healthy) throw new RelayError('EnrollmentUnavailable', 503);
    const current = this.document.devices.find((row) => row.agentId === agentId);
    if (!current) throw new RelayError('DeviceNotFound', 404);
    if (current.revokedAt !== null) throw new RelayError('DeviceRevoked', 403);
    if (current.repeaterId !== repeaterId) throw new RelayError('DeviceEnrollmentConflict', 409);
    return current;
  }

  renewalResult(row) { return copy({ ...row.result, state: row.state }); }

  prepareRenewal(body) {
    if (!this.healthy) throw new RelayError('EnrollmentUnavailable', 503);
    exact(body, ['requestId', 'agentId', 'repeaterId', 'csrPem', 'previousCertificateSha256', 'requestedAt']);
    if (!UUID.test(body.requestId) || !UUID.test(body.agentId) || typeof body.repeaterId !== 'string' || !REPEATER.test(body.repeaterId) || typeof body.csrPem !== 'string' || Buffer.byteLength(body.csrPem) > 4096 || !HASH.test(body.previousCertificateSha256) || !canonicalDate(body.requestedAt)) throw new RelayError('InvalidRenewal');
    const input = { requestId: body.requestId, agentId: body.agentId, repeaterId: body.repeaterId, csrPem: body.csrPem, previousCertificateSha256: body.previousCertificateSha256, requestedAt: body.requestedAt };
    const requestHash = crypto.createHash('sha256').update(JSON.stringify(input)).digest('hex');
    const current = this.currentDevice(body.agentId, body.repeaterId);
    const previous = this.document.renewals.find((row) => row.requestId === body.requestId);
    if (previous) {
      if (previous.requestHash !== requestHash) throw new RelayError('RenewalConflict', 409);
      if (previous.state === 'aborted') throw new RelayError('RenewalAborted', 409);
      if (previous.state === 'committed') {
        if (current.certificateSha256 !== previous.result.certificateSha256) throw new RelayError('RenewalSuperseded', 409);
      } else {
        if (current.certificateSha256 !== body.previousCertificateSha256) throw new RelayError('RenewalSuperseded', 409);
        if (Date.parse(previous.result.preparedUntil) <= this.now()) throw new RelayError('RenewalExpired', 409);
      }
      return this.renewalResult(previous);
    }
    if (this.document.requests.some((row) => row.requestId === body.requestId)) throw new RelayError('RenewalConflict', 409);
    const age = this.now() - Date.parse(body.requestedAt);
    if (age < -30000 || age > RENEWAL_REQUEST_MS) throw new RelayError('RenewalRequestExpired', 409);
    if (current.certificateSha256 !== body.previousCertificateSha256) throw new RelayError('DeviceEnrollmentConflict', 409);
    if (Date.parse(current.expiresAt) <= this.now()) throw new RelayError('DeviceCertificateExpired', 403);
    const next = this.compact(copy(this.document));
    if (next.renewals.some((row) => row.input.agentId === body.agentId && row.state === 'prepared')) throw new RelayError('RenewalAlreadyPending', 409);
    if (next.renewals.length >= 4096) throw new RelayError('EnrollmentCapacity', 503);
    this.canInstall(current, body.previousCertificateSha256, false);
    const issued = this.issuer.sign(body.csrPem, body.agentId);
    if (issued.certificateSha256 === body.previousCertificateSha256 || Date.parse(issued.expiresAt) <= this.now()) throw new RelayError('InvalidIssuedCertificate', 503);
    this.canInstall({ ...current, ...issued }, body.previousCertificateSha256, false);
    const result = { requestId: body.requestId, agentId: body.agentId, repeaterId: body.repeaterId, previousCertificateSha256: body.previousCertificateSha256, ...issued, preparedUntil: new Date(this.now() + RENEWAL_PREPARE_MS).toISOString() };
    const row = { requestId: body.requestId, requestHash, input, result, state: 'prepared' };
    next.renewals.push(row); this.save(next);
    // O vínculo antigo continua aceito até o commit; não há instalação nesta fase.
    return this.renewalResult(row);
  }

  renewalOperation(requestId, body, allowUnknownCertificate = false) {
    if (!this.healthy) throw new RelayError('EnrollmentUnavailable', 503);
    exact(body, ['agentId', 'repeaterId', 'previousCertificateSha256', 'certificateSha256']);
    if (!UUID.test(requestId) || !UUID.test(body.agentId) || typeof body.repeaterId !== 'string' || !REPEATER.test(body.repeaterId) || !HASH.test(body.previousCertificateSha256) || !(HASH.test(body.certificateSha256) || (allowUnknownCertificate && body.certificateSha256 === null))) throw new RelayError('InvalidRenewal');
    const current = this.currentDevice(body.agentId, body.repeaterId);
    const row = this.document.renewals.find((value) => value.requestId === requestId);
    if (!row) throw new RelayError('RenewalNotFound', 404);
    if (row.input.agentId !== body.agentId || row.input.repeaterId !== body.repeaterId || row.input.previousCertificateSha256 !== body.previousCertificateSha256 || (body.certificateSha256 !== null && row.result.certificateSha256 !== body.certificateSha256)) throw new RelayError('RenewalConflict', 409);
    const expected = row.state === 'committed' ? row.result.certificateSha256 : row.input.previousCertificateSha256;
    if (current.certificateSha256 !== expected) throw new RelayError('RenewalSuperseded', 409);
    return { current, row };
  }

  renewalStatus(requestId, body) {
    const { row } = this.renewalOperation(requestId, body, true);
    if (row.state === 'prepared' && Date.parse(row.result.preparedUntil) <= this.now()) throw new RelayError('RenewalExpired', 409);
    return this.renewalResult(row);
  }

  commitRenewal(requestId, body) {
    const { current, row } = this.renewalOperation(requestId, body);
    if (row.state === 'committed') return this.renewalResult(row);
    if (row.state === 'aborted') throw new RelayError('RenewalAborted', 409);
    if (Date.parse(row.result.preparedUntil) <= this.now()) throw new RelayError('RenewalExpired', 409);
    if (Date.parse(current.expiresAt) <= this.now() || Date.parse(row.result.expiresAt) <= this.now()) throw new RelayError('DeviceCertificateExpired', 403);
    const { certificatePem, certificateSha256, expiresAt } = row.result;
    const binding = { ...current, certificatePem, certificateSha256, expiresAt };
    this.canInstall(binding, body.previousCertificateSha256, false);
    const next = copy(this.document);
    next.devices = next.devices.map((value) => value.agentId === body.agentId ? binding : value);
    const committed = next.renewals.find((value) => value.requestId === requestId); committed.state = 'committed';
    this.save(next);
    try { this.install(binding); }
    catch { this.healthy = false; this.onFailure(); throw new RelayError('DeviceBindingUnavailable', 503); }
    return this.renewalResult(committed);
  }

  abortRenewal(requestId, body) {
    const { row } = this.renewalOperation(requestId, body, true);
    if (row.state === 'committed') throw new RelayError('RenewalAlreadyCommitted', 409);
    if (row.state !== 'aborted') {
      const next = copy(this.document); next.renewals.find((value) => value.requestId === requestId).state = 'aborted'; this.save(next);
    }
    return { requestId, agentId: body.agentId, state: 'aborted' };
  }

  provisionProfile(body) {
    if (!this.healthy) throw new RelayError('EnrollmentUnavailable', 503);
    exact(body, ['agentId', 'repeaterId', 'certificateSha256']);
    if (!UUID.test(body.agentId) || typeof body.repeaterId !== 'string' || !REPEATER.test(body.repeaterId) || !HASH.test(body.certificateSha256)) throw new RelayError('InvalidDeviceProfile');
    const current = this.currentDevice(body.agentId, body.repeaterId);
    if (current.certificateSha256 !== body.certificateSha256) throw new RelayError('DeviceEnrollmentConflict', 409);
    if (Date.parse(current.expiresAt) <= this.now()) throw new RelayError('DeviceCertificateExpired', 403);
    return { agentId: current.agentId, repeaterId: current.repeaterId, certificateSha256: current.certificateSha256, vncPassword: current.password, expiresAt: current.expiresAt };
  }

  revoke(agentId) {
    if (!this.healthy) throw new RelayError('EnrollmentUnavailable', 503);
    if (!UUID.test(agentId)) throw new RelayError('InvalidAgentId');
    const current = this.document.devices.find((row) => row.agentId === agentId);
    if (!current) throw new RelayError('DeviceNotFound', 404);
    if (current.revokedAt === null) {
      const next = copy(this.document); next.devices.find((row) => row.agentId === agentId).revokedAt = new Date(this.now()).toISOString(); this.save(next);
    }
    try { this.remove(agentId); }
    catch { this.healthy = false; this.onFailure(); throw new RelayError('DeviceBindingUnavailable', 503); }
    return { agentId, revoked: true };
  }

  stop() {
    if (this.healthy && this.locked) { fs.unlinkSync(`${this.journal}.lock`); this.locked = false; }
  }
}

module.exports = { CertificateIssuer, DeviceEnrollment, initializeEnrollmentState };
