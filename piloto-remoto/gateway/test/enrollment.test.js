'use strict';

const assert = require('node:assert/strict');
const { test, before, after } = require('node:test');
const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { execFileSync } = require('node:child_process');
const { CertificateIssuer, DeviceEnrollment, initializeEnrollmentState } = require('../enrollment');

let directory; let issuer; let csr;
const opensslPath = process.env.OPENSSL || (process.platform === 'darwin' ? execFileSync('/usr/bin/which', ['openssl'], { encoding: 'utf8' }).trim() : '/usr/bin/openssl');
const agentId = '0249a001-0000-4000-8000-000000000001';
const agent2 = '0249a002-0000-4000-8000-000000000002';
const read = (name) => fs.readFileSync(path.join(directory, name), 'utf8');
const openssl = (...args) => execFileSync(opensslPath, args, { cwd: directory, stdio: 'ignore' });
const request = (overrides = {}) => ({ requestId: crypto.randomUUID(), agentId, repeaterId: '490001', csrPem: csr, previousCertificateSha256: null, ...overrides });
const authorityOptions = () => ({ enabled: true, openssl: opensslPath, caPrivateKeyFile: path.join(directory, 'issuing-ca.key'), caCertificateFile: path.join(directory, 'issuing-ca.crt'), deviceCaPem: read('device-ca.crt'), validityDays: 1 });

before(() => {
  directory = fs.mkdtempSync(path.join(os.tmpdir(), 'pdv-enrollment-synthetic-')); fs.chmodSync(directory, 0o700);
  openssl('req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-keyout', 'device-ca.key', '-out', 'device-ca.crt', '-days', '3', '-subj', '/CN=synthetic-device-ca', '-addext', 'basicConstraints=critical,CA:TRUE,pathlen:1');
  openssl('req', '-newkey', 'rsa:2048', '-nodes', '-sha256', '-keyout', 'issuing-ca.key', '-out', 'issuing-ca.csr', '-subj', '/CN=synthetic-issuing-ca');
  fs.writeFileSync(path.join(directory, 'issuing-ca.ext'), 'basicConstraints=critical,CA:TRUE,pathlen:0\nkeyUsage=critical,keyCertSign,cRLSign\n');
  openssl('x509', '-req', '-in', 'issuing-ca.csr', '-CA', 'device-ca.crt', '-CAkey', 'device-ca.key', '-set_serial', '0x123456', '-days', '2', '-sha256', '-extfile', 'issuing-ca.ext', '-out', 'issuing-ca.crt');
  for (const name of ['device-ca.key', 'device-ca.crt', 'issuing-ca.key', 'issuing-ca.crt']) fs.chmodSync(path.join(directory, name), 0o600);
  openssl('req', '-newkey', 'rsa:2048', '-nodes', '-sha256', '-keyout', 'client.key', '-out', 'client.csr', '-subj', `/CN=pdv-${agentId}`, '-addext', 'basicConstraints=critical,CA:TRUE', '-addext', 'extendedKeyUsage=serverAuth');
  csr = read('client.csr'); issuer = new CertificateIssuer(authorityOptions());
});
after(() => fs.rmSync(directory, { recursive: true, force: true }));
const fixture = (t, overrides = {}) => {
  const stateDirectory = fs.mkdtempSync(path.join(directory, 'state-')); fs.chmodSync(stateDirectory, 0o700);
  const journal = path.join(stateDirectory, 'devices.json'); initializeEnrollmentState(journal, '--gateway-stopped');
  const installed = new Map(); let failed = false;
  const options = { enabled: true, journal, issuer, canInstall: () => {}, install: (value) => installed.set(value.agentId, value), revoke: (id) => installed.delete(id), failClosed: () => { failed = true; }, ...overrides };
  const enrollment = new DeviceEnrollment(options); t.after(() => enrollment.stop());
  return { enrollment, journal, options, installed, failed: () => failed };
};

test('emissor rejeita CA/issuer desabilitado, autoridade divergente e lifetime excessivo', () => {
  assert.throws(() => new CertificateIssuer({ ...authorityOptions(), enabled: false }), /EnrollmentIssuerDisabled/);
  assert.throws(() => new CertificateIssuer({ ...authorityOptions(), validityDays: 91 }), /InvalidCertificateLifetime/);
  assert.throws(() => new CertificateIssuer({ ...authorityOptions(), caCertificateFile: path.join(directory, 'device-ca.crt'), caPrivateKeyFile: path.join(directory, 'device-ca.key') }), /InvalidDeviceIssuingAuthority/);
  assert.throws(() => new CertificateIssuer({ ...authorityOptions(), deviceCaPem: 'invalid' }), /InvalidDeviceIssuingAuthority/);
  fs.chmodSync(path.join(directory, 'issuing-ca.key'), 0o644);
  assert.throws(() => new CertificateIssuer(authorityOptions()), /InvalidDeviceIssuingAuthority/);
  fs.chmodSync(path.join(directory, 'issuing-ca.key'), 0o600);
  openssl('req', '-x509', '-key', 'device-ca.key', '-out', 'root-pathlen0.crt', '-days', '3', '-subj', '/CN=synthetic-device-ca', '-addext', 'basicConstraints=critical,CA:TRUE,pathlen:0');
  assert.throws(() => new CertificateIssuer({ ...authorityOptions(), deviceCaPem: read('root-pathlen0.crt') }), /InvalidDeviceIssuingAuthority/);
});

test('CSR assinado prova posse; certificado ignora CA/serverAuth solicitados, mantém chave e identifica agentId', () => {
  const issued = issuer.sign(csr, agentId); const cert = new crypto.X509Certificate(issued.certificatePem);
  assert.equal(cert.ca, false); assert.equal(cert.subject, `CN=pdv-${agentId}`);
  assert.deepEqual(cert.keyUsage, ['1.3.6.1.5.5.7.3.2']);
  assert.equal(cert.subjectAltName, undefined);
  assert.ok(cert.checkPrivateKey(crypto.createPrivateKey(read('client.key'))));
  assert.equal(issued.certificateSha256.length, 64);
  assert.equal(issued.certificatePem.match(/BEGIN CERTIFICATE/g).length, 2);
  const chain = issued.certificatePem.match(/-----BEGIN CERTIFICATE-----[\s\S]+?-----END CERTIFICATE-----/g);
  assert.ok(cert.verify(new crypto.X509Certificate(chain[1]).publicKey));
  assert.ok(new crypto.X509Certificate(chain[1]).verify(new crypto.X509Certificate(read('device-ca.crt')).publicKey));
  assert.throws(() => issuer.sign(csr, agent2), /InvalidCertificateRequest/);
  assert.throws(() => issuer.sign(csr + read('client.key'), agentId), /InvalidCertificateRequest/);
  assert.throws(() => issuer.sign('x'.repeat(4097), agentId), /InvalidCertificateRequest/);
  const corrupted = csr.replace(/\n([A-Za-z0-9])/, (_match, c) => `\n${c === 'A' ? 'B' : 'A'}`);
  assert.throws(() => issuer.sign(corrupted, agentId), /InvalidCertificateRequest/);
});

test('CSR com RSA1024 ou SHA1 é rejeitado', () => {
  openssl('req', '-newkey', 'ec', '-pkeyopt', 'ec_paramgen_curve:P-256', '-nodes', '-sha256', '-keyout', 'ec.key', '-out', 'ec.csr', '-subj', `/CN=pdv-${agentId}`);
  assert.throws(() => issuer.sign(read('ec.csr'), agentId), /InvalidCertificateRequest/);
  for (const [name, bits, digest] of [['weak-key', '1024', '-sha256'], ['weak-signature', '2048', '-sha1']]) {
    openssl('req', '-newkey', `rsa:${bits}`, '-nodes', digest, '-keyout', `${name}.key`, '-out', `${name}.csr`, '-subj', `/CN=pdv-${agentId}`);
    assert.throws(() => issuer.sign(read(`${name}.csr`), agentId), /InvalidCertificateRequest/);
  }
});

test('primeiro cadastro persiste sem chave privada e sem senha na resposta; repetição sobrevive ao reinício', (t) => {
  const { enrollment, journal, options, installed } = fixture(t); const input = request(); const first = enrollment.enroll(input);
  assert.deepEqual(Object.keys(first).sort(), ['requestId', 'agentId', 'repeaterId', 'certificatePem', 'certificateSha256', 'expiresAt'].sort());
  assert.equal(first.password, undefined); assert.equal(first.privateKey, undefined);
  assert.equal(installed.get(agentId).password.length, 8);
  assert.ok(!fs.readFileSync(journal, 'utf8').includes('PRIVATE KEY'));
  assert.equal(fs.statSync(journal).mode & 0o077, 0);
  assert.deepEqual(enrollment.enroll({ ...input }), first);
  enrollment.stop(); installed.clear(); const restored = new DeviceEnrollment(options); t.after(() => restored.stop());
  assert.deepEqual(restored.enroll(input), first); assert.equal(installed.get(agentId).certificateSha256, first.certificateSha256);
});

test('idempotência divergente, fingerprints antigos, repetidor ocupado e payload não exato são rejeitados', (t) => {
  const { enrollment } = fixture(t); const input = request(); const first = enrollment.enroll(input);
  assert.throws(() => enrollment.enroll({ ...input, repeaterId: '490002' }), /EnrollmentConflict/);
  assert.throws(() => enrollment.enroll(request()), /DeviceEnrollmentConflict/);
  assert.throws(() => enrollment.enroll(request({ agentId: agent2 })), /DeviceEnrollmentConflict/);
  assert.throws(() => enrollment.enroll({ ...request(), extra: true }), /InvalidEnrollmentShape/);
  assert.throws(() => enrollment.enroll(request({ repeaterId: 490001 })), /InvalidEnrollment/);
  assert.throws(() => enrollment.enroll(request({ previousCertificateSha256: '0'.repeat(64) })), /DeviceEnrollmentConflict/);
  assert.equal(enrollment.document.devices[0].certificateSha256, first.certificateSha256);
});

test('renovação substitui fingerprint e não permite replay de geração antiga', (t) => {
  const { enrollment, installed } = fixture(t); const input = request(); const first = enrollment.enroll(input);
  const renewed = enrollment.enroll(request({ previousCertificateSha256: first.certificateSha256 }));
  assert.notEqual(renewed.certificateSha256, first.certificateSha256);
  assert.equal(installed.get(agentId).certificateSha256, renewed.certificateSha256);
  assert.throws(() => enrollment.enroll(input), /EnrollmentSuperseded/);
});

test('checagem de sessão ativa precede assinatura e escrita', (t) => {
  let signed = 0;
  const { enrollment, journal } = fixture(t, { issuer: { sign: () => { signed += 1; } }, canInstall: () => { throw new Error('DeviceBusy'); } });
  const before = fs.readFileSync(journal, 'utf8');
  assert.throws(() => enrollment.enroll(request()), /DeviceBusy/); assert.equal(signed, 0);
  assert.equal(fs.readFileSync(journal, 'utf8'), before);
});

test('revogação persiste tombstone, remove vínculo, é idempotente e impede novo cadastro/replay', (t) => {
  const { enrollment, journal, options, installed } = fixture(t); const input = request(); enrollment.enroll(input);
  assert.deepEqual(enrollment.revoke(agentId), { agentId, revoked: true }); assert.equal(installed.size, 0);
  assert.deepEqual(enrollment.revoke(agentId), { agentId, revoked: true });
  assert.throws(() => enrollment.enroll(input), /DeviceRevoked/); assert.throws(() => enrollment.enroll(request()), /DeviceRevoked/);
  assert.throws(() => enrollment.revoke(agent2), /DeviceNotFound/);
  assert.ok(JSON.parse(fs.readFileSync(journal)).devices[0].revokedAt);
  enrollment.stop(); const restored = new DeviceEnrollment(options); t.after(() => restored.stop());
  assert.equal(installed.size, 0); assert.throws(() => restored.enroll(input), /DeviceRevoked/);
});

test('falha ao persistir ou instalar bloqueia todas as novas operações e mantém lock para manutenção', (t) => {
  const { enrollment, journal, failed } = fixture(t);
  fs.renameSync(path.dirname(journal), `${path.dirname(journal)}-moved`);
  assert.throws(() => enrollment.enroll(request()), /EnrollmentStateUnavailable/); assert.equal(failed(), true);
  assert.throws(() => enrollment.enroll(request()), /EnrollmentUnavailable/);
  const second = fixture(t, { install: () => { throw new Error('Unavailable'); } });
  assert.throws(() => second.enrollment.enroll(request()), /DeviceBindingUnavailable/); assert.equal(second.failed(), true);
  assert.equal(JSON.parse(fs.readFileSync(second.journal)).devices.length, 1);
  assert.throws(() => second.enrollment.revoke(agentId), /EnrollmentUnavailable/);
});

test('segundo escritor e estado inseguro são rejeitados; inicialização nunca sobrescreve estado', (t) => {
  const { journal, options, enrollment } = fixture(t);
  assert.throws(() => new DeviceEnrollment(options), /EEXIST/);
  assert.throws(() => initializeEnrollmentState(journal, '--gateway-stopped'), /EEXIST/);
  assert.throws(() => initializeEnrollmentState(journal, ''), /OfflineEnrollmentInitializationRequired/);
  enrollment.stop(); fs.chmodSync(journal, 0o644);
  assert.throws(() => new DeviceEnrollment(options), /ProtectedEnrollmentFileRequired/);
});

const renewalRequest = (first, overrides = {}) => request({ previousCertificateSha256: first.certificateSha256, requestedAt: new Date().toISOString(), ...overrides });
const confirmation = (value, overrides = {}) => ({ agentId: value.agentId, repeaterId: value.repeaterId, previousCertificateSha256: value.previousCertificateSha256, certificateSha256: value.certificateSha256, ...overrides });

test('preparação é durável, mantém identidade antiga, recupera resposta perdida e commit é idempotente', (t) => {
  const { enrollment, journal, options, installed } = fixture(t);
  const first = enrollment.enroll(request()); const oldPassword = installed.get(agentId).password;
  const input = renewalRequest(first); const prepared = enrollment.prepareRenewal(input);
  assert.equal(prepared.state, 'prepared'); assert.equal(prepared.previousCertificateSha256, first.certificateSha256);
  assert.notEqual(prepared.certificateSha256, first.certificateSha256);
  assert.equal(installed.get(agentId).certificateSha256, first.certificateSha256);
  assert.equal(enrollment.document.devices[0].certificateSha256, first.certificateSha256);
  assert.equal(prepared.password, undefined); assert.equal(prepared.privateKey, undefined);
  assert.ok(!fs.readFileSync(journal, 'utf8').includes('PRIVATE KEY'));
  assert.deepEqual(enrollment.prepareRenewal({ ...input }), prepared);
  enrollment.stop(); installed.clear(); const restored = new DeviceEnrollment(options); t.after(() => restored.stop());
  assert.deepEqual(restored.prepareRenewal(input), prepared);
  assert.deepEqual(restored.renewalStatus(input.requestId, confirmation(prepared, { certificateSha256: null })), prepared);
  assert.throws(() => restored.commitRenewal(input.requestId, confirmation(prepared, { certificateSha256: null })), /InvalidRenewal/);
  assert.equal(installed.get(agentId).certificateSha256, first.certificateSha256);
  const committed = restored.commitRenewal(input.requestId, confirmation(prepared));
  assert.equal(committed.state, 'committed'); assert.equal(installed.get(agentId).certificateSha256, prepared.certificateSha256);
  assert.equal(installed.get(agentId).password, oldPassword);
  assert.deepEqual(restored.commitRenewal(input.requestId, confirmation(prepared)), committed);
  assert.deepEqual(restored.prepareRenewal(input), committed);
  assert.deepEqual(restored.renewalStatus(input.requestId, confirmation(prepared)), committed);
  restored.stop(); const afterLostReply = new DeviceEnrollment(options); t.after(() => afterLostReply.stop());
  assert.deepEqual(afterLostReply.commitRenewal(input.requestId, confirmation(prepared)), committed);
  assert.equal(afterLostReply.document.schemaVersion, 2);
});

test('renovação exige forma exata, vínculo atual, timestamp curto, CAS e uma proposta por computador', (t) => {
  const { enrollment } = fixture(t); const first = enrollment.enroll(request());
  assert.throws(() => enrollment.prepareRenewal({ ...renewalRequest(first), extra: true }), /InvalidEnrollmentShape/);
  assert.throws(() => enrollment.prepareRenewal(renewalRequest(first, { previousCertificateSha256: null })), /InvalidRenewal/);
  assert.throws(() => enrollment.prepareRenewal(renewalRequest(first, { previousCertificateSha256: '0'.repeat(64) })), /DeviceEnrollmentConflict/);
  assert.throws(() => enrollment.prepareRenewal(renewalRequest(first, { requestedAt: new Date(Date.now() - 301000).toISOString() })), /RenewalRequestExpired/);
  assert.throws(() => enrollment.prepareRenewal(renewalRequest(first, { requestedAt: new Date(Date.now() + 31000).toISOString() })), /RenewalRequestExpired/);
  assert.throws(() => enrollment.prepareRenewal(renewalRequest(first, { requestedAt: '2026-01-01' })), /InvalidRenewal/);
  const input = renewalRequest(first); const prepared = enrollment.prepareRenewal(input);
  assert.throws(() => enrollment.prepareRenewal({ ...input, csrPem: `${csr}\n` }), /RenewalConflict/);
  assert.throws(() => enrollment.prepareRenewal(renewalRequest(first)), /RenewalAlreadyPending/);
  assert.throws(() => enrollment.commitRenewal(input.requestId, confirmation(prepared, { certificateSha256: 'f'.repeat(64) })), /RenewalConflict/);
  assert.throws(() => enrollment.commitRenewal(input.requestId, { ...confirmation(prepared), extra: true }), /InvalidEnrollmentShape/);
  assert.throws(() => enrollment.enroll(request({ requestId: input.requestId, previousCertificateSha256: first.certificateSha256 })), /EnrollmentConflict/);
});

test('lease ativa bloqueia preparação e commit sem escrita ou troca de identidade', (t) => {
  let busy = false; let signed = 0;
  const { enrollment, journal, installed } = fixture(t, { issuer: { sign: (...args) => { signed += 1; return issuer.sign(...args); } }, canInstall: () => { if (busy) throw new Error('DeviceBusy'); } });
  const first = enrollment.enroll(request()); const before = fs.readFileSync(journal, 'utf8'); const initialSigned = signed;
  busy = true; assert.throws(() => enrollment.prepareRenewal(renewalRequest(first)), /DeviceBusy/);
  assert.equal(signed, initialSigned); assert.equal(fs.readFileSync(journal, 'utf8'), before);
  busy = false; const prepared = enrollment.prepareRenewal(renewalRequest(first)); const staged = fs.readFileSync(journal, 'utf8');
  busy = true; assert.throws(() => enrollment.commitRenewal(prepared.requestId, confirmation(prepared)), /DeviceBusy/);
  assert.equal(fs.readFileSync(journal, 'utf8'), staged); assert.equal(installed.get(agentId).certificateSha256, first.certificateSha256);
  busy = false; enrollment.commitRenewal(prepared.requestId, confirmation(prepared));
  assert.equal(installed.get(agentId).certificateSha256, prepared.certificateSha256);
});

test('proposta expira sem trocar vínculo, cancelamento mantém identidade e timestamp impede replay compactado', (t) => {
  let now = Date.now() - 12 * 3600000;
  const { enrollment, installed } = fixture(t, { now: () => now }); const first = enrollment.enroll(request());
  const input = renewalRequest(first, { requestedAt: new Date(now).toISOString() }); const prepared = enrollment.prepareRenewal(input);
  now += 6 * 60000; assert.deepEqual(enrollment.prepareRenewal(input), prepared); // Retry de resposta perdida não usa o prazo inicial de cinco minutos.
  now += 24 * 3600000;
  assert.throws(() => enrollment.commitRenewal(input.requestId, confirmation(prepared)), /RenewalExpired/);
  assert.throws(() => enrollment.prepareRenewal(input), /RenewalExpired/);
  assert.equal(installed.get(agentId).certificateSha256, first.certificateSha256);
  assert.deepEqual(enrollment.abortRenewal(input.requestId, confirmation(prepared)), { requestId: input.requestId, agentId, state: 'aborted' });
  assert.equal(enrollment.document.renewals.length, 0); // Expirados já podem ser compactados.
  assert.throws(() => enrollment.prepareRenewal(input), /RenewalRequestExpired/);
  const fresh = enrollment.prepareRenewal(renewalRequest(first, { requestedAt: new Date(now).toISOString() }));
  assert.equal(fresh.state, 'prepared'); assert.equal(installed.get(agentId).certificateSha256, first.certificateSha256);
});

test('cancelamento é idempotente, não confirma e commit confirmado nunca pode ser desfeito', (t) => {
  const { enrollment } = fixture(t); const first = enrollment.enroll(request()); const prepared = enrollment.prepareRenewal(renewalRequest(first));
  const expected = { requestId: prepared.requestId, agentId, state: 'aborted' };
  assert.deepEqual(enrollment.abortRenewal(prepared.requestId, confirmation(prepared, { certificateSha256: null })), expected);
  assert.deepEqual(enrollment.abortRenewal(prepared.requestId, confirmation(prepared)), expected);
  assert.throws(() => enrollment.commitRenewal(prepared.requestId, confirmation(prepared)), /RenewalAborted/);
  assert.throws(() => enrollment.prepareRenewal(renewalRequest(first, { requestId: prepared.requestId })), /RenewalConflict|RenewalAborted/);
  const next = enrollment.prepareRenewal(renewalRequest(first)); enrollment.commitRenewal(next.requestId, confirmation(next));
  assert.throws(() => enrollment.abortRenewal(next.requestId, confirmation(next)), /RenewalAlreadyCommitted/);
});

test('perfil interno requer fingerprint atual, preserva senha após renovação e revogação invalida toda proposta', (t) => {
  const { enrollment, options } = fixture(t); const first = enrollment.enroll(request());
  const profileInput = { agentId, repeaterId: first.repeaterId, certificateSha256: first.certificateSha256 };
  const profile = enrollment.provisionProfile(profileInput); assert.equal(profile.vncPassword.length, 8);
  const prepared = enrollment.prepareRenewal(renewalRequest(first));
  assert.throws(() => enrollment.provisionProfile({ ...profileInput, certificateSha256: prepared.certificateSha256 }), /DeviceEnrollmentConflict/);
  enrollment.commitRenewal(prepared.requestId, confirmation(prepared));
  const renewedProfile = enrollment.provisionProfile({ ...profileInput, certificateSha256: prepared.certificateSha256 });
  assert.equal(renewedProfile.vncPassword, profile.vncPassword);
  assert.throws(() => enrollment.provisionProfile(profileInput), /DeviceEnrollmentConflict/);
  const nextInput = renewalRequest(prepared); const next = enrollment.prepareRenewal(nextInput); enrollment.revoke(agentId);
  assert.throws(() => enrollment.prepareRenewal(nextInput), /DeviceRevoked/);
  assert.throws(() => enrollment.commitRenewal(next.requestId, confirmation(next)), /DeviceRevoked/);
  assert.throws(() => enrollment.provisionProfile({ ...profileInput, certificateSha256: prepared.certificateSha256 }), /DeviceRevoked/);
  assert.equal(enrollment.document.renewals.length, 0); assert.ok(enrollment.document.devices[0].revokedAt);
  enrollment.stop(); const restored = new DeviceEnrollment(options); t.after(() => restored.stop());
  assert.throws(() => restored.commitRenewal(next.requestId, confirmation(next)), /DeviceRevoked/);
});

test('certificado vencido não renova nem fornece perfil e falha de instalação no commit fecha o gateway', (t) => {
  let now = Date.now(); let fail = false;
  const { enrollment, installed, failed, journal } = fixture(t, { now: () => now, install: (value) => { if (fail) throw new Error('Unavailable'); installed.set(value.agentId, value); } });
  const first = enrollment.enroll(request()); const prepared = enrollment.prepareRenewal(renewalRequest(first));
  now = Date.parse(first.expiresAt) + 1;
  assert.throws(() => enrollment.provisionProfile({ agentId, repeaterId: first.repeaterId, certificateSha256: first.certificateSha256 }), /DeviceCertificateExpired/);
  assert.throws(() => enrollment.prepareRenewal(renewalRequest(first, { requestedAt: new Date(now).toISOString() })), /DeviceCertificateExpired/);
  now = Date.now(); fail = true;
  assert.throws(() => enrollment.commitRenewal(prepared.requestId, confirmation(prepared)), /DeviceBindingUnavailable/);
  assert.equal(failed(), true); assert.equal(JSON.parse(fs.readFileSync(journal)).devices[0].certificateSha256, prepared.certificateSha256);
  assert.throws(() => enrollment.provisionProfile({ agentId, repeaterId: first.repeaterId, certificateSha256: first.certificateSha256 }), /EnrollmentUnavailable/);
  assert.ok(fs.existsSync(`${journal}.lock`));
});

test('compactação conserva mil identidades e tombstones, propostas vivas e resultados atuais sem acumular gerações', (t) => {
  const { enrollment } = fixture(t); const now = Date.now(); const devices = []; const requests = []; const renewals = [];
  for (let index = 0; index < 1000; index += 1) {
    const id = `0249a001-0000-4000-8000-${String(index).padStart(12, '0')}`;
    const currentHash = crypto.createHash('sha256').update(`current-${index}`).digest('hex');
    devices.push({ agentId: id, certificateSha256: currentHash, revokedAt: index === 999 ? new Date(now).toISOString() : null });
    for (let generation = 0; generation < 10; generation += 1) {
      requests.push({ requestId: crypto.randomUUID(), result: { agentId: id, certificateSha256: generation === 9 ? currentHash : 'old' } });
      renewals.push({ requestId: crypto.randomUUID(), input: { agentId: id, previousCertificateSha256: 'old' }, result: { certificateSha256: generation === 9 ? currentHash : 'old', preparedUntil: new Date(now - 1).toISOString() }, state: 'committed' });
    }
    renewals.push({ requestId: crypto.randomUUID(), input: { agentId: id, previousCertificateSha256: currentHash }, result: { preparedUntil: new Date(now + 60000).toISOString() }, state: 'prepared' });
  }
  const result = enrollment.compact({ schemaVersion: 2, devices, requests, renewals });
  assert.equal(result.devices.length, 1000); assert.ok(result.devices[999].revokedAt);
  assert.equal(result.requests.length, 1998); assert.equal(result.renewals.length, 1998);
  assert.equal(result.renewals.filter((row) => row.state === 'prepared').length, 999);
  assert.equal(result.renewals.filter((row) => row.state === 'committed').length, 999);
});
