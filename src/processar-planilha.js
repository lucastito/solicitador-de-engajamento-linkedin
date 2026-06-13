const fs = require('fs');
const path = require('path');

const statusSim = 'sim';
const statusNao = 'n\u00E3o';
const statusParcial = 'parcialmente';

function requiredEnvironmentValue(name) {
  const value = process.env[name];
  if (!value || !value.trim()) {
    throw new Error('Variavel de ambiente obrigatoria nao definida: ' + name);
  }
  return value.trim();
}

const workflowRoot = path.resolve(requiredEnvironmentValue('SOLICITADOR_ROOT'));
const dataDir = path.resolve(workflowRoot, 'data');
const logsDir = path.resolve(workflowRoot, 'logs');
const spreadsheetPath = path.resolve(
  process.env.SOLICITADOR_PLANILHA || path.resolve(dataDir, 'contatos_linkedin_envio.csv'),
);

const baileysEndpoint = process.env.BAILEYS_ENDPOINT || 'http://127.0.0.1:4010/send';
const requestTimeoutMs = 45000;
const minDelayMs = 8000;
const maxDelayMs = 15000;
const checkpointEvery = 10;
const checkpointPauseMinMs = 20000;
const checkpointPauseMaxMs = 35000;

const dryRun = String(process.env.SOLICITADOR_DRY_RUN || 'true').toLowerCase() !== 'false';

function ensureDirectory(dirPath) {
  if (!fs.existsSync(dirPath)) fs.mkdirSync(dirPath, { recursive: true });
}

function normalizeText(value) {
  return String(value || '')
    .normalize('NFD')
    .replace(/[\u0300-\u036f]/g, '')
    .toLowerCase()
    .trim();
}

function normalizeKey(value) {
  return normalizeText(value).replace(/[^a-z0-9]+/g, ' ').trim();
}

function detectDelimiter(firstLine) {
  const semicolonCount = (firstLine.match(/;/g) || []).length;
  const commaCount = (firstLine.match(/,/g) || []).length;
  return semicolonCount >= commaCount ? ';' : ',';
}

function parseCsv(content, delimiter) {
  const rows = [];
  let current = '';
  let row = [];
  let inQuotes = false;

  for (let i = 0; i < content.length; i++) {
    const char = content[i];
    const next = content[i + 1];

    if (char === '"') {
      if (inQuotes && next === '"') {
        current += '"';
        i += 1;
      } else {
        inQuotes = !inQuotes;
      }
      continue;
    }

    if (char === delimiter && !inQuotes) {
      row.push(current);
      current = '';
      continue;
    }

    if ((char === '\n' || char === '\r') && !inQuotes) {
      if (char === '\r' && next === '\n') i += 1;
      row.push(current);
      const isOnlyEmpty = row.length === 1 && row[0].trim() === '';
      if (!isOnlyEmpty) rows.push(row);
      row = [];
      current = '';
      continue;
    }

    current += char;
  }

  if (current.length > 0 || row.length > 0) {
    row.push(current);
    const isOnlyEmpty = row.length === 1 && row[0].trim() === '';
    if (!isOnlyEmpty) rows.push(row);
  }

  if (rows.length === 0) return { headers: [], records: [] };

  const headers = rows[0].map((h) => String(h || '').trim());
  const records = rows.slice(1).map((parts) => {
    const record = {};
    for (let i = 0; i < headers.length; i++) {
      record[headers[i]] = parts[i] !== undefined ? String(parts[i]) : '';
    }
    return record;
  });

  return { headers, records };
}

function escapeCsvValue(value, delimiter) {
  const text = String(value ?? '');
  const needsQuotes = text.includes(delimiter) || text.includes('"') || text.includes('\n') || text.includes('\r');
  if (!needsQuotes) return text;
  return '"' + text.replace(/"/g, '""') + '"';
}

function toCsv(headers, records, delimiter) {
  const lines = [];
  lines.push(headers.map((h) => escapeCsvValue(h, delimiter)).join(delimiter));
  for (const record of records) {
    const row = headers.map((h) => escapeCsvValue(record[h] ?? '', delimiter));
    lines.push(row.join(delimiter));
  }
  return lines.join('\r\n') + '\r\n';
}

const fieldAliases = {
  publicationName: ['nome da publicacao', 'nome da publicacao linkedin', 'nome publicacao', 'nome_publicacao', 'publicacao'],
  publicationLink: ['link da publicacao', 'link publicacao', 'link_publicacao', 'url publicacao'],
  status: ['status de envio', 'status envio', 'status_envio'],
  message: ['mensagem pro contato', 'mensagem para o contato', 'mensagem contato', 'mensagem'],
  whereKnow: ['onde conheco', 'de onde conheco', 'origem do contato'],
  personName: ['nome da pessoa', 'nome pessoa', 'nome'],
  nickname: ['apelido'],
  phone: ['numero de whats app', 'numero whatsapp', 'telefone', 'whatsapp'],
  detail: ['detalhe do ultimo envio', 'detalhe ultimo envio', 'detalhe envio'],
};

function findHeaderByAliases(headers, aliases) {
  const aliasSet = new Set(aliases.map((a) => normalizeKey(a)));
  for (const header of headers) {
    if (aliasSet.has(normalizeKey(header))) return header;
  }
  return '';
}

function getNormalizedRow(record) {
  const out = {};
  for (const [key, value] of Object.entries(record)) out[normalizeKey(key)] = String(value ?? '').trim();
  return out;
}

function pickField(normalizedRow, aliases) {
  for (const alias of aliases) {
    const value = normalizedRow[normalizeKey(alias)];
    if (value !== undefined) return value;
  }
  return '';
}

function normalizeStatus(value) {
  const raw = normalizeText(value);
  if (raw === 'sim') return statusSim;
  if (raw === 'nao') return statusNao;
  if (raw === 'parcialmente') return statusParcial;
  return '';
}

function normalizePhone(rawValue) {
  const digits = String(rawValue || '').replace(/\D/g, '');
  if (!digits) return '';
  if (digits.startsWith('55')) return digits;
  if (digits.length === 10 || digits.length === 11) return '55' + digits;
  return digits;
}

function isLikelyBrazilPhone(phoneDigits) {
  return phoneDigits.length >= 12 && phoneDigits.length <= 13;
}

function randomInt(min, max) {
  const minSafe = Math.ceil(min);
  const maxSafe = Math.floor(max);
  return Math.floor(Math.random() * (maxSafe - minSafe + 1)) + minSafe;
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

const http = require('http');

async function sendWhatsapp(phoneDigits, messageText) {
  if (dryRun) {
    return { ok: true, dryRun: true, response: { ok: true, simulated: true } };
  }

  return await new Promise((resolve) => {
    const payload = JSON.stringify({ phone: phoneDigits, message: messageText });
    const req = http.request(baileysEndpoint, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Content-Length': Buffer.byteLength(payload),
      },
    }, (res) => {
      let bodyText = '';
      res.on('data', (chunk) => {
        bodyText += chunk;
      });
      res.on('end', () => {
        let parsedBody = null;
        try { parsedBody = bodyText ? JSON.parse(bodyText) : null; } catch (_) { parsedBody = null; }

        if (res.statusCode < 200 || res.statusCode >= 300) {
          return resolve({ ok: false, error: 'HTTP ' + res.statusCode + ' ao enviar via Baileys', responseBody: bodyText });
        }

        if (parsedBody && parsedBody.ok === false) {
          return resolve({ ok: false, error: parsedBody.error || 'Baileys retornou ok=false', responseBody: parsedBody });
        }

        return resolve({ ok: true, response: parsedBody || bodyText });
      });
    });

    req.setTimeout(requestTimeoutMs, () => {
      req.destroy(new Error('Timeout ao enviar via Baileys (' + requestTimeoutMs + 'ms)'));
    });

    req.on('error', (err) => {
      resolve({ ok: false, error: err && err.message ? err.message : String(err) });
    });

    req.write(payload);
    req.end();
  });
}
function formatMessage(nickname, customMessage, publicationLink) {
  const base = 'Oi ' + nickname.trim() + '! ' + customMessage.trim();
  if (!publicationLink) return base;
  return base + '\n' + publicationLink.trim();
}

async function main() {
  ensureDirectory(dataDir);
  ensureDirectory(logsDir);

  if (!fs.existsSync(spreadsheetPath)) throw new Error('Planilha nao encontrada em: ' + spreadsheetPath);

  const csvRaw = fs.readFileSync(spreadsheetPath, 'utf8');
  const firstLine = csvRaw.split(/\r?\n/)[0] || '';
  const delimiter = detectDelimiter(firstLine);
  const parsed = parseCsv(csvRaw, delimiter);

  if (parsed.headers.length === 0) throw new Error('Planilha vazia ou sem cabecalho: ' + spreadsheetPath);

  const statusHeader = findHeaderByAliases(parsed.headers, fieldAliases.status) || 'status de envio';
  const detailHeader = findHeaderByAliases(parsed.headers, fieldAliases.detail) || 'detalhe do ultimo envio';

  const outputHeaders = [...parsed.headers];
  if (!outputHeaders.includes(statusHeader)) outputHeaders.push(statusHeader);
  if (!outputHeaders.includes(detailHeader)) outputHeaders.push(detailHeader);

  const enrichedRows = parsed.records.map((record, index) => {
    if (record[statusHeader] === undefined) record[statusHeader] = '';
    if (record[detailHeader] === undefined) record[detailHeader] = '';
    const normalized = getNormalizedRow(record);

    const publicationName = pickField(normalized, fieldAliases.publicationName);
    const publicationLink = pickField(normalized, fieldAliases.publicationLink);
    const existingStatus = normalizeStatus(pickField(normalized, fieldAliases.status));
    const customMessage = pickField(normalized, fieldAliases.message);
    const whereKnow = pickField(normalized, fieldAliases.whereKnow);
    const personName = pickField(normalized, fieldAliases.personName);
    const nickname = pickField(normalized, fieldAliases.nickname);
    const phoneRaw = pickField(normalized, fieldAliases.phone);
    const phoneNormalized = normalizePhone(phoneRaw);

    return {
      index,
      record,
      publicationName,
      publicationLink,
      existingStatus,
      customMessage,
      whereKnow,
      personName,
      nickname,
      phoneRaw,
      phoneNormalized,
    };
  });

  const groups = new Map();
  for (const row of enrichedRows) {
    const hasPublicationKey = Boolean((row.publicationName || '').trim() || (row.publicationLink || '').trim());
    const key = hasPublicationKey
      ? ((row.publicationName || 'sem_nome_publicacao') + '||' + (row.publicationLink || 'sem_link_publicacao'))
      : ('__row__' + row.index);

    if (!groups.has(key)) groups.set(key, []);
    groups.get(key).push(row);
  }

  const attempts = [];
  let attemptCounter = 0;

  const totals = {
    publications: groups.size,
    contacts: enrichedRows.length,
    success: 0,
    failure: 0,
    skippedAlreadySent: 0,
    invalidRows: 0,
  };

  for (const groupRows of groups.values()) {
    let successCount = 0;
    let failureCount = 0;

    for (const row of groupRows) {
      if (row.existingStatus === statusSim) {
        successCount += 1;
        totals.skippedAlreadySent += 1;
        row.record[detailHeader] = 'Ja estava marcado como sim';
        continue;
      }

      const phoneDigits = row.phoneNormalized;
      const nickname = (row.nickname || '').trim();
      const customMessage = (row.customMessage || '').trim();

      if (!phoneDigits || !isLikelyBrazilPhone(phoneDigits)) {
        failureCount += 1;
        totals.invalidRows += 1;
        row.record[detailHeader] = 'Falha: numero de WhatsApp invalido';
        attempts.push({ ts: new Date().toISOString(), phone: phoneDigits, ok: false, error: 'numero de WhatsApp invalido' });
        continue;
      }

      if (!nickname) {
        failureCount += 1;
        totals.invalidRows += 1;
        row.record[detailHeader] = 'Falha: apelido obrigatorio';
        attempts.push({ ts: new Date().toISOString(), phone: phoneDigits, ok: false, error: 'apelido obrigatorio' });
        continue;
      }

      if (!customMessage) {
        failureCount += 1;
        totals.invalidRows += 1;
        row.record[detailHeader] = 'Falha: mensagem obrigatoria';
        attempts.push({ ts: new Date().toISOString(), phone: phoneDigits, ok: false, error: 'mensagem obrigatoria' });
        continue;
      }

      const messageText = formatMessage(nickname, customMessage, row.publicationLink);
      const sendResult = await sendWhatsapp(phoneDigits, messageText);
      attemptCounter += 1;

      if (sendResult.ok) {
        successCount += 1;
        totals.success += 1;
        row.record[detailHeader] = dryRun ? 'Dry run: envio simulado com sucesso' : 'Enviado com sucesso';
      } else {
        failureCount += 1;
        totals.failure += 1;
        row.record[detailHeader] = 'Falha: ' + (sendResult.error || 'erro desconhecido');
      }

      attempts.push({
        ts: new Date().toISOString(),
        publication: row.publicationName,
        phone: phoneDigits,
        nickname,
        whereKnow: row.whereKnow,
        ok: sendResult.ok,
        dryRun,
        error: sendResult.ok ? '' : (sendResult.error || 'erro desconhecido'),
      });

      const basePause = randomInt(minDelayMs, maxDelayMs);
      await sleep(basePause);

      if (checkpointEvery > 0 && attemptCounter % checkpointEvery === 0) {
        const checkpointPause = randomInt(checkpointPauseMinMs, checkpointPauseMaxMs);
        await sleep(checkpointPause);
      }
    }

    const totalRowsInPublication = groupRows.length;
    let publicationStatus = statusParcial;
    if (successCount === totalRowsInPublication && totalRowsInPublication > 0) publicationStatus = statusSim;
    else if (successCount === 0) publicationStatus = statusNao;
    else publicationStatus = statusParcial;

    for (const row of groupRows) {
      row.record[statusHeader] = publicationStatus;
    }
  }

  const timestamp = new Date();
  let backupPath = '';
  if (!dryRun) {
    const stamp = timestamp.toISOString().replace(/[:.]/g, '-');
    backupPath = path.resolve(dataDir, 'backup-contatos_linkedin_envio-' + stamp + '.csv');
    fs.writeFileSync(backupPath, csvRaw, 'utf8');
  }

  const outputCsv = toCsv(outputHeaders, enrichedRows.map((r) => r.record), delimiter);
  fs.writeFileSync(spreadsheetPath, outputCsv, 'utf8');

  const datePart = timestamp.toISOString().slice(0, 10);
  const logPath = path.resolve(logsDir, 'envio-whatsapp-' + datePart + '.log');
  const logEntries = attempts.map((attempt) => JSON.stringify(attempt));

  const summary = { ts: new Date().toISOString(), dryRun, spreadsheetPath, backupPath, totals, baileysEndpoint };
  logEntries.push(JSON.stringify({ summary }));
  fs.appendFileSync(logPath, logEntries.join('\n') + '\n', 'utf8');

  return [{ json: { ok: true, dryRun, spreadsheetPath, backupPath, logPath, delimiter, totals } }];
}

return main();
