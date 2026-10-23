'use strict';

// Exercita o script real no VM com DOM/Guacamole/HTTP falsos. Não inicia
// navegador, servidor, conexão remota ou captura de teclado/tela reais.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const source = fs.readFileSync(path.join(__dirname, '..', 'viewer-client.js'), 'utf8');
const ID = '11111111-1111-4111-8111-111111111111';
const START = Date.parse('2026-10-21T16:00:00Z');
const pending = () => { let resolve; let reject; const promise = new Promise((yes, no) => { resolve = yes; reject = no; }); return { promise, resolve, reject }; };
const settle = async () => { for (let i = 0; i < 8; i++) await Promise.resolve(); };
const response = (data, ok = true) => ({ ok, json: async () => data });

const fixture = ({ deferredState = false, endOk = true, connectError = false } = {}) => {
  let now = START; let pageFocused = true; let sequence = 0; let nextState = null;
  const fetches = []; const clients = []; const tunnels = []; const mice = []; const keyboards = []; const intervals = new Map(); const windowEvents = new Map();
  const document = { activeElement: null, hasFocus: () => pageFocused };
  const element = (name) => ({ name, textContent: '', children: [], events: new Map(), appendChild(child) { this.children.push(child); }, replaceChildren() { this.children = []; }, focus() { document.activeElement = this; }, addEventListener(event, callback) { this.events.set(event, callback); } });
  const elements = Object.fromEntries(['status', 'message', 'display', 'remaining', 'finish'].map((name) => [name, element(name)]));
  document.getElementById = (id) => elements[id];
  const initial = { state: 'ready', csrf: 'SCOPED_CSRF_FIXTURE', expiresAt: new Date(START + 900000).toISOString() };
  const first = pending(); let firstRequested = false;
  const fetch = async (url, options) => {
    fetches.push({ url, options });
    if (url.endsWith('/end')) return response({ state: 'closed' }, endOk);
    assert.ok(url.endsWith('/state')); assert.equal(options.credentials, 'same-origin'); assert.equal(options.cache, 'no-store');
    if (!firstRequested) { firstRequested = true; return deferredState ? first.promise : response(initial); }
    if (nextState) { const value = nextState; nextState = null; return value; }
    return response(initial);
  };
  const Guacamole = {
    HTTPTunnel: function (url, crossDomain, headers) { this.url = url; this.crossDomain = crossDomain; this.headers = headers; tunnels.push(this); },
    Client: function (tunnel) {
      this.tunnel = tunnel; this.connects = []; this.disconnects = 0; this.mouseEvents = []; this.keyEvents = [];
      this.getDisplay = () => ({ getElement: () => elements.remoteScreen || (elements.remoteScreen = element('remoteScreen')) });
      this.connect = (args) => { this.connects.push(args); if (connectError && this.onerror) this.onerror(new Error('SYNC_CONNECT_FAILURE')); };
      this.disconnect = () => { this.disconnects += 1; if (this.onstatechange) this.onstatechange(5); };
      this.sendMouseState = (value) => this.mouseEvents.push(value);
      this.sendKeyEvent = (pressed, keysym) => this.keyEvents.push([pressed, keysym]);
      // Não oferece getState(): Client1.6 usa onstatechange.
      clients.push(this);
    },
    Mouse: function (screen) { this.screen = screen; this.onEach = (events, callback) => { this.events = events; this.callback = callback; }; mice.push(this); },
    Keyboard: function (screen) { this.screen = screen; this.resets = 0; this.reset = () => { this.resets += 1; }; keyboards.push(this); },
  };
  const window = { location: { href: `https://viewer.example/pdv-remote/s/${ID}/` }, innerWidth: 1440, innerHeight: 900, Guacamole, addEventListener: (event, callback) => windowEvents.set(event, callback) };
  const forbiddenStorage = { get() { throw new Error('PersistentStorageUsed'); }, set() { throw new Error('PersistentStorageUsed'); } };
  const context = { document, window, Guacamole, URL, URLSearchParams, fetch, Date: class extends Date { static now() { return now; } }, setInterval(callback, ms) { const id = ++sequence; intervals.set(id, { callback, ms }); return id; }, clearInterval(id) { intervals.delete(id); }, console: { log() { throw new Error('LoggingForbidden'); }, error() { throw new Error('LoggingForbidden'); } } };
  for (const target of [context, window]) for (const key of ['localStorage', 'sessionStorage']) Object.defineProperty(target, key, forbiddenStorage);
  vm.runInNewContext(source, context, { filename: 'viewer-client.js', timeout: 1000 });
  return {
    clients, tunnels, mice, keyboards, elements, fetches, intervals,
    resolveInitial: (value = initial) => first.resolve(response(value)),
    finish: () => elements.finish.events.get('click')(), pagehide: () => windowEvents.get('pagehide')(),
    focus: (value) => { pageFocused = value; if (!value) document.activeElement = null; },
    blur: () => { document.activeElement = null; elements.display.events.get('blur')(); },
    state: (value, ok = true) => { nextState = Promise.resolve(response(value, ok)); },
    stateFailure: () => { nextState = Promise.reject(new Error('STATE_NETWORK_FAILURE')); nextState.catch(() => {}); },
    advance: (ms) => { now += ms; },
    tick: async (ms) => { for (const item of [...intervals.values()]) if (item.ms === ms) await item.callback(); await settle(); },
  };
};

test('finalizar antes da consulta inicial não cria cliente/timers e envia END quando obtém CSRF', async () => {
  for (const action of ['finish', 'pagehide']) {
    const f = fixture({ deferredState: true });
    await f[action](); assert.equal(f.clients.length, 0); assert.equal(f.intervals.size, 0); assert.equal(f.fetches.length, 1);
    f.resolveInitial(); await settle();
    assert.equal(f.clients.length, 0); assert.equal(f.tunnels.length, 0); assert.equal(f.intervals.size, 0);
    const closing = f.fetches.filter(({ url }) => url.endsWith('/end')); assert.equal(closing.length, 1);
    assert.equal(closing[0].options.headers['X-PDV-Remote-CSRF'], 'SCOPED_CSRF_FIXTURE'); assert.equal(closing[0].options.keepalive, true);
    assert.equal(f.elements.status.textContent, 'Acesso encerrado');
  }
});

test('controle exige clientState3 e foco, blur solta teclado e fechamento bloqueia novos eventos', async () => {
  const f = fixture(); await settle(); const client = f.clients[0]; const mouse = f.mice[0]; const keyboard = f.keyboards[0];
  assert.equal(client.connects.length, 1); assert.equal(f.intervals.size, 2);
  mouse.callback({ state: 'before-connected' }); assert.equal(keyboard.onkeydown(65), true); keyboard.onkeyup(65);
  assert.equal(client.mouseEvents.length, 0); assert.equal(client.keyEvents.length, 0);
  client.onstatechange(3); mouse.callback({ state: 'connected-focused' });
  assert.equal(keyboard.onkeydown(65), false); keyboard.onkeyup(65);
  assert.deepEqual(client.mouseEvents, ['connected-focused']); assert.deepEqual(client.keyEvents, [[1, 65], [0, 65]]);
  f.focus(false); mouse.callback({ state: 'background' }); assert.equal(keyboard.onkeydown(66), true);
  assert.equal(client.mouseEvents.length, 1); assert.equal(client.keyEvents.length, 2);
  f.blur(); assert.equal(keyboard.resets, 1);
  f.focus(true); client.onstatechange(2); mouse.callback({ state: 'not-ready' }); assert.equal(keyboard.onkeydown(67), true);
  assert.equal(client.mouseEvents.length, 1);
  await f.finish(); mouse.callback({ state: 'closed' }); assert.equal(keyboard.onkeydown(68), true); keyboard.onkeyup(68);
  assert.equal(client.mouseEvents.length, 1); assert.equal(client.keyEvents.length, 2); assert.equal(client.disconnects, 1); assert.equal(f.intervals.size, 0);
});

test('erro, prazo, queda da consulta e pagehide encerram sem reconectar ou repetir END', async () => {
  for (const trigger of ['error', 'expiry', 'state-closed', 'state-failure', 'pagehide']) {
    const f = fixture(); await settle(); const client = f.clients[0]; client.onstatechange(3);
    if (trigger === 'error') client.onerror(new Error('UPSTREAM_FAILURE'));
    if (trigger === 'expiry') { f.advance(900000); await f.tick(1000); }
    if (trigger === 'state-closed') { f.state({ state: 'closed' }); await f.tick(5000); }
    if (trigger === 'state-failure') { f.stateFailure(); await f.tick(5000); }
    if (trigger === 'pagehide') await f.pagehide();
    await settle(); assert.equal(client.disconnects, 1, trigger); assert.equal(f.intervals.size, 0, trigger); assert.equal(client.connects.length, 1, trigger);
    assert.equal(f.fetches.filter(({ url }) => url.endsWith('/end')).length, 1, trigger);
    await f.finish(); await f.pagehide(); assert.equal(client.disconnects, 1); assert.equal(f.fetches.filter(({ url }) => url.endsWith('/end')).length, 1);
  }
});

test('erro síncrono ao iniciar o túnel não cria timers depois do encerramento', async () => {
  const f = fixture({ connectError: true }); await settle();
  assert.equal(f.clients.length, 1); assert.equal(f.clients[0].connects.length, 1); assert.equal(f.clients[0].disconnects, 1); assert.equal(f.intervals.size, 0);
  assert.equal(f.fetches.filter(({ url }) => url.endsWith('/end')).length, 1);
  await f.finish(); assert.equal(f.clients[0].connects.length, 1);
});

test('falha ao encerrar preserva mensagem incerta, sem afirmar desconexão confirmada', async () => {
  const f = fixture({ endOk: false }); await settle(); await f.finish();
  assert.equal(f.elements.status.textContent, 'Encerramento solicitado'); assert.match(f.elements.message.textContent, /Confirme o encerramento no Conecta/);
  assert.equal(f.clients[0].disconnects, 1); assert.equal(f.intervals.size, 0);
});

test('configuração do túnel limita dimensões e não grava dados em storage, URL ou logs', async () => {
  const f = fixture(); await settle();
  assert.equal(f.tunnels[0].url, `https://viewer.example/pdv-remote/s/${ID}/tunnel`); assert.equal(new URL(f.tunnels[0].url).search, '');
  assert.equal(f.tunnels[0].crossDomain, false); assert.equal(f.tunnels[0].headers['X-PDV-Remote-CSRF'], 'SCOPED_CSRF_FIXTURE');
  const fields = new URLSearchParams(f.clients[0].connects[0]); assert.deepEqual([...fields.keys()].sort(), ['height', 'width']); assert.equal(fields.get('width'), '1408'); assert.equal(fields.get('height'), '760');
  for (const { url, options } of f.fetches) { assert.equal(new URL(url).search, ''); assert.equal(options.cache, 'no-store'); assert.equal(options.credentials, 'same-origin'); }
  await f.finish(); assert.ok(!f.fetches.some(({ url }) => /token|password|ticket|SCOPED_CSRF/.test(url)));
});
