const http = require('http');
const path = require('path');
const pino = require('pino');
const qrcode = require('qrcode-terminal');
const {
  default: makeWASocket,
  DisconnectReason,
  useMultiFileAuthState,
  fetchLatestBaileysVersion,
} = require('@whiskeysockets/baileys');

const host = process.env.BAILEYS_HOST || '127.0.0.1';
const port = Number(process.env.BAILEYS_PORT || 4010);
const authDir = path.resolve(process.env.BAILEYS_AUTH_DIR || path.resolve(__dirname, 'session'));

const logger = pino({ level: 'info' });
let socket = null;
let connected = false;
let lastQr = '';
let reconnecting = false;

async function connectWhatsApp() {
  const { state, saveCreds } = await useMultiFileAuthState(authDir);
  const { version } = await fetchLatestBaileysVersion();

  socket = makeWASocket({
    version,
    auth: state,
    logger,
    printQRInTerminal: false,
    browser: ['n8n-solicitador-linkedin', 'Chrome', '1.0.0'],
  });

  socket.ev.on('creds.update', saveCreds);

  socket.ev.on('connection.update', (update) => {
    const { connection, lastDisconnect, qr } = update;

    if (qr) {
      lastQr = qr;
      console.log('\nEscaneie o QR abaixo no WhatsApp (Aparelhos conectados):\n');
      qrcode.generate(qr, { small: true });
    }

    if (connection === 'open') {
      connected = true;
      reconnecting = false;
      console.log('Baileys conectado ao WhatsApp.');
    }

    if (connection === 'close') {
      connected = false;
      const statusCode = lastDisconnect?.error?.output?.statusCode;
      const shouldReconnect = statusCode !== DisconnectReason.loggedOut;

      console.log('Conexao fechada. statusCode=', statusCode, 'reconnect=', shouldReconnect);

      if (shouldReconnect && !reconnecting) {
        reconnecting = true;
        setTimeout(() => {
          connectWhatsApp().catch((err) => {
            reconnecting = false;
            console.error('Erro ao reconectar:', err.message);
          });
        }, 3000);
      } else if (!shouldReconnect) {
        console.log('Sessão desconectada. Refaça o pareamento removendo a pasta session, se necessário.');
      }
    }
  });
}

function sendJson(res, statusCode, payload) {
  const body = JSON.stringify(payload);
  res.writeHead(statusCode, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': Buffer.byteLength(body),
  });
  res.end(body);
}

function normalizePhone(phoneRaw) {
  const digits = String(phoneRaw || '').replace(/\D/g, '');
  if (!digits) return '';
  if (digits.startsWith('55')) return digits;
  if (digits.length === 10 || digits.length === 11) return '55' + digits;
  return digits;
}

function toJid(phoneDigits) {
  return phoneDigits + '@s.whatsapp.net';
}

const server = http.createServer(async (req, res) => {
  if (req.method === 'GET' && req.url === '/health') {
    return sendJson(res, 200, {
      ok: true,
      connected,
      hasQr: !!lastQr,
    });
  }

  if (req.method === 'GET' && req.url === '/qr') {
    if (!lastQr) {
      return sendJson(res, 404, {
        ok: false,
        error: 'QR ainda nao disponivel',
      });
    }

    return qrcode.generate(lastQr, { small: true }, (qrAscii) => {
      return sendJson(res, 200, {
        ok: true,
        connected,
        qrAscii,
      });
    });
  }

  if (req.method === 'POST' && req.url === '/send') {
    let rawBody = '';
    req.on('data', (chunk) => {
      rawBody += chunk;
    });

    req.on('end', async () => {
      try {
        const payload = rawBody ? JSON.parse(rawBody) : {};
        const phone = normalizePhone(payload.phone);
        const message = String(payload.message || '').trim();

        if (!connected || !socket) {
          return sendJson(res, 503, {
            ok: false,
            error: 'Baileys ainda nao conectado ao WhatsApp',
          });
        }

        if (!phone || phone.length < 12 || phone.length > 13) {
          return sendJson(res, 400, {
            ok: false,
            error: 'Telefone invalido',
          });
        }

        if (!message) {
          return sendJson(res, 400, {
            ok: false,
            error: 'Mensagem vazia',
          });
        }

        const jid = toJid(phone);
        const sent = await socket.sendMessage(jid, { text: message });

        return sendJson(res, 200, {
          ok: true,
          phone,
          jid,
          messageId: sent?.key?.id || '',
        });
      } catch (err) {
        return sendJson(res, 500, {
          ok: false,
          error: err && err.message ? err.message : String(err),
        });
      }
    });

    return;
  }

  return sendJson(res, 404, {
    ok: false,
    error: 'Rota nao encontrada',
  });
});

async function startServer() {
  server.listen(port, host, async () => {
    console.log('Baileys bridge ouvindo em http://' + host + ':' + port);
    await connectWhatsApp();
  });
}

if (require.main === module) {
  startServer().catch((error) => {
    console.error('Falha ao iniciar Baileys bridge:', error);
    process.exitCode = 1;
  });
}

module.exports = {
  normalizePhone,
  startServer,
  toJid,
};
