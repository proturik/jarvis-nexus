/*
 * NEXUS OMEGA adds an opt-in screen companion in front of the local ULTRA server.
 * It never captures a frame by default. A frame is sent to OpenAI only after the
 * person explicitly enables the in-app toggle and then sends a new command.
 */
import { randomUUID } from 'node:crypto';
import http from 'node:http';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { mkdir, readFile, rename, unlink, writeFile } from 'node:fs/promises';
import { spawn } from 'node:child_process';

const ROOT = path.dirname(fileURLToPath(import.meta.url));
const DATA = path.join(ROOT, 'data');
const VISION_FILE = path.join(DATA, 'vision-consent.json');
const SCREEN_FILE = path.join(DATA, 'nexus-current-screen.jpg');
const CAPTURE_SCRIPT = path.join(ROOT, 'windows-control', 'Capture-NexusScreen.ps1');
const LAYER_SCRIPT = path.join(ROOT, 'public-omega', 'omega-layer.js');
const LOCAL_BASE = 'http://127.0.0.1:3791';
const HOST = '127.0.0.1';
const PORT = Number.parseInt(process.env.JARVIS_OMEGA_PORT || '3792', 10);
const MAX_BODY = 80 * 1024;

await loadEnv(path.join(ROOT, '.env'));
await import('./ultra-server.mjs');

let vision = { enabled: false, cloudConsent: false, lastAnalysedAt: null };

async function loadEnv(filename) {
  try {
    for (const raw of (await readFile(filename, 'utf8')).split(/\r?\n/u)) {
      const line = raw.trim();
      const separator = line.indexOf('=');
      if (!line || line.startsWith('#') || separator < 1) continue;
      const key = line.slice(0, separator).trim();
      const value = line.slice(separator + 1).trim().replace(/^(['"])(.*)\1$/u, '$2');
      if (key && process.env[key] === undefined) process.env[key] = value;
    }
  } catch { /* .env is optional */ }
}

async function readJson(filename, fallback) {
  try { return JSON.parse(await readFile(filename, 'utf8')); } catch { return fallback; }
}

async function writeJson(filename, value) {
  const temporary = `${filename}.${process.pid}.${Date.now()}.tmp`;
  await writeFile(temporary, `${JSON.stringify(value, null, 2)}\n`, 'utf8');
  await rename(temporary, filename);
}

function clean(value, limit = 1000) {
  return String(value ?? '').replace(/[\u0000-\u001F\u007F]/gu, ' ').replace(/\s+/gu, ' ').trim().slice(0, limit);
}

function secureHeaders(contentType, cache = 'no-store') {
  return {
    'Content-Type': contentType,
    'Cache-Control': cache,
    'Content-Security-Policy': "default-src 'self'; connect-src 'self'; img-src 'self' data:; style-src 'self'; script-src 'self'; base-uri 'none'; frame-ancestors 'none'",
    'Referrer-Policy': 'no-referrer',
    'X-Content-Type-Options': 'nosniff',
    'X-Frame-Options': 'DENY',
  };
}

function sendJson(response, status, body) {
  response.writeHead(status, secureHeaders('application/json; charset=utf-8'));
  response.end(JSON.stringify(body));
}

async function requestBody(request) {
  let size = 0;
  const chunks = [];
  for await (const chunk of request) {
    size += chunk.length;
    if (size > MAX_BODY) throw new Error('Запрос слишком большой.');
    chunks.push(chunk);
  }
  return Buffer.concat(chunks);
}

async function jsonBody(request) {
  const body = await requestBody(request);
  if (!body.length) return {};
  try { return JSON.parse(body.toString('utf8')); } catch { throw new Error('Нужен корректный JSON.'); }
}

async function proxy(url, request, response, body = null) {
  const upstream = await fetch(`${LOCAL_BASE}${url.pathname}${url.search}`, {
    method: request.method,
    headers: body ? { 'Content-Type': request.headers['content-type'] || 'application/json' } : undefined,
    body,
  });
  const headers = secureHeaders(upstream.headers.get('content-type') || 'application/octet-stream', upstream.headers.get('cache-control') || 'no-store');
  response.writeHead(upstream.status, headers);
  response.end(Buffer.from(await upstream.arrayBuffer()));
}

function run(command, args, timeout = 25_000) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { shell: false, windowsHide: true });
    let stdout = ''; let stderr = '';
    const timer = setTimeout(() => { child.kill(); reject(new Error('Время операции вышло.')); }, timeout);
    child.stdout.on('data', (chunk) => { stdout += chunk; });
    child.stderr.on('data', (chunk) => { stderr += chunk; });
    child.on('error', (error) => { clearTimeout(timer); reject(error); });
    child.on('close', (code) => { clearTimeout(timer); code === 0 ? resolve(stdout) : reject(new Error(clean(stderr || stdout || `Код ${code}`, 500))); });
  });
}

async function captureOneFrame() {
  try { await unlink(SCREEN_FILE); } catch { /* no prior frame */ }
  const output = await run('powershell.exe', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', CAPTURE_SCRIPT, '-OutputPath', SCREEN_FILE, '-Target', 'Primary', '-MaxWidth', '1280', '-JpegQuality', '72']);
  const result = JSON.parse(output.trim());
  if (!result.ok) throw new Error(result.error || 'Не удалось снять экран.');
  return readFile(SCREEN_FILE);
}

function outputText(payload) {
  if (typeof payload.output_text === 'string') return payload.output_text;
  return Array.isArray(payload.output)
    ? payload.output.flatMap((item) => Array.isArray(item.content) ? item.content : []).filter((part) => part.type === 'output_text' || part.type === 'text').map((part) => part.text || '').join('\n')
    : '';
}

async function visualComment(userMessage, frame) {
  const response = await fetch('https://api.openai.com/v1/responses', {
    method: 'POST',
    headers: { Authorization: `Bearer ${process.env.OPENAI_API_KEY}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({
      model: process.env.OPENAI_MODEL || 'gpt-4.1-mini',
      instructions: 'You are JARVIS NEXUS, a friendly Russian-speaking companion. The user explicitly opted in to send this one screen frame for commentary. Describe only what you can confidently see. Keep it short, warm, and useful. Never infer passwords, private data, identity, or hidden information. Do not claim you controlled the computer.',
      input: [{ role: 'user', content: [{ type: 'input_text', text: `Пользователь сказал: ${userMessage}\n\nПосмотри на текущий экран и ответь как добрый умный напарник.` }, { type: 'input_image', image_url: `data:image/jpeg;base64,${frame.toString('base64')}`, detail: 'low' }] }],
      max_output_tokens: 260,
    }),
    signal: AbortSignal.timeout(28_000),
  });
  if (!response.ok) throw new Error(`Визуальный мозг ответил ${response.status}`);
  return clean(outputText(await response.json()), 900);
}

async function enhancedChat(request, response) {
  const payload = await jsonBody(request);
  const message = clean(payload.message, 1200);
  if (!message) return sendJson(response, 400, { error: 'Скажи или напиши команду.' });

  const localResult = await fetch(`${LOCAL_BASE}/api/chat`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(payload) });
  const result = await localResult.json();
  if (!localResult.ok) return sendJson(response, localResult.status, result);

  if (!vision.enabled || !vision.cloudConsent || !process.env.OPENAI_API_KEY) return sendJson(response, 200, result);
  let frame = null;
  try {
    frame = await captureOneFrame();
    const commentary = await visualComment(message, frame);
    if (commentary) result.reply = `${result.reply}\n\n👁 ${commentary}`;
    vision.lastAnalysedAt = new Date().toISOString();
    await writeJson(VISION_FILE, vision);
  } catch (error) {
    result.reply = `${result.reply}\n\n[Визуальный контур: ${clean(error.message, 180)}]`;
  } finally {
    if (frame) { try { await unlink(SCREEN_FILE); } catch { /* privacy-first cleanup */ } }
  }
  return sendJson(response, 200, result);
}

async function bootstrap(response) {
  const base = await fetch(`${LOCAL_BASE}/api/bootstrap`);
  const state = await base.json();
  state.vision = { active: vision.enabled, cloudConsent: vision.cloudConsent, cloudReady: Boolean(process.env.OPENAI_API_KEY), lastAnalysedAt: vision.lastAnalysedAt };
  state.settings.screenCompanion = vision.enabled;
  return sendJson(response, base.status, state);
}

async function injectApp(response) {
  const base = await fetch(`${LOCAL_BASE}/ultra.js`);
  const [baseScript, layer] = await Promise.all([base.text(), readFile(LAYER_SCRIPT, 'utf8')]);
  response.writeHead(200, secureHeaders('text/javascript; charset=utf-8', 'no-cache'));
  response.end(`${baseScript}\n\n/* OMEGA screen companion overlay */\n${layer}`);
}

async function handle(request, response) {
  const url = new URL(request.url || '/', `http://${HOST}:${PORT}`);
  try {
    if (request.method === 'GET' && url.pathname === '/api/bootstrap') return bootstrap(response);
    if (request.method === 'POST' && url.pathname === '/api/chat') return enhancedChat(request, response);
    if (request.method === 'POST' && url.pathname === '/api/vision/toggle') {
      const payload = await jsonBody(request);
      const enable = payload.enabled === true;
      const consent = payload.cloudConsent === true;
      if (enable && !consent) return sendJson(response, 400, { error: 'Для экранного режима нужно явное согласие на отправку снимков в визуальный API.' });
      if (enable && !process.env.OPENAI_API_KEY) return sendJson(response, 400, { error: 'Сначала добавь OPENAI_API_KEY в локальный .env. Без ключа снимки не отправляются.' });
      vision.enabled = enable;
      vision.cloudConsent = enable ? consent : false;
      await writeJson(VISION_FILE, vision);
      return sendJson(response, 200, { vision: { active: vision.enabled, cloudConsent: vision.cloudConsent, cloudReady: Boolean(process.env.OPENAI_API_KEY), lastAnalysedAt: vision.lastAnalysedAt } });
    }
    if (request.method === 'GET' && url.pathname === '/ultra.js') return injectApp(response);
    if (request.method === 'GET' && url.pathname === '/ultra.css') return proxy(url, request, response);
    if (request.method === 'GET' && url.pathname === '/') return proxy(url, request, response);
    const body = ['GET', 'HEAD'].includes(request.method) ? null : await requestBody(request);
    return proxy(url, request, response, body.length ? body : null);
  } catch (error) {
    console.error(error);
    return sendJson(response, 400, { error: error.message || 'Ошибка NEXUS OMEGA.' });
  }
}

await mkdir(DATA, { recursive: true });
vision = { enabled: false, cloudConsent: false, lastAnalysedAt: null, ...(await readJson(VISION_FILE, {})) };
const server = http.createServer(handle);
server.listen(PORT, HOST, () => console.log(`JARVIS NEXUS OMEGA: http://${HOST}:${PORT}`));
for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, () => server.close(() => process.exit(0)));
