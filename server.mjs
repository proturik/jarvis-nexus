import { createHash, randomUUID } from 'node:crypto';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { mkdir, readFile, stat, writeFile } from 'node:fs/promises';
import { spawn } from 'node:child_process';

const ROOT = path.dirname(fileURLToPath(import.meta.url));
const PUBLIC_DIR = path.join(ROOT, 'public');
const DATA_DIR = path.join(ROOT, 'data');
const SETTINGS_FILE = path.join(DATA_DIR, 'settings.json');
const MEMORY_FILE = path.join(DATA_DIR, 'memory.json');
const TASKS_FILE = path.join(DATA_DIR, 'tasks.json');
const EVENTS_FILE = path.join(DATA_DIR, 'events.json');
const HOST = '127.0.0.1';
const PORT = Number.parseInt(process.env.PORT || '3788', 10);
const MAX_BODY_BYTES = 64 * 1024;
const ACTION_TTL_MS = 3 * 60 * 1000;

loadDotEnv(path.join(ROOT, '.env'));

const DEFAULT_SETTINGS = Object.freeze({
  assistantName: 'JARVIS',
  personality: 'street-kind',
  voiceEnabled: true,
  voiceName: '',
  provider: 'auto',
  model: process.env.OPENAI_MODEL || 'gpt-4.1-mini',
  requireConfirmation: true,
});

const APP_CATALOG = Object.freeze({
  calculator: { label: 'Калькулятор', executable: 'calc.exe', args: [] },
  notepad: { label: 'Блокнот', executable: 'notepad.exe', args: [] },
  files: { label: 'Проводник', executable: 'explorer.exe', args: [] },
  settings: { label: 'Параметры Windows', executable: 'explorer.exe', args: ['ms-settings:'] },
  vscode: { label: 'Visual Studio Code', executable: 'code', args: [] },
});

const MIME_TYPES = Object.freeze({
  '.css': 'text/css; charset=utf-8',
  '.html': 'text/html; charset=utf-8',
  '.ico': 'image/x-icon',
  '.js': 'text/javascript; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.txt': 'text/plain; charset=utf-8',
});

let state = {
  settings: { ...DEFAULT_SETTINGS },
  memories: [],
  tasks: [],
  events: [],
};
const pendingActions = new Map();

function loadDotEnv(filename) {
  return readFile(filename, 'utf8')
    .then((content) => {
      for (const rawLine of content.split(/\r?\n/u)) {
        const line = rawLine.trim();
        if (!line || line.startsWith('#')) continue;
        const separator = line.indexOf('=');
        if (separator < 1) continue;
        const key = line.slice(0, separator).trim();
        const rawValue = line.slice(separator + 1).trim();
        const value = rawValue.replace(/^(['"])(.*)\1$/u, '$2');
        if (key && process.env[key] === undefined) process.env[key] = value;
      }
    })
    .catch(() => undefined);
}

async function initialise() {
  await mkdir(DATA_DIR, { recursive: true });
  await loadDotEnv(path.join(ROOT, '.env'));
  const [savedSettings, memories, tasks, events] = await Promise.all([
    readJson(SETTINGS_FILE, {}),
    readJson(MEMORY_FILE, []),
    readJson(TASKS_FILE, []),
    readJson(EVENTS_FILE, []),
  ]);

  state = {
    settings: sanitiseSettings({ ...DEFAULT_SETTINGS, ...savedSettings }),
    memories: Array.isArray(memories) ? memories.slice(-80) : [],
    tasks: Array.isArray(tasks) ? tasks.slice(-80) : [],
    events: Array.isArray(events) ? events.slice(-120) : [],
  };
  await rememberEvent('core_online', 'Ядро NEXUS запущено локально.');
}

async function readJson(filename, fallback) {
  try {
    return JSON.parse(await readFile(filename, 'utf8'));
  } catch {
    return fallback;
  }
}

async function writeJson(filename, value) {
  await writeFile(filename, `${JSON.stringify(value, null, 2)}\n`, 'utf8');
}

async function persistSettings() {
  await writeJson(SETTINGS_FILE, state.settings);
}

async function persistMemories() {
  await writeJson(MEMORY_FILE, state.memories);
}

async function persistTasks() {
  await writeJson(TASKS_FILE, state.tasks);
}

async function persistEvents() {
  await writeJson(EVENTS_FILE, state.events);
}

async function rememberEvent(type, message) {
  state.events.push({
    id: randomUUID(),
    type,
    message: cleanText(message, 260),
    at: new Date().toISOString(),
  });
  state.events = state.events.slice(-120);
  await persistEvents();
}

function cleanText(value, limit = 1000) {
  return String(value ?? '').replace(/[\u0000-\u001F\u007F]/gu, ' ').replace(/\s+/gu, ' ').trim().slice(0, limit);
}

function sanitiseSettings(input) {
  const setting = {
    ...DEFAULT_SETTINGS,
    assistantName: cleanText(input.assistantName || DEFAULT_SETTINGS.assistantName, 32) || 'JARVIS',
    personality: ['classic', 'street-kind', 'street-max'].includes(input.personality) ? input.personality : 'street-kind',
    voiceEnabled: Boolean(input.voiceEnabled),
    voiceName: cleanText(input.voiceName, 80),
    provider: ['auto', 'local', 'openai'].includes(input.provider) ? input.provider : 'auto',
    model: cleanText(input.model || DEFAULT_SETTINGS.model, 100),
    requireConfirmation: input.requireConfirmation !== false,
  };
  return setting;
}

function publicSettings() {
  return {
    ...state.settings,
    cloudConnected: Boolean(process.env.OPENAI_API_KEY),
    homeAssistantConnected: Boolean(process.env.HOME_ASSISTANT_URL && process.env.HOME_ASSISTANT_TOKEN),
  };
}

function systemSnapshot() {
  const total = os.totalmem();
  const free = os.freemem();
  const usedPercent = Math.round(((total - free) / total) * 100);
  return {
    platform: `${os.type()} ${os.release()}`,
    architecture: os.arch(),
    hostname: os.hostname(),
    uptimeMinutes: Math.floor(os.uptime() / 60),
    memory: { total, free, usedPercent },
    cores: os.cpus().length,
    localTime: new Intl.DateTimeFormat('ru-RU', { dateStyle: 'medium', timeStyle: 'short' }).format(new Date()),
  };
}

function replyPrefix() {
  if (state.settings.personality === 'classic') return 'Принято.';
  if (state.settings.personality === 'street-max') return 'Ну что, шеф, охрененно —';
  return 'Ну что, шеф,';
}

function buildSystemPrompt() {
  const personality = state.settings.personality === 'classic'
    ? 'Speak polished, calm Russian with no profanity.'
    : state.settings.personality === 'street-max'
      ? 'Speak like a clever, loyal and warm Russian streetwise sidekick. Mild profanity is okay when it adds warmth, but never use slurs, hateful language, sexual content, threats or insults aimed at the user.'
      : 'Speak like a clever, loyal and warm Russian streetwise sidekick. Use occasional very mild colloquial phrasing, never profanity as filler, never slurs, threats, demeaning language or insults aimed at the user.';
  return [
    `You are ${state.settings.assistantName} NEXUS, a private Windows assistant.`,
    personality,
    'The user is your owner and ally: be supportive, direct and useful.',
    'Answer in Russian unless the user asks for another language.',
    'Never claim a Windows, browser, smart-home, money, messaging or destructive action has happened unless the system explicitly says it succeeded.',
    'For any real-world action, say that JARVIS will request confirmation from the local safety gate.',
    'Keep answers concise unless the user asks for a detailed plan.',
  ].join('\n');
}

function fallbackReply(message, operation = null) {
  const input = message.toLocaleLowerCase('ru-RU');
  if (operation?.type === 'remember') return `${replyPrefix()} записал это в локальную память. Она хранится только в папке JARVIS.`;
  if (operation?.type === 'create_task') return `${replyPrefix()} задача в очереди. Не потеряется, даже если вкладку закрыть.`;
  if (operation?.type === 'system_status') {
    const snapshot = systemSnapshot();
    return `${replyPrefix()} система бодрая: ${snapshot.cores} потоков, память занята на ${snapshot.memory.usedPercent}%, аптайм ${snapshot.uptimeMinutes} мин.`;
  }
  if (/кто ты|что ты умеешь/u.test(input)) {
    return `${replyPrefix()} я ${state.settings.assistantName} NEXUS: голос, память, задачи, поиск, запуск разрешённых программ и безопасные сценарии. Облачный мозг подключается одной строкой в .env, без слива ключа в интерфейс.`;
  }
  if (/привет|здорова|салют/u.test(input)) return `${replyPrefix()} на месте. Говори, что разрулить.`;
  if (/спасибо|благодар/u.test(input)) return state.settings.personality === 'classic' ? 'Всегда пожалуйста.' : 'Да не за что, шеф. Я тут именно для этого.';
  if (/время|который час/u.test(input)) return `${replyPrefix()} сейчас ${new Intl.DateTimeFormat('ru-RU', { timeStyle: 'short' }).format(new Date())}.`;
  return `${replyPrefix()} понял запрос. Локальный режим уже работает; для действительно умного свободного диалога подключи модель в настройках — я возьму на себя остальное, без лишней суеты.`;
}

function detectOperation(message) {
  const original = cleanText(message, 1200);
  const input = original.toLocaleLowerCase('ru-RU');

  const memoryMatch = original.match(/^(?:запомни|помни)\s*[:,—-]?\s*(.+)$/iu);
  if (memoryMatch?.[1]) return { type: 'remember', text: cleanText(memoryMatch[1], 500) };

  const taskMatch = original.match(/^(?:добавь\s+)?(?:задачу|напоминание|напомни)\s*[:,—-]?\s*(.+)$/iu);
  if (taskMatch?.[1]) return { type: 'create_task', text: cleanText(taskMatch[1], 500) };

  if (/\b(?:статус|состояние|диагностик|скан)\b/iu.test(input)) return { type: 'system_status' };

  const appAliases = [
    ['calculator', /калькулятор|calc/iu],
    ['notepad', /блокнот|notepad/iu],
    ['files', /проводник|файлы|папк/iu],
    ['settings', /параметр|настройки windows/iu],
    ['vscode', /vscode|visual studio code|код/iu],
  ];
  if (/^(?:открой|запусти|включи)\b/iu.test(input)) {
    const found = appAliases.find(([, matcher]) => matcher.test(input));
    if (found) return { type: 'launch_app', appId: found[0] };
  }

  const searchMatch = original.match(/^(?:найди|поищи|загугли)\s+(.+)$/iu);
  if (searchMatch?.[1]) return { type: 'search_web', query: cleanText(searchMatch[1], 300) };
  if (/\bпогода\b/iu.test(input)) return { type: 'search_web', query: original };
  return null;
}

async function applyDirectOperation(operation) {
  if (operation.type === 'remember') {
    state.memories.push({ id: randomUUID(), text: operation.text, kind: 'note', at: new Date().toISOString() });
    state.memories = state.memories.slice(-80);
    await persistMemories();
    await rememberEvent('memory_saved', `Запомнено: ${operation.text}`);
  }
  if (operation.type === 'create_task') {
    state.tasks.push({ id: randomUUID(), title: operation.text, done: false, createdAt: new Date().toISOString() });
    state.tasks = state.tasks.slice(-80);
    await persistTasks();
    await rememberEvent('task_created', `Задача: ${operation.text}`);
  }
}

function issueAction(operation) {
  const id = randomUUID();
  const expiresAt = Date.now() + ACTION_TTL_MS;
  const proposed = { id, operation, expiresAt };
  pendingActions.set(id, proposed);
  cleanupPendingActions();

  if (operation.type === 'launch_app') {
    const app = APP_CATALOG[operation.appId];
    return { token: id, label: `Запустить: ${app.label}`, detail: `Открою ${app.label} в Windows.`, risk: 'normal', expiresAt };
  }
  if (operation.type === 'search_web') {
    return { token: id, label: `Найти в браузере: ${operation.query}`, detail: 'Открою поисковый запрос в браузере по умолчанию.', risk: 'normal', expiresAt };
  }
  return null;
}

function cleanupPendingActions() {
  const now = Date.now();
  for (const [token, pending] of pendingActions) {
    if (pending.expiresAt <= now) pendingActions.delete(token);
  }
}

async function askCloudModel(message, history = []) {
  if (!process.env.OPENAI_API_KEY || state.settings.provider === 'local') return null;
  const model = state.settings.model || process.env.OPENAI_MODEL;
  if (!model) return null;
  try {
    const input = [
      ...history.slice(-8).map((turn) => ({ role: turn.role === 'assistant' ? 'assistant' : 'user', content: cleanText(turn.content, 800) })),
      { role: 'user', content: message },
    ];
    const response = await fetch('https://api.openai.com/v1/responses', {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${process.env.OPENAI_API_KEY}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({ model, instructions: buildSystemPrompt(), input, max_output_tokens: 450 }),
      signal: AbortSignal.timeout(20_000),
    });
    if (!response.ok) throw new Error(`Cloud response: ${response.status}`);
    const payload = await response.json();
    const text = extractOutputText(payload);
    return text ? cleanText(text, 1800) : null;
  } catch (error) {
    await rememberEvent('cloud_unavailable', `Облачная модель недоступна: ${error.message}`);
    return null;
  }
}

function extractOutputText(payload) {
  if (typeof payload.output_text === 'string') return payload.output_text;
  if (!Array.isArray(payload.output)) return '';
  return payload.output
    .flatMap((item) => Array.isArray(item.content) ? item.content : [])
    .filter((item) => item.type === 'output_text' || item.type === 'text')
    .map((item) => item.text || '')
    .join('\n');
}

async function completeChat(message, history) {
  const operation = detectOperation(message);
  let action = null;
  if (operation?.type === 'remember' || operation?.type === 'create_task') await applyDirectOperation(operation);
  if (operation?.type === 'launch_app' || operation?.type === 'search_web') action = issueAction(operation);

  let reply = null;
  if (!action && !['remember', 'create_task', 'system_status'].includes(operation?.type)) reply = await askCloudModel(message, history);
  if (!reply) reply = fallbackReply(message, operation);
  if (action) reply = `${replyPrefix()} подготовил действие. Я не запускаю программы исподтишка — жми подтверждение, и погнали.`;
  if (operation?.type === 'system_status') reply = fallbackReply(message, operation);

  await rememberEvent('chat', `Команда: ${message}`);
  return { reply, action, source: reply && process.env.OPENAI_API_KEY && !action ? 'cloud-or-local' : 'local' };
}

function startDetached(executable, args = []) {
  const child = spawn(executable, args, { detached: true, stdio: 'ignore', windowsHide: false });
  child.unref();
}

async function executeAction(operation) {
  if (operation.type === 'launch_app') {
    const app = APP_CATALOG[operation.appId];
    if (!app) throw new Error('Приложение не входит в разрешённый каталог.');
    startDetached(app.executable, app.args);
    await rememberEvent('action_done', `Открыто: ${app.label}`);
    return { message: `${app.label} запущен.` };
  }
  if (operation.type === 'search_web') {
    const url = `https://www.google.com/search?q=${encodeURIComponent(operation.query)}`;
    startDetached('rundll32.exe', ['url.dll,FileProtocolHandler', url]);
    await rememberEvent('action_done', `Поиск: ${operation.query}`);
    return { message: `Открыл поиск: ${operation.query}.` };
  }
  throw new Error('Такое действие пока не поддерживается.');
}

function sendJson(response, statusCode, body) {
  response.writeHead(statusCode, {
    'Content-Type': 'application/json; charset=utf-8',
    'Cache-Control': 'no-store',
    'Content-Security-Policy': "default-src 'self'; connect-src 'self'; img-src 'self' data:; style-src 'self'; script-src 'self'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'",
    'X-Content-Type-Options': 'nosniff',
    'X-Frame-Options': 'DENY',
    'Referrer-Policy': 'no-referrer',
  });
  response.end(JSON.stringify(body));
}

function sendText(response, statusCode, content, type = 'text/plain; charset=utf-8') {
  response.writeHead(statusCode, {
    'Content-Type': type,
    'Cache-Control': type.includes('html') ? 'no-cache' : 'public, max-age=300',
    'Content-Security-Policy': "default-src 'self'; connect-src 'self'; img-src 'self' data:; style-src 'self'; script-src 'self'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'",
    'X-Content-Type-Options': 'nosniff',
    'X-Frame-Options': 'DENY',
    'Referrer-Policy': 'no-referrer',
  });
  response.end(content);
}

async function readBody(request) {
  const chunks = [];
  let size = 0;
  for await (const chunk of request) {
    size += chunk.length;
    if (size > MAX_BODY_BYTES) throw new Error('Запрос слишком большой.');
    chunks.push(chunk);
  }
  if (!chunks.length) return {};
  try {
    return JSON.parse(Buffer.concat(chunks).toString('utf8'));
  } catch {
    throw new Error('Ожидался корректный JSON.');
  }
}

function endpointNotFound(response) {
  sendJson(response, 404, { error: 'Маршрут не найден.' });
}

async function serveAsset(response, pathname) {
  const requested = pathname === '/' ? 'index.html' : pathname.replace(/^\/+/, '');
  const target = path.resolve(PUBLIC_DIR, requested);
  if (path.relative(PUBLIC_DIR, target).startsWith('..') || path.isAbsolute(path.relative(PUBLIC_DIR, target))) {
    sendText(response, 403, 'Forbidden');
    return;
  }
  try {
    const info = await stat(target);
    if (!info.isFile()) return sendText(response, 404, 'Not found');
    const extension = path.extname(target).toLowerCase();
    sendText(response, 200, await readFile(target), MIME_TYPES[extension] || 'application/octet-stream');
  } catch {
    sendText(response, 404, 'Not found');
  }
}

async function handle(request, response) {
  const url = new URL(request.url || '/', `http://${HOST}:${PORT}`);
  try {
    if (request.method === 'GET' && url.pathname === '/api/bootstrap') {
      sendJson(response, 200, {
        settings: publicSettings(),
        system: systemSnapshot(),
        memories: state.memories.slice(-12).reverse(),
        tasks: state.tasks.slice(-12).reverse(),
        events: state.events.slice(-12).reverse(),
        catalog: Object.entries(APP_CATALOG).map(([id, app]) => ({ id, label: app.label })),
      });
      return;
    }

    if (request.method === 'POST' && url.pathname === '/api/chat') {
      const body = await readBody(request);
      const message = cleanText(body.message, 1200);
      if (!message) return sendJson(response, 400, { error: 'Напишите или скажите команду.' });
      const history = Array.isArray(body.history) ? body.history.slice(-8).map((turn) => ({ role: turn.role, content: cleanText(turn.content, 800) })) : [];
      sendJson(response, 200, await completeChat(message, history));
      return;
    }

    if (request.method === 'POST' && url.pathname === '/api/actions/execute') {
      const body = await readBody(request);
      const token = cleanText(body.token, 80);
      const pending = pendingActions.get(token);
      if (!pending || pending.expiresAt <= Date.now()) {
        pendingActions.delete(token);
        return sendJson(response, 410, { error: 'Подтверждение устарело. Повторите команду.' });
      }
      pendingActions.delete(token);
      sendJson(response, 200, { ok: true, ...(await executeAction(pending.operation)) });
      return;
    }

    if (request.method === 'POST' && url.pathname === '/api/tasks/toggle') {
      const body = await readBody(request);
      const task = state.tasks.find((item) => item.id === cleanText(body.id, 80));
      if (!task) return sendJson(response, 404, { error: 'Задача не найдена.' });
      task.done = !task.done;
      task.completedAt = task.done ? new Date().toISOString() : null;
      await persistTasks();
      await rememberEvent('task_toggled', `${task.done ? 'Готово' : 'Возвращено'}: ${task.title}`);
      sendJson(response, 200, { task });
      return;
    }

    if (request.method === 'POST' && url.pathname === '/api/settings') {
      const body = await readBody(request);
      state.settings = sanitiseSettings({ ...state.settings, ...body });
      await persistSettings();
      await rememberEvent('settings_updated', 'Настройки NEXUS обновлены.');
      sendJson(response, 200, { settings: publicSettings() });
      return;
    }

    if (request.method === 'GET' && url.pathname === '/api/home/status') {
      const connected = Boolean(process.env.HOME_ASSISTANT_URL && process.env.HOME_ASSISTANT_TOKEN);
      return sendJson(response, 200, {
        connected,
        message: connected ? 'Home Assistant настроен. Управление включается через allowlist сервисов в .env.' : 'Home Assistant ещё не подключён.',
      });
    }

    if (url.pathname.startsWith('/api/')) return endpointNotFound(response);
    return serveAsset(response, url.pathname);
  } catch (error) {
    console.error(error);
    sendJson(response, error.message === 'Запрос слишком большой.' ? 413 : 400, { error: error.message || 'Внутренняя ошибка NEXUS.' });
  }
}

await initialise();
const server = http.createServer(handle);
server.listen(PORT, HOST, () => {
  console.log(`JARVIS NEXUS: http://${HOST}:${PORT}`);
});

function shutdown() {
  server.close(() => process.exit(0));
}
process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);

export { cleanText, detectOperation, fallbackReply, sanitiseSettings };
