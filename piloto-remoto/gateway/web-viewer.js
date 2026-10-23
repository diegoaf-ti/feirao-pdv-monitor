'use strict';

const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const http = require('node:http');
const https = require('node:https');
const { RelayError } = require('./relay');

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
const SECRET = /^[A-Za-z0-9_-]{43}$/;
const digest = (value) => crypto.createHash('sha256').update(value).digest('hex');
const random = () => crypto.randomBytes(32).toString('base64url');
const origin = (value) => { const url = new URL(value); if (url.protocol !== 'https:' || url.origin !== value) throw new RelayError('ViewerOriginInvalid'); return url; };
const exact = (object, keys) => { if (!object || typeof object !== 'object' || Array.isArray(object) || Object.keys(object).length !== keys.length || keys.some((key) => !Object.hasOwn(object, key))) throw new RelayError('InvalidViewerShape'); };
const body = async (request, maximum = 4096) => {
  if (request.headers['content-encoding']) throw new RelayError('UnsupportedEncoding', 415);
  const chunks = []; let length = 0;
  for await (const chunk of request) { length += chunk.length; if (length > maximum) throw new RelayError('BodyTooLarge', 413); chunks.push(chunk); }
  return Buffer.concat(chunks);
};
const form = (buffer) => {
  const params = new URLSearchParams(buffer.toString('utf8')); const result = {};
  for (const [key, value] of params) { if (Object.hasOwn(result, key)) throw new RelayError('DuplicateField'); result[key] = value; }
  return result;
};
const securityHeaders = (response) => {
  response.setHeader('Cache-Control', 'no-store, private'); response.setHeader('Pragma', 'no-cache');
  response.setHeader('Referrer-Policy', 'no-referrer'); response.setHeader('X-Content-Type-Options', 'nosniff');
  response.setHeader('X-Frame-Options', 'DENY'); response.setHeader('Cross-Origin-Opener-Policy', 'same-origin');
  response.setHeader('Content-Security-Policy', "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self' data: blob:; font-src 'none'; media-src 'none'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'; object-src 'none'");
  response.setHeader('Permissions-Policy', 'camera=(), microphone=(), geolocation=(), clipboard-read=(), clipboard-write=()');
};
const send = (response, status, content, type = 'application/json; charset=utf-8') => {
  response.writeHead(status, { 'Content-Type': type }); response.end(type.startsWith('application/json') ? JSON.stringify(content) : content);
};

// No bearer, senha VNC ou authToken chega ao JavaScript da página.
// O cookie é exclusivo deste atendimento; o token HTTP do túnel é substituído.
const createWebViewer = ({ relay, config, now = Date.now }) => {
  const publicUrl = origin(config.publicOrigin); const conectaUrl = origin(config.conectaOrigin);
  const upstream = new URL(config.guacamoleUrl);
  const localHttp = config.allowPrivateHttp === true && ['guacamole', '127.0.0.1', 'localhost', '[::1]'].includes(upstream.hostname);
  if ((upstream.protocol !== 'https:' && !(upstream.protocol === 'http:' && localHttp)) || upstream.username || upstream.password || upstream.search || upstream.hash || !upstream.pathname.endsWith('/') || !/^[a-f0-9]{32}$/.test(config.jsonKey || '') || !/^[a-f0-9]{64}$/.test(config.commonJsSha256 || '')) throw new RelayError('ViewerConfigurationInvalid');
  const key = Buffer.from(config.jsonKey, 'hex'); const tickets = new Map(); const sessions = new Map(); const closedSessions = new Map();
  const assets = { 'viewer.js': fs.readFileSync(path.join(__dirname, 'viewer-client.js')), 'viewer.css': fs.readFileSync(path.join(__dirname, 'viewer.css')), 'open.js': fs.readFileSync(path.join(__dirname, 'viewer-open.js')) };
  const pendingRequests = new Set();
  let library = null; let libraryPending = null; let stopping = false;
  const endpoint = (relative) => new URL(relative, upstream);
  const upstreamRequest = (method, relative, data, headers = {}, timeout = 10000) => {
    const url = endpoint(relative); const transport = url.protocol === 'https:' ? https : http;
    return transport.request(url, { method, agent: false, timeout, rejectUnauthorized: true, ...(config.upstreamCa ? { ca: config.upstreamCa } : {}), headers: { ...headers, ...(data !== undefined ? { 'Content-Length': Buffer.byteLength(data) } : {}) } });
  };
  const buffered = (method, relative, data, maximum = 16384, headers = {}, owner = null) => new Promise((resolve, reject) => {
    const request = upstreamRequest(method, relative, data, headers); const chunks = []; let length = 0;
    pendingRequests.add(request); owner?.requests.add(request);
    const deadline = setTimeout(() => request.destroy(), 10000); deadline.unref();
    const cleanup = () => { clearTimeout(deadline); pendingRequests.delete(request); owner?.requests.delete(request); };
    request.once('response', (response) => {
      response.on('data', (chunk) => { length += chunk.length; if (length > maximum) response.destroy(new Error('limit')); else chunks.push(chunk); });
      response.once('error', () => { cleanup(); reject(new RelayError('ViewerUpstreamUnavailable', 503)); });
      response.once('end', () => { cleanup(); resolve({ status: response.statusCode, headers: response.headers, data: Buffer.concat(chunks) }); });
    });
    request.once('timeout', () => request.destroy()); request.once('error', () => { cleanup(); reject(new RelayError('ViewerUpstreamUnavailable', 503)); }); request.end(data);
  });
  const authorizedLease = (id) => {
    const lease = relay.get(id);
    if (stopping || !relay.healthy || relay.stopped || !['ready', 'connected'].includes(lease.state) || Date.parse(lease.expiresAt) <= now()) throw new RelayError('ViewerLeaseUnavailable', 409);
    return lease;
  };
  const revokeToken = (token) => { if (token) buffered('DELETE', `api/tokens/${encodeURIComponent(token)}`, undefined).catch(() => {}); };
  const invalidate = (id, closeLease = false) => {
    for (const [hash, ticket] of tickets) if (ticket.sessionId === id) tickets.delete(hash);
    for (const [hash, session] of sessions) if (session.sessionId === id) {
      sessions.delete(hash); for (const request of session.requests) request.destroy(); for (const incoming of session.incoming) incoming.destroy();
      const token = session.authToken; session.authToken = null; session.tunnelToken = null; revokeToken(token);
      // Apenas confirmação de encerramento por60s. Nunca retoma controle,
      // autenticação Guac ou túnel. Necessário quando disconnect chega antes de END.
      closedSessions.set(hash, { sessionId: id, csrf: session.csrf, closed: true, until: now() + 60000 });
      while (closedSessions.size > 128) closedSessions.delete(closedSessions.keys().next().value);
    }
    if (closeLease) relay.safeClose(id, 'viewer_disconnected');
  };
  const issue = (id, input) => {
    exact(input, ['sessionId']); if (!UUID.test(id) || input.sessionId !== id) throw new RelayError('InvalidLeaseId');
    const lease = authorizedLease(id);
    if (lease.state !== 'ready' || [...sessions.values()].some((session) => session.sessionId === id)) throw new RelayError('ViewerAlreadyOpened', 409);
    for (const [hash, value] of tickets) if (value.expires <= now() || value.sessionId === id) tickets.delete(hash);
    if (tickets.size >= 32) throw new RelayError('ViewerCapacity', 503);
    const ticket = random(); const expires = Math.min(now() + 30000, Date.parse(lease.expiresAt));
    tickets.set(digest(ticket), { sessionId: id, expires });
    return { sessionId: id, state: 'viewer_ready', viewerUrl: `${publicUrl.origin}/pdv-remote/open`, ticket, expiresAt: lease.expiresAt, ticketExpiresAt: new Date(expires).toISOString() };
  };
  const authenticate = async (sessionId, owner) => {
    const lease = authorizedLease(sessionId);
    const parameters = { hostname: lease.hostname, port: String(lease.port), password: lease.password, 'read-only': 'false', 'disable-copy': 'true', 'disable-paste': 'true', 'disable-display-resize': 'true', 'enable-sftp': 'false', 'enable-audio': 'false' };
    const document = { username: `conecta-${sessionId}-${crypto.randomBytes(8).toString('hex')}`, expires: Math.min(now() + 60000, Date.parse(lease.expiresAt)), singleUse: true, connections: { [sessionId]: { protocol: 'vnc', singleUse: true, parameters } } };
    const plaintext = Buffer.from(JSON.stringify(document)); const signature = crypto.createHmac('sha256', key).update(plaintext).digest();
    const cipher = crypto.createCipheriv('aes-128-cbc', key, Buffer.alloc(16));
    const encrypted = Buffer.concat([cipher.update(Buffer.concat([signature, plaintext])), cipher.final()]).toString('base64');
    const result = await buffered('POST', 'api/tokens', new URLSearchParams({ data: encrypted }).toString(), 16384, { 'Content-Type': 'application/x-www-form-urlencoded' }, owner);
    let value; try { value = JSON.parse(result.data.toString('utf8')); } catch { throw new RelayError('ViewerAuthenticationUnavailable', 503); }
    if (result.status !== 200 || typeof value.authToken !== 'string' || !/^[A-Za-z0-9+/_=-]{16,256}$/.test(value.authToken) || value.dataSource !== 'json' || !Array.isArray(value.availableDataSources) || !value.availableDataSources.includes('json')) throw new RelayError('ViewerAuthenticationUnavailable', 503);
    return value.authToken;
  };
  const cookieSession = (request, id, allowClosed = false) => {
    const cookies = (request.headers.cookie || '').split(';').map((item) => item.trim()).filter((item) => item.startsWith('__Secure-pdv_remote='));
    if (cookies.length !== 1) throw new RelayError('ViewerNotAuthorized', 401);
    const cookie = cookies[0].substring('__Secure-pdv_remote='.length);
    const hash = SECRET.test(cookie) ? digest(cookie) : null;
    const session = sessions.get(hash) || (allowClosed ? closedSessions.get(hash) : null);
    if (!session || session.sessionId !== id) throw new RelayError('ViewerNotAuthorized', 401);
    if (session.closed) { if (session.until <= now() || relay.get(id).state !== 'closed') throw new RelayError('ViewerNotAuthorized', 401); return session; }
    authorizedLease(id); return session;
  };
  const csrf = (request, session) => {
    if (((request.method !== 'GET' || request.headers.origin) && request.headers.origin !== publicUrl.origin) || request.headers['x-pdv-remote-csrf'] !== session.csrf) throw new RelayError('ViewerOriginNotAuthorized', 403);
  };
  const stream = async (request, response, session, query) => {
    csrf(request, session);
    if (query === '?connect') {
      if (request.method !== 'POST' || session.connectAttempted) throw new RelayError('ViewerAlreadyOpened', 409);
      session.connectAttempted = true;
      session.incoming.add(request); let values;
      try { values = form(await body(request, 1024)); } finally { session.incoming.delete(request); }
      authorizedLease(session.sessionId);
      if (![...sessions.values()].includes(session) || !session.authToken) throw new RelayError('ViewerNotAuthorized', 401);
      if (Object.keys(values).some((name) => !['width', 'height'].includes(name))) throw new RelayError('InvalidViewerParameters');
      const width = values.width || '1280'; const height = values.height || '800';
      if (!/^\d{3,4}$/.test(width) || !/^\d{3,4}$/.test(height) || Number(width) < 320 || Number(width) > 4096 || Number(height) < 200 || Number(height) > 4096) throw new RelayError('InvalidViewerParameters');
      const data = new URLSearchParams({ token: session.authToken, GUAC_ID: session.sessionId, GUAC_TYPE: 'c', GUAC_DATA_SOURCE: 'json', GUAC_WIDTH: width, GUAC_HEIGHT: height, GUAC_DPI: '96', GUAC_IMAGE: 'image/png' }).toString();
      const result = await buffered('POST', 'tunnel?connect', data, 256, { 'Content-Type': 'application/x-www-form-urlencoded' }, session);
      const uuid = result.data.toString('utf8'); const tunnelToken = result.headers['guacamole-tunnel-token'];
      authorizedLease(session.sessionId);
      if (![...sessions.values()].includes(session) || result.status !== 200 || !UUID.test(uuid) || typeof tunnelToken !== 'string' || !/^[A-Za-z0-9+/]{44}$/.test(tunnelToken) || Buffer.from(tunnelToken, 'base64').length !== 33) throw new RelayError('ViewerTunnelUnavailable', 503);
      session.tunnelId = uuid; session.tunnelToken = tunnelToken; session.browserTunnelToken = random(); session.lastSeen = now();
      response.setHeader('Guacamole-Tunnel-Token', session.browserTunnelToken); send(response, 200, uuid, 'text/plain; charset=utf-8'); return;
    }
    const match = /^\?(read|write):([0-9a-f-]{36})(?::([0-9]{1,10}))?$/.exec(query);
    if (!match || match[2] !== session.tunnelId || request.headers['guacamole-tunnel-token'] !== session.browserTunnelToken || (match[1] === 'read' ? request.method !== 'GET' || !match[3] : request.method !== 'POST' || match[3])) throw new RelayError('ViewerTunnelNotAuthorized', 403);
    const reading = match[1] === 'read';
    if (session.operations >= 4) throw new RelayError('ViewerRequestLimit', 429);
    session.operations += 1; session.incoming.add(request); let released = false;
    const release = () => { if (!released) { released = true; session.operations -= 1; session.incoming.delete(request); } };
    let data; let pending;
    try {
      data = reading ? undefined : await body(request, 65536);
      authorizedLease(session.sessionId);
      if (![...sessions.values()].includes(session)) throw new RelayError('ViewerNotAuthorized', 401);
      pending = upstreamRequest(request.method, `tunnel${query}`, data, { 'Guacamole-Tunnel-Token': session.tunnelToken, ...(reading ? {} : { 'Content-Type': 'application/octet-stream' }) }, 30000);
    } catch (error) { release(); throw error; }
    session.requests.add(pending); session.lastSeen = now();
    const cleanup = () => { session.requests.delete(pending); release(); };
    pending.once('error', () => { cleanup(); if (!response.headersSent) send(response, 502, { error: 'ViewerTransportUnavailable' }); else response.destroy(); });
    pending.once('timeout', () => pending.destroy());
    pending.once('response', (upstreamResponse) => {
      if (upstreamResponse.statusCode !== 200) { upstreamResponse.resume(); cleanup(); send(response, 502, { error: 'ViewerTransportUnavailable' }); return; }
      response.writeHead(200, { 'Content-Type': 'application/octet-stream', 'X-Accel-Buffering': 'no' });
      upstreamResponse.once('error', () => response.destroy()); upstreamResponse.once('end', cleanup); upstreamResponse.pipe(response);
    });
    response.once('close', () => { cleanup(); pending.destroy(); }); pending.end(data);
  };
  const handler = async (request, response) => {
    securityHeaders(response);
    try {
      if (!request.socket.encrypted || request.headers.host !== publicUrl.host || stopping) throw new RelayError('ViewerNotAuthorized', 403);
      const url = new URL(request.url, publicUrl);
      if (url.pathname === '/pdv-remote/open') {
        if (url.search || request.method !== 'POST' || request.headers.origin !== conectaUrl.origin || request.headers['content-type']?.split(';')[0] !== 'application/x-www-form-urlencoded') throw new RelayError('ViewerOriginNotAuthorized', 403);
        const values = form(await body(request)); exact(values, ['sessionId', 'ticket']);
        const hash = SECRET.test(values.ticket) ? digest(values.ticket) : null; const ticket = tickets.get(hash);
        if (!ticket || ticket.sessionId !== values.sessionId || ticket.expires <= now()) throw new RelayError('ViewerTicketInvalid', 403);
        tickets.delete(hash); const lease = authorizedLease(ticket.sessionId);
        if ([...sessions.values()].some((value) => value.sessionId === ticket.sessionId)) throw new RelayError('ViewerAlreadyOpened', 409);
        const cookie = random(); const entry = { sessionId: ticket.sessionId, csrf: random(), authToken: null, tunnelToken: null, tunnelId: null, requests: new Set(), connectAttempted: false, lastSeen: now(), expires: Date.parse(lease.expiresAt) };
        entry.incoming = new Set(); entry.operations = 0;
        const sessionKey = digest(cookie); sessions.set(sessionKey, entry);
        try { entry.authToken = await authenticate(ticket.sessionId, entry); authorizedLease(ticket.sessionId); if (sessions.get(sessionKey) !== entry) throw new RelayError('ViewerLeaseUnavailable', 409); }
        catch (error) { revokeToken(entry.authToken); entry.authToken = null; invalidate(ticket.sessionId, true); throw error; }
        const location = `/pdv-remote/s/${ticket.sessionId}/`;
        response.setHeader('Set-Cookie', `__Secure-pdv_remote=${cookie}; Path=${location}; Secure; HttpOnly; SameSite=Strict; Max-Age=${Math.max(1, Math.floor((entry.expires - now()) / 1000))}`);
        // 200 cria um documento do próprio site antes de navegar. Uma cadeia
        // cross-site POST→303 pode omitir cookies SameSite=Strict no Chrome.
        response.setHeader('Location', location);
        send(response, 200, `<!doctype html><html lang="pt-BR"><head><meta charset="utf-8"><title>Abrir suporte remoto</title><script src="/pdv-remote/assets/open.js" defer></script></head><body><p>Abrindo atendimento…</p><a id="continue" href="${location}">Continuar para o atendimento</a></body></html>`, 'text/html; charset=utf-8'); return;
      }
      const asset = /^\/pdv-remote\/assets\/(viewer\.js|viewer\.css|open\.js|guacamole-common-js\.js)$/.exec(url.pathname);
      if (asset && !url.search && request.method === 'GET') {
        if (asset[1] === 'guacamole-common-js.js') {
          if (!library && !libraryPending) libraryPending = buffered('GET', 'guacamole-common-js/all.min.js', undefined, 4194304).then((result) => { if (result.status !== 200 || digest(result.data) !== config.commonJsSha256) throw new RelayError('ViewerLibraryIntegrity', 503); library = result.data; }).finally(() => { libraryPending = null; });
          if (libraryPending) await libraryPending;
          send(response, 200, library, 'application/javascript; charset=utf-8'); return;
        }
        send(response, 200, assets[asset[1]], asset[1].endsWith('.js') ? 'application/javascript; charset=utf-8' : 'text/css; charset=utf-8'); return;
      }
      const match = /^\/pdv-remote\/s\/([0-9a-f-]{36})\/(state|end|tunnel)?$/.exec(url.pathname);
      if (!match || !UUID.test(match[1])) throw new RelayError('NotFound', 404);
      const session = cookieSession(request, match[1], match[2] === 'end');
      if (!match[2] && !url.search && request.method === 'GET') { send(response, 200, fs.readFileSync(path.join(__dirname, 'viewer.html')), 'text/html; charset=utf-8'); return; }
      if (match[2] === 'state' && !url.search && request.method === 'GET') { session.lastSeen = now(); send(response, 200, { state: relay.get(session.sessionId).state, expiresAt: new Date(session.expires).toISOString(), csrf: session.csrf }); return; }
      if (match[2] === 'end' && !url.search && request.method === 'POST') { csrf(request, session); await body(request, 1024); if (!session.closed) invalidate(session.sessionId, true); response.setHeader('Set-Cookie', `__Secure-pdv_remote=; Path=/pdv-remote/s/${session.sessionId}/; Secure; HttpOnly; SameSite=Strict; Max-Age=0`); send(response, 200, { state: 'closed' }); return; }
      if (match[2] === 'tunnel') { await stream(request, response, session, url.search); return; }
      throw new RelayError('NotFound', 404);
    } catch (error) { if (!response.headersSent && !response.destroyed) send(response, error instanceof RelayError ? error.status : 500, { error: error instanceof RelayError ? error.code : 'ViewerUnavailable' }); else response.destroy(); }
  };
  const timer = setInterval(() => {
    for (const [hash, ticket] of tickets) if (ticket.expires <= now()) tickets.delete(hash);
    for (const [hash, session] of closedSessions) if (session.until <= now()) closedSessions.delete(hash);
    for (const session of [...sessions.values()]) { try { authorizedLease(session.sessionId); if (now() - session.lastSeen > 20000) invalidate(session.sessionId, true); } catch { invalidate(session.sessionId); } }
  }, 1000); timer.unref();
  return { issue, handler, invalidate, stop() { stopping = true; clearInterval(timer); for (const session of [...sessions.values()]) invalidate(session.sessionId, true); for (const request of pendingRequests) request.destroy(); tickets.clear(); closedSessions.clear(); } };
};
module.exports = { createWebViewer };
