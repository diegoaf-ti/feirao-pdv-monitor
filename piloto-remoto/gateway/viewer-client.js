'use strict';

// Somente controle consentido e temporário; nenhum dado de teclado/tela é logado.
(() => {
  const status = document.getElementById('status'); const message = document.getElementById('message');
  const display = document.getElementById('display'); const remaining = document.getElementById('remaining');
  let client = null; let clientState = 0; let csrf = null; let closed = false; let polling = null; let clock = null; let deadline = 0; let ending = null;
  const endpoint = (suffix) => new URL(suffix, window.location.href).toString();
  const closeServer = async () => {
    if (!csrf) return;
    try {
      const response = await fetch(endpoint('end'), { method: 'POST', headers: { 'X-PDV-Remote-CSRF': csrf || '', 'Content-Type': 'text/plain' }, body: '', credentials: 'same-origin', keepalive: true, cache: 'no-store' });
      if (!response.ok) throw new Error('unconfirmed'); status.textContent = 'Acesso encerrado'; message.textContent = 'Volte ao Conecta para solicitar outro atendimento.';
    } catch { status.textContent = 'Encerramento solicitado'; message.textContent = 'Confirme o encerramento no Conecta. O prazo do servidor continua valendo.'; }
  };
  const finish = async () => {
    if (closed) return ending; closed = true; clearInterval(polling); clearInterval(clock);
    remaining.textContent = ''; document.getElementById('finish').disabled = true;
    if (client) client.disconnect(); status.textContent = 'Encerrando acesso…'; display.replaceChildren();
    if (csrf) { ending = closeServer(); return ending; }
  };
  document.getElementById('finish').addEventListener('click', finish);
  window.addEventListener('pagehide', finish);
  const state = async () => {
    const response = await fetch(endpoint('state'), { credentials: 'same-origin', cache: 'no-store' });
    if (!response.ok) throw new Error('unavailable'); return response.json();
  };
  const begin = async () => {
    const initial = await state(); csrf = initial.csrf; deadline = Date.parse(initial.expiresAt);
    if (closed) { ending = closeServer(); await ending; return; }
    if (!window.Guacamole || !csrf || !Number.isFinite(deadline)) throw new Error('unavailable');
    const tunnel = new Guacamole.HTTPTunnel(endpoint('tunnel'), false, { 'X-PDV-Remote-CSRF': csrf });
    client = new Guacamole.Client(tunnel); display.appendChild(client.getDisplay().getElement());
    client.onerror = () => { message.textContent = 'A conexão foi interrompida. Solicite um novo atendimento pelo Conecta.'; finish(); };
    client.onstatechange = (value) => { clientState = value; if (value === 3 && !closed) { status.textContent = 'Atendimento conectado'; display.focus(); } if (value === 5 && !closed) finish(); };
    const mouse = new Guacamole.Mouse(client.getDisplay().getElement());
    mouse.onEach(['mousedown', 'mouseup', 'mousemove'], (event) => { if (!closed && clientState === 3 && document.hasFocus()) client.sendMouseState(event.state); });
    const keyboard = new Guacamole.Keyboard(display);
    keyboard.onkeydown = (keysym) => { if (!closed && clientState === 3 && document.activeElement === display) { client.sendKeyEvent(1, keysym); return false; } return true; };
    keyboard.onkeyup = (keysym) => { if (!closed && clientState === 3) client.sendKeyEvent(0, keysym); };
    display.addEventListener('blur', () => keyboard.reset());
    client.connect(new URLSearchParams({ width: String(Math.max(320, Math.min(4096, window.innerWidth - 32))), height: String(Math.max(200, Math.min(4096, window.innerHeight - 140))) }).toString());
    if (closed) return;
    polling = setInterval(async () => { if (closed) return; try { const current = await state(); if (!['ready', 'connected'].includes(current.state)) finish(); } catch { finish(); } }, 5000);
    clock = setInterval(() => { const seconds = Math.max(0, Math.ceil((deadline - Date.now()) / 1000)); remaining.textContent = `${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, '0')}`; if (!seconds) finish(); }, 1000);
  };
  begin().catch(() => { message.textContent = 'Não foi possível abrir este atendimento. Volte ao Conecta para encerrar ou solicitar novamente.'; finish(); });
})();
