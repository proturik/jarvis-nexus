import { randomUUID } from 'node:crypto';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { mkdir, readFile, rename, stat, writeFile } from 'node:fs/promises';
import { spawn } from 'node:child_process';

const ROOT = path.dirname(fileURLToPath(import.meta.url));
const WEB_DIR = path.join(ROOT, 'public-ultra');
const ASSETS_DIR = path.join(ROOT, 'assets');
const DATA_DIR = path.join(ROOT, 'data');
const HOST = '127.0.0.1';
const PORT = Number.parseInt(process.env.JARVIS_ULTRA_PORT || '3791', 10);
const BODY_LIMIT = 80 * 1024;
const ACTION_LIFETIME = 3 * 60 * 1000;
const OLLAMA_CHAT_URL = 'http://127.0.0.1:11434/api/chat';
const LOCAL_VISION_URL = 'http://127.0.0.1:3793/vision';
const CONTROL_SCRIPT = path.join(ROOT, 'windows-control', 'Invoke-NexusControl.ps1');
const APP_DISCOVERY_SCRIPT = path.join(ROOT, 'windows-control', 'Find-NexusApp.ps1');
const THEME_SCRIPT = path.join(ROOT, 'windows-theme', 'Sync-Nexus-Theme.ps1');

await loadDotEnv(path.join(ROOT, '.env'));

const FILES = Object.freeze({
  conversations: path.join(DATA_DIR, 'conversations.json'),
  events: path.join(DATA_DIR, 'events.json'),
  memories: path.join(DATA_DIR, 'memory.json'),
  profile: path.join(DATA_DIR, 'profile.json'),
  settings: path.join(DATA_DIR, 'settings.json'),
  tasks: path.join(DATA_DIR, 'tasks.json'),
});

const DEFAULT_SETTINGS = Object.freeze({
  assistantName: 'JARVIS',
  personality: 'street-kind',
  voiceEnabled: true,
  provider: 'local',
  model: process.env.OPENAI_MODEL || 'gpt-4.1-mini',
  alwaysConfirm: true,
});

const APP_CATALOG = Object.freeze({
  calculator: { label: 'Калькулятор', executable: 'calc.exe', args: [] },
  discord: { label: 'Discord', executable: path.join(process.env.LOCALAPPDATA || '', 'Discord', 'Update.exe'), args: ['--processStart', 'Discord.exe'], windowTitle: 'Discord' },
  files: { label: 'Проводник', executable: 'explorer.exe', args: [] },
  notepad: { label: 'Блокнот', executable: 'notepad.exe', args: [] },
  settings: { label: 'Параметры Windows', executable: 'explorer.exe', args: ['ms-settings:'] },
  vscode: { label: 'Visual Studio Code', executable: 'code', args: [] },
});

const WEBSITE_CATALOG = Object.freeze({
  youtube: { label: 'YouTube', url: 'https://www.youtube.com/' },
  twitch: { label: 'Twitch', url: 'https://www.twitch.tv/' },
  github: { label: 'GitHub', url: 'https://github.com/' },
  gmail: { label: 'Gmail', url: 'https://mail.google.com/' },
  google: { label: 'Google', url: 'https://www.google.com/' },
  vk: { label: 'VK', url: 'https://vk.com/' },
  rutube: { label: 'Rutube', url: 'https://rutube.ru/' },
  reddit: { label: 'Reddit', url: 'https://www.reddit.com/' },
});

function resolveWebsiteIntent(input) {
  const sites = [
    ['youtube', /(?:ютуб|ютюб|youtube)/iu],
    ['twitch', /(?:твич|twitch)/iu],
    ['github', /(?:гитхаб|гит hub|github)/iu],
    ['gmail', /(?:джимейл|гмейл|gmail)/iu],
    ['google', /(?:гугл|google)/iu],
    ['vk', /(?:вконтакте|вк|vk)/iu],
    ['rutube', /(?:рутуб|rutube)/iu],
    ['reddit', /(?:реддит|reddit)/iu],
  ];
  const browsers = [
    ['google chrome', /(?:гугл\s*хром|google\s*chrome|chrome|хром)/iu],
    ['microsoft edge', /(?:microsoft\s*edge|edge|эдж)/iu],
    ['firefox', /(?:mozilla\s*firefox|firefox|фаерфокс)/iu],
    ['opera', /(?:opera|опера)/iu],
  ];
  const siteMatch = sites.find(([, expression]) => expression.test(input));
  if (!siteMatch) return null;
  const browserMatch = browsers.find(([, expression]) => expression.test(input));
  if (siteMatch[0] === 'google' && browserMatch && !/(?:сайт|страниц|поиск)/iu.test(input)) return null;
  const website = WEBSITE_CATALOG[siteMatch[0]];
  return { kind: 'website', website: siteMatch[0], browserName: browserMatch?.[0] || '', label: `Открыть ${website.label}${browserMatch ? ` в ${browserMatch[0]}` : ''}`, risk: 'normal' };
}

const MIME = Object.freeze({
  '.css': 'text/css; charset=utf-8',
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.png': 'image/png',
  '.svg': 'image/svg+xml',
});

let state = {
  conversations: [],
  events: [],
  memories: [],
  profile: { name: '', facts: [], updatedAt: null },
  settings: { ...DEFAULT_SETTINGS },
  tasks: [],
};
const pending = new Map();

async function loadDotEnv(filename) {
  try {
    const source = await readFile(filename, 'utf8');
    for (const row of source.split(/\r?\n/u)) {
      const line = row.trim();
      if (!line || line.startsWith('#')) continue;
      const index = line.indexOf('=');
      if (index < 1) continue;
      const key = line.slice(0, index).trim();
      const value = line.slice(index + 1).trim().replace(/^(['"])(.*)\1$/u, '$2');
      if (key && process.env[key] === undefined) process.env[key] = value;
    }
  } catch {
    // .env is deliberately optional.
  }
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

function sanitiseSettings(value) {
  return {
    ...DEFAULT_SETTINGS,
    assistantName: clean(value.assistantName || DEFAULT_SETTINGS.assistantName, 32) || 'JARVIS',
    personality: ['classic', 'street-kind', 'street-max'].includes(value.personality) ? value.personality : 'street-kind',
    voiceEnabled: value.voiceEnabled !== false,
    provider: ['auto', 'local', 'openai'].includes(value.provider) ? value.provider : 'auto',
    model: clean(value.model || DEFAULT_SETTINGS.model, 100),
    alwaysConfirm: value.alwaysConfirm !== false,
  };
}

function sanitiseProfile(value) {
  const facts = Array.isArray(value?.facts) ? value.facts : [];
  return {
    name: clean(value?.name, 80),
    facts: facts
      .filter((fact) => typeof fact?.text === 'string')
      .slice(-100)
      .map((fact) => ({ id: clean(fact.id, 80) || randomUUID(), text: clean(fact.text, 600), kind: clean(fact.kind || 'fact', 24), at: fact.at || new Date().toISOString() })),
    updatedAt: value?.updatedAt || null,
  };
}

async function boot() {
  await mkdir(DATA_DIR, { recursive: true });
  const [settings, profile, memories, tasks, events, conversations] = await Promise.all([
    readJson(FILES.settings, {}),
    readJson(FILES.profile, {}),
    readJson(FILES.memories, []),
    readJson(FILES.tasks, []),
    readJson(FILES.events, []),
    readJson(FILES.conversations, []),
  ]);
  state = {
    settings: sanitiseSettings({ ...DEFAULT_SETTINGS, ...settings }),
    profile: sanitiseProfile(profile),
    memories: Array.isArray(memories) ? memories.slice(-120) : [],
    tasks: Array.isArray(tasks) ? tasks.slice(-120) : [],
    events: Array.isArray(events) ? events.slice(-160) : [],
    conversations: Array.isArray(conversations) ? conversations.slice(-240) : [],
  };
  await logEvent('core_online', 'NEXUS ULTRA: долговременная память на месте.');
}

async function logEvent(type, message) {
  state.events.push({ id: randomUUID(), type, message: clean(message, 280), at: new Date().toISOString() });
  state.events = state.events.slice(-160);
  await writeJson(FILES.events, state.events);
}

async function saveConversation(role, text) {
  state.conversations.push({ id: randomUUID(), role, text: clean(text, 1800), at: new Date().toISOString() });
  state.conversations = state.conversations.slice(-240);
  await writeJson(FILES.conversations, state.conversations);
}

async function remember(text, kind = 'note') {
  const item = { id: randomUUID(), text: clean(text, 600), kind: clean(kind, 24), at: new Date().toISOString() };
  state.memories.push(item);
  state.memories = state.memories.slice(-120);
  await writeJson(FILES.memories, state.memories);
  await logEvent('memory_saved', `Запомнил: ${item.text}`);
  return item;
}

async function rememberFact(text, kind = 'fact') {
  const factText = clean(text, 600);
  if (!factText || state.profile.facts.some((fact) => fact.text.toLocaleLowerCase('ru-RU') === factText.toLocaleLowerCase('ru-RU'))) return;
  state.profile.facts.push({ id: randomUUID(), text: factText, kind, at: new Date().toISOString() });
  state.profile.facts = state.profile.facts.slice(-100);
  state.profile.updatedAt = new Date().toISOString();
  await writeJson(FILES.profile, state.profile);
  await logEvent('profile_saved', `Профиль обновлён: ${factText}`);
}

function localDateKey(value) {
  const date = new Date(value);
  return Number.isNaN(date.getTime()) ? '' : new Intl.DateTimeFormat('sv-SE').format(date);
}

function systemSnapshot() {
  const total = os.totalmem();
  const free = os.freemem();
  return {
    platform: `${os.type()} ${os.release()}`,
    cpuCores: os.cpus().length,
    uptimeMinutes: Math.floor(os.uptime() / 60),
    memoryPercent: Math.round(((total - free) / total) * 100),
    localTime: new Intl.DateTimeFormat('ru-RU', { dateStyle: 'medium', timeStyle: 'short' }).format(new Date()),
  };
}

function publicState() {
  return {
    settings: { ...state.settings, cloudConnected: Boolean(process.env.OPENAI_API_KEY), themeBackupExists: false },
    profile: state.profile,
    memories: state.memories.slice(-18).reverse(),
    tasks: state.tasks.slice(-16).reverse(),
    events: state.events.slice(-16).reverse(),
    conversations: state.conversations.slice(-40),
    system: systemSnapshot(),
  };
}

function streetPrefix() {
  if (state.settings.personality === 'classic') return 'Принято.';
  if (state.settings.personality === 'street-max') return 'Шеф, охрененно, —';
  return 'Шеф,';
}

function profileContext() {
  const name = state.profile.name ? `Пользователя зовут ${state.profile.name}.` : '';
  const facts = state.profile.facts.slice(-18).map((fact) => `- ${fact.text}`).join('\n');
  const notes = state.memories.slice(-12).map((memory) => `- ${memory.text}`).join('\n');
  return [name, facts ? `Факты о пользователе:\n${facts}` : '', notes ? `Явно сохранённые заметки:\n${notes}` : ''].filter(Boolean).join('\n\n');
}

function systemPrompt() {
  const tone = state.settings.personality === 'classic'
    ? 'Говори по-русски спокойно, умно и без мата.'
    : state.settings.personality === 'street-max'
      ? 'Говори по-русски как очень умный, лояльный и добрый уличный напарник. Допускается редкий мягкий мат для живости, но никаких оскорблений пользователя, угроз, слюров, ненависти или токсичности.'
      : 'Говори по-русски как очень умный, лояльный и добрый уличный напарник. Используй живую разговорную речь и изредка мягкие выражения, но никогда не унижай пользователя и не используй слюры, угрозы или токсичность.';
  return [
    `Ты ${state.settings.assistantName}, личный голосовой ассистент Windows.`,
    tone,
    'Ты помнишь только явно сохранённые факты и локальную историю этого помощника. Не выдумывай воспоминания.',
    'Не утверждай, что ты кликнул, ввёл текст, открыл программу, изменил Windows, отправил сообщение, купил или удалил что-либо, пока локальное ядро не подтвердит результат. Открытие приложения из строгого разрешённого списка может выполниться сразу по явной команде пользователя; всё остальное требует подтверждения.',
    'Будь конкретным и кратким, пока пользователь не просит деталей. Отвечай на смысл последней реплики, как живой близкий приятель, а не как справочник команд.',
    'Не перечисляй возможности, не говори, что сидишь или ждёшь команды, если тебя об этом не спросили. Не начинай каждую реплику с «Шеф» или одной и той же присказки.',
    'Пиши естественным разговорным русским без нарочито ломаных слов. Не копируй старые шаблоны из истории: формулируй мысль сам.',
    profileContext(),
  ].filter(Boolean).join('\n\n');
}

function extractOutput(payload) {
  if (typeof payload.output_text === 'string') return payload.output_text;
  if (!Array.isArray(payload.output)) return '';
  return payload.output.flatMap((item) => Array.isArray(item.content) ? item.content : []).filter((item) => item.type === 'output_text' || item.type === 'text').map((item) => item.text || '').join('\n');
}

async function askCloud(message) {
  if (!process.env.OPENAI_API_KEY || state.settings.provider === 'local') return null;
  try {
    const history = state.conversations.slice(-14).map((turn) => ({ role: turn.role === 'assistant' ? 'assistant' : 'user', content: turn.text }));
    const response = await fetch('https://api.openai.com/v1/responses', {
      method: 'POST',
      headers: { Authorization: `Bearer ${process.env.OPENAI_API_KEY}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ model: state.settings.model, instructions: systemPrompt(), input: [...history, { role: 'user', content: message }], max_output_tokens: 500 }),
      signal: AbortSignal.timeout(22_000),
    });
    if (!response.ok) throw new Error(`Модель вернула ${response.status}`);
    return clean(extractOutput(await response.json()), 1800) || null;
  } catch (error) {
    await logEvent('cloud_unavailable', `Облачный мозг недоступен: ${error.message}`);
    return null;
  }
}

function localBrainModels() {
  return [...new Set([
    process.env.JARVIS_LOCAL_MODEL,
    'qwen3:8b',
    'llama3.2:latest',
    'llama3.1:8b',
  ].filter(Boolean))];
}

function localModelTimeout(model) {
  return model === 'qwen3:8b' ? 45_000 : 28_000;
}

function isLegacyTemplateTurn(turn) {
  if (turn?.role !== 'assistant') return false;
  const text = clean(turn.text, 1800);
  return text.includes('Могу выполнить конкретное действие голосом')
    || text.includes('местный мозг ещё грузится')
    || text.includes('готово к выполнению. Не буду кликать')
    || /в окне\?\s*(?:ты )?в кресле\?\s*или в баре с бутылкой/iu.test(text)
    || /(?:хочешь|не хочешь),?\s*чтобы я закр/iu.test(text);
}

function hasUnconfirmedActionClaim(reply) {
  return /\b(?:открою|закрою|запущу|нажму|кликну|введу|напишу|отправлю|удалю|выключу|отключу|перемещу|открыл|закрыл|запустил|нажал|кликнул|ввёл|отправил|удалил|выключил|отключил|переместил)\b/iu.test(clean(reply, 1800));
}

function localConversation(message, includeHistory = true) {
  const history = (includeHistory ? state.conversations.filter((turn) => !isLegacyTemplateTurn(turn)).slice(-8) : []).map((turn) => ({
    role: turn.role === 'assistant' ? 'assistant' : 'user',
    content: turn.text,
  }));
  const last = history.at(-1);
  if (!last || last.role !== 'user' || last.content !== message) {
    history.push({ role: 'user', content: message });
  }
  return [{ role: 'system', content: systemPrompt() }, ...history];
}

async function askLocalBrain(message, maxTokens = 260, includeHistory = true) {
  if (state.settings.provider === 'openai') return null;
  for (const model of localBrainModels()) {
    try {
      const response = await fetch(OLLAMA_CHAT_URL, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          model,
          messages: localConversation(message, includeHistory),
          stream: false,
          think: false,
          keep_alive: '7m',
          options: { temperature: 0.82, num_predict: maxTokens },
        }),
        signal: AbortSignal.timeout(localModelTimeout(model)),
      });
      if (response.status === 404) continue;
      if (!response.ok) throw new Error(`Локальная модель вернула ${response.status}`);
      const payload = await response.json();
      const reply = clean(payload?.message?.content, 1800);
      if (reply) return reply;
    } catch (error) {
      await logEvent('local_brain_unavailable', `Локальный мозг ${model} недоступен: ${error.message}`);
      continue;
    }
  }
  return null;
}

async function askBrain(message, maxTokens = 260, includeHistory = true) {
  if (state.settings.provider === 'openai') return askCloud(message);
  const localReply = await askLocalBrain(message, maxTokens, includeHistory);
  if (localReply || state.settings.provider === 'local') return localReply;
  return askCloud(message);
}

async function askLocalVision(prompt) {
  const response = await fetch(LOCAL_VISION_URL, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ prompt: clean(prompt, 400) }),
    signal: AbortSignal.timeout(130_000),
  });
  let payload = null;
  try { payload = await response.json(); } catch { payload = null; }
  if (!response.ok || payload?.ok !== true) throw new Error(clean(payload?.error, 180) || 'Локальное зрение не ответило.');
  let answer = clean(payload.answer, 500) || 'Не смог уверенно понять происходящее на экране.';
  if (/^(?:готово|выполнено|сделано)[.!\s]*$/iu.test(answer) || hasUnconfirmedActionClaim(answer)) {
    answer = 'Экран просмотрен; действие выполнит и проверит отдельный локальный исполнитель.';
  }
  return {
    answer,
    action: payload.action && typeof payload.action === 'object' ? payload.action : null,
  };
}

async function friendlyConfirmedReply(message, result) {
  const prompt = [
    'Локальное ядро уже подтвердило факт действия: ' + clean(result.message, 220),
    'Исходная команда пользователя: ' + clean(message, 220),
    'Ответь пользователю по-русски живо и по-дружески, одним коротким предложением.',
    'Можно слегка неформально, но без оскорблений. Не добавляй новых фактов, обещаний или действий: говори только о подтверждённом результате.',
    'Не задавай встречный вопрос, не шути о местонахождении пользователя и не повторяй старые присказки. Каждый раз меняй формулировку.',
  ].join('\n');
  return await askBrain(prompt, 96, false);
}

async function friendlyProposalReply(message, operation) {
  const prompt = [
    'Пользователь запросил действие: ' + clean(message, 220),
    'Локальное ядро ещё НЕ выполнило его. Нужна явная кнопка подтверждения для: ' + clean(operation.label, 220),
    'Ответь одним коротким живым предложением по-русски. Не утверждай, что действие уже сделано; попроси подтвердить на панели.',
    'Не добавляй посторонних вопросов и не повторяй старые присказки.',
  ].join('\n');
  return await askBrain(prompt, 88, false);
}
function keyForSpokenKey(text) {
  const lookup = {
    'энтер': 'ENTER', 'enter': 'ENTER', 'ввод': 'ENTER', 'escape': 'ESC', 'эскейп': 'ESC', 'esc': 'ESC',
    'таб': 'TAB', 'tab': 'TAB', 'пробел': 'SPACE', 'backspace': 'BACKSPACE', 'бекспейс': 'BACKSPACE',
    'delete': 'DELETE', 'удалить': 'DELETE', 'вверх': 'UP', 'вниз': 'DOWN', 'влево': 'LEFT', 'вправо': 'RIGHT',
    'home': 'HOME', 'end': 'END', 'f1': 'F1', 'f2': 'F2', 'f3': 'F3', 'f4': 'F4', 'f5': 'F5', 'f6': 'F6',
    'f7': 'F7', 'f8': 'F8', 'f9': 'F9', 'f10': 'F10', 'f11': 'F11', 'f12': 'F12',
  };
  return lookup[text.toLocaleLowerCase('ru-RU')] || null;
}

function classify(message) {
  const raw = clean(message, 1200);
  const input = raw.toLocaleLowerCase('ru-RU');
  let match;

  if ((match = raw.match(/^(?:посмотри|глянь)(?:\s+(?:на|что происходит на))?\s*(?:мой\s+)?экран(?:\s+и\s+(.+))?$/iu))) return { kind: 'vision', prompt: raw, actionText: clean(match[1], 300) };
  if (/^(?:что (?:ты )?видишь|что происходит) на экране|^(?:опиши|проанализируй) экран|^помоги .{0,40}(?:на|с) экране/iu.test(input)) return { kind: 'vision', prompt: raw, actionText: '' };
  if ((match = raw.match(/^(?:запомни|помни)\s*[:,—-]?\s*(.+)$/iu))) return { kind: 'remember', text: clean(match[1], 600) };
  if ((match = raw.match(/^(?:добавь\s+)?(?:задачу|напоминание|напомни)\s*[:,—-]?\s*(.+)$/iu))) return { kind: 'task', text: clean(match[1], 600) };
  if ((match = raw.match(/^(?:меня зовут|зови меня)\s+(.+)$/iu))) return { kind: 'set_name', name: clean(match[1], 80) };
  if (/что мы (?:обсуждали|говорили) вчера|о ч[её]м мы вчера/iu.test(input)) return { kind: 'recall_yesterday' };
  if (/^(?:перемести|двинь)\s+(?:мышь|курсор)(?:\s+(?:на|в))?\s*(-?\d+)\s*[,; ]\s*(-?\d+)/iu.test(raw)) {
    match = raw.match(/(-?\d+)\s*[,; ]\s*(-?\d+)/u); return { kind: 'control', action: 'MoveMouse', x: Number(match[1]), y: Number(match[2]), label: `Переместить курсор в ${match[1]}, ${match[2]}`, risk: 'normal' };
  }
  if ((match = raw.match(/^(двойной\s+)?(?:кликни|клик|щёлкни|щелкни)(?:\s+(левой|правой|средней))?(?:\s+(?:кнопкой|мышью))?(?:\s+(?:на|в))?\s*(-?\d+)\s*[,; ]\s*(-?\d+)/iu))) {
    const button = ({ левой: 'Left', правой: 'Right', средней: 'Middle' })[match[2]?.toLocaleLowerCase('ru-RU')] || 'Left';
    return { kind: 'control', action: 'Click', x: Number(match[3]), y: Number(match[4]), button, clickKind: match[1] ? 'Double' : 'Single', label: `${match[1] ? 'Двойной клик' : 'Клик'} ${match[3]}, ${match[4]}`, risk: 'normal' };
  }
  if ((match = raw.match(/^прокрути\s+(вверх|вниз)(?:\s+на\s+(\d+))?/iu))) {
    const steps = Math.min(Number(match[2] || 4), 20); return { kind: 'control', action: 'Scroll', amount: match[1].toLocaleLowerCase('ru-RU') === 'вверх' ? steps : -steps, label: `Прокрутить ${match[1]}`, risk: 'normal' };
  }
  if ((match = raw.match(/^(?:напиши|введи|набери|напечатай)\s+(.+)$/iu))) {
    const text = clean(match[1], 1000); return { kind: 'control', action: 'TypeText', text, label: `Ввести текст: ${text.slice(0, 48)}${text.length > 48 ? '…' : ''}`, risk: /парол|password|пин|pin|код|card|карт/iu.test(text) ? 'sensitive' : 'normal' };
  }
  if ((match = raw.match(/^нажми\s+(.+)$/iu))) {
    const key = keyForSpokenKey(clean(match[1], 18)); if (key) return { kind: 'control', action: 'PressKey', key, label: `Нажать ${key}`, risk: 'normal' };
  }
  if (/^(?:скопируй|копировать)$/iu.test(input)) return { kind: 'control', action: 'Hotkey', keys: 'CTRL+C', label: 'Нажать Ctrl + C', risk: 'normal' };
  if (/^(?:вставь|вставить)$/iu.test(input)) return { kind: 'control', action: 'Hotkey', keys: 'CTRL+V', label: 'Нажать Ctrl + V', risk: 'sensitive' };
  if (/^(?:отмени|назад действие)$/iu.test(input)) return { kind: 'control', action: 'Hotkey', keys: 'CTRL+Z', label: 'Нажать Ctrl + Z', risk: 'normal' };
  if (/^(?:переключи окно|следующее окно)$/iu.test(input)) return { kind: 'control', action: 'Hotkey', keys: 'ALT+TAB', label: 'Переключить окно (Alt + Tab)', risk: 'normal' };
  if (/^(?:закрой окно|закрыть окно)$/iu.test(input)) return { kind: 'control', action: 'Hotkey', keys: 'ALT+F4', label: 'Закрыть активное окно (Alt + F4)', risk: 'sensitive' };
  if (/^(?:закрой|закрыть|выключи|останови|close)(?=$|\s|[,.!?])/iu.test(input)) {
    const requested = clean(raw.replace(/^(?:закрой|закрыть|выключи|останови|close)\s*/iu, ''), 80) || 'это приложение';
    const aliases = [
      ['Discord', /дис\s*корд|дискомфорт|discord/iu],
      ['Steam', /стим|с\s*тим|steam/iu],
      ['Google Chrome', /google chrome|chrome|хром|гугл хром/iu],
      ['Telegram', /телеграм|telegram/iu],
      ['Spotify', /спотифай|spotify/iu],
      ['Firefox', /фаерфокс|firefox/iu],
      ['Opera', /опера|opera/iu],
    ];
    const known = aliases.find(([, expression]) => expression.test(requested));
    const title = known?.[0] || requested;
    return { kind: 'close_app', title, label: `Закрыть ${title}`, risk: known ? 'normal' : 'sensitive' };
  }
  if ((match = raw.match(/^(?:переключись|активируй окно)\s+(.+)$/iu))) return { kind: 'control', action: 'FocusWindow', title: clean(match[1], 120), label: `Активировать окно: ${clean(match[1], 70)}`, risk: 'normal' };
  if (/что (?:сейчас )?(?:открыто|на экране)|покажи окна/iu.test(input)) return { kind: 'control', action: 'ListWindows', label: 'Прочитать названия открытых окон', risk: 'sensitive' };
  if (/синхронизируй (?:тему )?(?:windows|виндовс)|тема nexus|примени тему/iu.test(input)) return { kind: 'theme', mode: 'Apply', label: 'Синхронизировать Windows с NEXUS', risk: 'attention' };
  if (/верни (?:тему|оформление)|откати тему|восстанови тему/iu.test(input)) return { kind: 'theme', mode: 'Restore', label: 'Вернуть прежнюю тему Windows', risk: 'attention' };
  if (/(?:^|\s)(?:статус|состояние|диагностик|пульс системы)(?=$|\s|[,.!?])/iu.test(input)) return { kind: 'status' };
  if (/^(?:открой|запусти|open)(?=$|\s|[,.!?])/iu.test(input)) {
    const websiteIntent = resolveWebsiteIntent(input);
    if (websiteIntent) return websiteIntent;
  }
  if (/^(?:открой|запусти|включи|open)(?=$|\s|[,.!?])/iu.test(input)) {
    const aliases = [['calculator', /калькулятор|calc/iu], ['discord', /дис\s*корд|дискомфорт|discord/iu], ['notepad', /блокнот|notepad/iu], ['files', /проводник|файлы|папк/iu], ['settings', /параметр|настройки windows/iu], ['vscode', /vscode|visual studio code|код/iu]];
    const app = aliases.find(([, expression]) => expression.test(input))?.[0];
    if (app) return { kind: 'app', app, label: `Открыть ${APP_CATALOG[app].label}`, risk: 'normal' };
    return { kind: 'unsupported_app', appName: clean(raw.replace(/^(?:открой|запусти|включи|open)\s*/iu, ''), 80) || 'это приложение' };
  }
  if ((match = raw.match(/^(?:найди|поищи|загугли)\s+(.+)$/iu))) return { kind: 'search', query: clean(match[1], 300), label: `Поиск: ${clean(match[1], 90)}`, risk: 'normal' };
  if (/(?:^|\s)погода(?=$|\s|[,.!?])/iu.test(input)) return { kind: 'search', query: raw, label: `Поиск: ${raw.slice(0, 90)}`, risk: 'normal' };
  return { kind: 'chat' };
}

async function discoverProfileFact(message) {
  const raw = clean(message, 600);
  const patterns = [
    [/^мне нравится\s+(.+)$/iu, 'preference'],
    [/^я люблю\s+(.+)$/iu, 'preference'],
    [/^я работаю\s+(.+)$/iu, 'work'],
    [/^я живу\s+(.+)$/iu, 'location'],
    [/^мой (?:любимый|любимая)\s+(.+)$/iu, 'preference'],
  ];
  for (const [expression, kind] of patterns) {
    const match = raw.match(expression);
    if (match?.[1]) { await rememberFact(raw, kind); return true; }
  }
  return false;
}

function yesterdaySummary() {
  const yesterday = new Date();
  yesterday.setDate(yesterday.getDate() - 1);
  const key = localDateKey(yesterday);
  const turns = state.conversations.filter((turn) => localDateKey(turn.at) === key).slice(-12);
  if (!turns.length) return `${streetPrefix()} за вчера в локальной истории пока ничего нет. Когда поговорим, я это сохраню.`;
  const snippets = turns.filter((turn) => turn.role === 'user').map((turn) => turn.text).slice(-5);
  return `${streetPrefix()} вчера ты просил про: ${snippets.join(' · ')}. Полная история лежит локально, я её не сочиняю.`;
}

function localReply(message, operation) {
  if (operation.kind === 'chat') return `${streetPrefix()} местный мозг ещё грузится. Не буду сыпать тебе инструкциями вместо живого ответа — повтори фразу через пару секунд.`;
  if (operation.kind === 'remember') return `${streetPrefix()} записал. После перезагрузки это останется в твоей локальной памяти.`;
  if (operation.kind === 'task') return `${streetPrefix()} задача в очереди. Я её не потеряю после рестарта.`;
  if (operation.kind === 'set_name') return `${streetPrefix()} запомнил: тебя зовут ${operation.name}.`;
  if (operation.kind === 'recall_yesterday') return yesterdaySummary();
  if (operation.kind === 'status') { const system = systemSnapshot(); return `${streetPrefix()} ${system.cpuCores} потоков, память ${system.memoryPercent}%, аптайм ${system.uptimeMinutes} минут. Всё на связи.`; }
  if (operation.kind === 'app_choices') return `${streetPrefix()} нашёл несколько вариантов для «${operation.appName}»: ${operation.choices.join(' · ')}. Скажи название точнее, и открою нужное.`;
  if (operation.kind === 'unsupported_app') return `${streetPrefix()} не открыл «${operation.appName}»: в меню «Пуск» подходящей безопасной программы не нашёл. Не буду врать, что сделал.`;
  if (operation.kind === 'website') return `${streetPrefix()} готов открыть ${operation.label.replace(/^Открыть\s+/u, '')}. Подтверди действие на панели.`;
  if (/кто ты|что умеешь/u.test(message.toLocaleLowerCase('ru-RU'))) return `${streetPrefix()} я твой JARVIS: управляю мышью, клавишами, окнами и приложениями; храню профиль, задачи и разговоры локально. На реальные шаги всегда дам нормальное подтверждение.`;
  if (/привет|здорова|салют/u.test(message.toLocaleLowerCase('ru-RU'))) return `${streetPrefix()} на месте. Что сегодня разрулим?`;
  return `${streetPrefix()} понял. Могу выполнить конкретное действие голосом: «перемести мышь 900 500», «кликни 900 500», «напиши привет», «нажми enter», «открой блокнот» или «запомни: …».`;
}

async function applyDirect(operation) {
  if (operation.kind === 'remember') await remember(operation.text);
  if (operation.kind === 'task') {
    state.tasks.push({ id: randomUUID(), title: operation.text, done: false, createdAt: new Date().toISOString() });
    state.tasks = state.tasks.slice(-120);
    await writeJson(FILES.tasks, state.tasks);
    await logEvent('task_added', `Задача: ${operation.text}`);
  }
  if (operation.kind === 'set_name') {
    state.profile.name = operation.name;
    state.profile.updatedAt = new Date().toISOString();
    await writeJson(FILES.profile, state.profile);
    await logEvent('profile_saved', `Имя пользователя: ${operation.name}`);
  }
}

function propose(operation) {
  const token = randomUUID();
  const expiresAt = Date.now() + ACTION_LIFETIME;
  pending.set(token, { operation, expiresAt });
  for (const [id, item] of pending) if (item.expiresAt < Date.now()) pending.delete(id);
  const detail = operation.kind === 'control'
    ? 'Управление мышью/клавиатурой в активном Windows-сеансе.'
    : operation.kind === 'theme'
      ? 'Изменятся только личные настройки Windows; текущие значения уже защищены резервной копией.'
      : ['app', 'discovered_app'].includes(operation.kind)
        ? 'Откроется безопасный ярлык программы из меню «Пуск».'
        : operation.kind === 'close_app'
          ? 'Windows отправит обычный запрос на закрытие найденного окна и проверит, что оно исчезло.'
          : operation.kind === 'website'
            ? 'Откроется проверенный HTTPS-сайт в выбранном установленном браузере.'
            : 'Откроется поиск в браузере по умолчанию.';
  return { token, label: operation.label, detail, risk: operation.risk, expiresAt };
}

function run(command, args, timeoutMs = 18_000) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { windowsHide: true, shell: false });
    let stdout = ''; let stderr = '';
    const timeout = setTimeout(() => { child.kill(); reject(new Error('Команда превысила лимит времени.')); }, timeoutMs);
    child.stdout.on('data', (chunk) => { stdout += chunk; });
    child.stderr.on('data', (chunk) => { stderr += chunk; });
    child.on('error', (error) => { clearTimeout(timeout); reject(error); });
    child.on('close', (code) => { clearTimeout(timeout); code === 0 ? resolve(stdout) : reject(new Error(clean(stderr || stdout || `Код завершения ${code}`, 420))); });
  });
}

function discoveryQuery(name) {
  const aliases = {
    'steam': 'steam', 'стим': 'steam', 'с тим': 'steam',
    'discord': 'discord', 'дискорд': 'discord', 'дис корд': 'discord', 'дискомфорт': 'discord',
    'chrome': 'chrome', 'google chrome': 'google chrome', 'хром': 'chrome', 'гугл хром': 'chrome', 'телеграм': 'telegram',
    'спотифай': 'spotify', 'опера': 'opera', 'фаерфокс': 'firefox', 'зум': 'zoom',
    'обс': 'obs', 'эпик': 'epic games', 'батлнет': 'battle net',
  };
  const cleaned = clean(name, 80);
  return aliases[cleaned.toLocaleLowerCase('ru-RU')] || cleaned;
}

async function resolveInstalledApp(appName) {
  const requestedName = clean(appName, 80) || 'это приложение';
  if (/^(?:cmd|command prompt|powershell|pwsh|terminal|shell|bash|командная строка|терминал|консоль)$/iu.test(requestedName)) return { kind: 'unsupported_app', appName: requestedName };
  try {
    const output = await run('powershell.exe', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', APP_DISCOVERY_SCRIPT, '-Action', 'Resolve', '-Name', discoveryQuery(requestedName)], 12_000);
    const payload = JSON.parse(output.trim());
    const candidates = Array.isArray(payload.candidates) ? payload.candidates
      .map((item) => ({ label: clean(item?.label, 100), shortcut: String(item?.shortcut || ''), score: Number(item?.score || 0) }))
      .filter((item) => item.label && path.isAbsolute(item.shortcut) && path.extname(item.shortcut).toLocaleLowerCase('en-US') === '.lnk')
      .slice(0, 5) : [];
    if (candidates.length === 1 || (candidates.length > 1 && candidates[0].score >= 85 && candidates[0].score - candidates[1].score >= 10)) {
      const candidate = candidates[0];
      return { kind: 'discovered_app', label: `Открыть ${candidate.label}`, appLabel: candidate.label, shortcut: candidate.shortcut, risk: 'normal' };
    }
    if (candidates.length > 1) return { kind: 'app_choices', appName: requestedName, choices: candidates.map((item) => item.label) };
  } catch (error) {
    await logEvent('app_discovery_failed', clean(error?.message, 180) || 'Application discovery failed.');
  }
  return { kind: 'unsupported_app', appName: requestedName };
}

function launchDetached(executable, args = []) {
  return new Promise((resolve, reject) => {
    const child = spawn(executable, args, { detached: true, stdio: 'ignore', windowsHide: false, shell: false });
    child.once('error', reject);
    child.once('spawn', () => { child.unref(); resolve(); });
  });
}

async function executeControl(operation) {
  const args = ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', CONTROL_SCRIPT, '-Action', operation.action];
  if (Number.isInteger(operation.x)) args.push('-X', String(operation.x));
  if (Number.isInteger(operation.y)) args.push('-Y', String(operation.y));
  if (Number.isInteger(operation.amount)) args.push('-Amount', String(operation.amount));
  if (operation.button) args.push('-Button', operation.button);
  if (operation.clickKind) args.push('-ClickKind', operation.clickKind);
  if (operation.text) args.push('-Text', operation.text);
  if (operation.key) args.push('-Key', operation.key);
  if (operation.keys) args.push('-Keys', operation.keys);
  if (operation.title) args.push('-Title', operation.title);
  const output = await run('powershell.exe', args);
  const result = JSON.parse(output.trim());
  if (!result.ok) throw new Error(result.error || 'Windows отказался выполнить действие.');
  if (operation.action === 'ListWindows') {
    const titles = (result.windows || []).map((item) => item.title).filter(Boolean).slice(0, 10);
    return { message: titles.length ? `Вижу открытые окна: ${titles.join(' · ')}` : 'Видимых окон не найдено.' };
  }
  return { message: `Сделано: ${operation.label}.` };
}

async function execute(operation) {
  if (operation.kind === 'control') return executeControl(operation);
  if (operation.kind === 'close_app') {
    const result = await executeControl({ kind: 'control', action: 'CloseWindow', title: operation.title, label: operation.label, risk: operation.risk });
    return { message: result.message.replace(/^Сделано:\s*/u, '') };
  }
  if (operation.kind === 'discovered_app') {
    const output = await run('powershell.exe', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', APP_DISCOVERY_SCRIPT, '-Action', 'Launch', '-Shortcut', operation.shortcut], 18_000);
    const result = JSON.parse(output.trim());
    if (result.ok !== true || !clean(result.label, 100)) throw new Error('Windows did not confirm application launch.');
    return { message: `${clean(result.label, 100)} запущен.` };
  }
  if (operation.kind === 'app') {
    const app = APP_CATALOG[operation.app];
    if (!app) throw new Error('Приложение не входит в каталог JARVIS.');
    await launchDetached(app.executable, app.args);
    if (app.windowTitle) {
      for (let attempt = 0; attempt < 8; attempt += 1) {
        await new Promise((resolve) => setTimeout(resolve, 500));
        try {
          await executeControl({ kind: 'control', action: 'FocusWindow', title: app.windowTitle, label: `Показать ${app.label}`, risk: 'normal' });
          return { message: `${app.label} запущен и выведен на экран.` };
        } catch {
          // The program may still be starting; retry only within the bounded window.
        }
      }
      return { message: `${app.label} запущен; окно ещё загружается.` };
    }
    return { message: `${app.label} запущен.` };
  }
  if (operation.kind === 'search') {
    const url = `https://www.google.com/search?q=${encodeURIComponent(operation.query)}`;
    await launchDetached('rundll32.exe', ['url.dll,FileProtocolHandler', url]);
    return { message: `Открыл поиск: ${operation.query}.` };
  }
  if (operation.kind === 'website') {
    const website = WEBSITE_CATALOG[operation.website];
    if (!website) throw new Error('Сайт не входит в безопасный каталог JARVIS.');
    if (operation.browserName) {
      const output = await run('powershell.exe', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', APP_DISCOVERY_SCRIPT, '-Action', 'LaunchUrl', '-Name', operation.browserName, '-Url', website.url], 18_000);
      const result = JSON.parse(output.trim());
      if (result.ok !== true || !clean(result.label, 100)) throw new Error('Windows did not confirm browser launch.');
      return { message: `${website.label} открыт в ${clean(result.label, 100)}.` };
    }
    await launchDetached('rundll32.exe', ['url.dll,FileProtocolHandler', website.url]);
    return { message: `${website.label} открыт в браузере по умолчанию.` };
  }
  if (operation.kind === 'theme') {
    await run('powershell.exe', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', THEME_SCRIPT, '-Mode', operation.mode]);
    return { message: operation.mode === 'Apply' ? 'Windows синхронизирована с NEXUS: тёмный режим, прозрачность и акцент применены.' : 'Прежние значения темы Windows восстановлены из резервной копии.' };
  }
  throw new Error('Неподдерживаемое действие.');
}

async function chat(message) {
  let operation = classify(message);
  let visionReply = null;
  if (operation.kind === 'vision') {
    try {
      const vision = await askLocalVision(operation.prompt);
      visionReply = vision.answer;
      let planned = operation.actionText ? classify(operation.actionText) : { kind: 'vision_result' };
      if (planned.kind === 'unsupported_app') planned = await resolveInstalledApp(planned.appName);
      const actionable = ['control', 'app', 'discovered_app', 'close_app', 'website', 'search', 'theme'].includes(planned.kind);
      if (actionable) {
        operation = planned;
      } else if (vision.action?.type === 'click' && Number.isInteger(vision.action.x) && Number.isInteger(vision.action.y)) {
        operation = { kind: 'control', action: 'Click', x: vision.action.x, y: vision.action.y, button: 'Left', clickKind: 'Single', label: `VISION: нажать ${vision.action.x}, ${vision.action.y}`, risk: 'sensitive' };
      } else {
        operation = { kind: 'vision_result' };
      }
    } catch (error) {
      visionReply = `${streetPrefix()} не смог посмотреть на экран: ${clean(error?.message, 220) || 'локальное зрение недоступно.'}`;
      operation = { kind: 'vision_result' };
    }
  }
  if (operation.kind === 'unsupported_app') operation = await resolveInstalledApp(operation.appName);
  await discoverProfileFact(message);
  await saveConversation('user', message);
  if (['remember', 'task', 'set_name'].includes(operation.kind)) await applyDirect(operation);

  let action = null;
  let reply = visionReply;
  if (['app', 'discovered_app', 'close_app', 'website'].includes(operation.kind) && operation.risk === 'normal' && state.settings.alwaysConfirm === false) {
    try {
      const result = await execute(operation);
      const confirmedReply = await friendlyConfirmedReply(message, result) || `${streetPrefix()} ${result.message}`;
      reply = [visionReply, confirmedReply].filter(Boolean).join('\n\n');
      await logEvent('action_done', result.message);
    } catch (error) {
      const reason = clean(error && error.message, 240) || 'Windows не подтвердил действие.';
      const failureReply = operation.kind === 'close_app'
        ? `${streetPrefix()} не закрыл ${operation.title}: ${reason}`
        : `${streetPrefix()} не открыл ${operation.label.replace(/^Открыть\s+/u, '')}: ${reason}`;
      reply = [visionReply, failureReply].filter(Boolean).join('\n\n');
      await logEvent('action_failed', reason);
    }
  } else if (['control', 'app', 'discovered_app', 'close_app', 'website', 'search', 'theme'].includes(operation.kind)) {
    action = propose(operation);
    const proposalReply = await friendlyProposalReply(message, operation);
    reply = [visionReply, proposalReply].filter(Boolean).join('\n\n');
  } else if (operation.kind === 'chat') {
    reply = await askBrain(message);
    if (reply && (isLegacyTemplateTurn({ role: 'assistant', text: reply }) || hasUnconfirmedActionClaim(reply))) {
      const retryPrompt = [
        'Последняя реплика пользователя: ' + clean(message, 400),
        'Это обычный разговор, а не команда управления компьютером.',
        'Ответь только на последнюю реплику живо, кратко и по-русски. Не продолжай старые поручения, не обещай и не заявляй никаких действий на ПК.',
      ].join('\n');
      reply = await askBrain(retryPrompt, 180, false);
    }
  }
  reply ||= localReply(message, operation);
  await saveConversation('assistant', reply);
  await logEvent('conversation', `Диалог: ${message}`);
  return { reply, action };
}

function headers(type, cache = 'no-store') {
  return {
    'Content-Type': type,
    'Cache-Control': cache,
    'Content-Security-Policy': "default-src 'self'; connect-src 'self'; img-src 'self' data:; script-src 'self'; style-src 'self'; base-uri 'none'; frame-ancestors 'none'",
    'Referrer-Policy': 'no-referrer', 'X-Content-Type-Options': 'nosniff', 'X-Frame-Options': 'DENY',
  };
}

function json(response, statusCode, body) { response.writeHead(statusCode, headers('application/json; charset=utf-8')); response.end(JSON.stringify(body)); }
async function bodyOf(request) {
  let size = 0; const chunks = [];
  for await (const chunk of request) { size += chunk.length; if (size > BODY_LIMIT) throw new Error('Запрос слишком большой.'); chunks.push(chunk); }
  if (!chunks.length) return {};
  try { return JSON.parse(Buffer.concat(chunks).toString('utf8')); } catch { throw new Error('Нужен корректный JSON.'); }
}

async function staticFile(response, directory, requested, cache = 'public, max-age=300') {
  const target = path.resolve(directory, requested);
  const relative = path.relative(directory, target);
  if (relative.startsWith('..') || path.isAbsolute(relative)) { response.writeHead(403); response.end(); return; }
  try {
    const info = await stat(target);
    if (!info.isFile()) throw new Error('not a file');
    const type = MIME[path.extname(target).toLowerCase()] || 'application/octet-stream';
    response.writeHead(200, headers(type, cache)); response.end(await readFile(target));
  } catch { response.writeHead(404); response.end('Not found'); }
}

async function handle(request, response) {
  const url = new URL(request.url || '/', `http://${HOST}:${PORT}`);
  try {
    if (request.method === 'GET' && url.pathname === '/api/bootstrap') return json(response, 200, publicState());
    if (request.method === 'POST' && url.pathname === '/api/chat') {
      const payload = await bodyOf(request); const message = clean(payload.message, 1200);
      if (!message) return json(response, 400, { error: 'Скажи или напиши команду.' });
      return json(response, 200, await chat(message));
    }
    if (request.method === 'POST' && url.pathname === '/api/actions/execute') {
      const payload = await bodyOf(request); const token = clean(payload.token, 100); const item = pending.get(token);
      pending.delete(token);
      if (!item || item.expiresAt < Date.now()) return json(response, 410, { error: 'Подтверждение устарело. Скажи команду ещё раз.' });
      const result = await execute(item.operation); await logEvent('action_done', result.message); return json(response, 200, { ok: true, ...result });
    }
    if (request.method === 'POST' && url.pathname === '/api/tasks/toggle') {
      const payload = await bodyOf(request); const item = state.tasks.find((task) => task.id === clean(payload.id, 100));
      if (!item) return json(response, 404, { error: 'Задача не найдена.' });
      item.done = !item.done; item.completedAt = item.done ? new Date().toISOString() : null; await writeJson(FILES.tasks, state.tasks); return json(response, 200, { task: item });
    }
    if (request.method === 'POST' && url.pathname === '/api/settings') {
      const payload = await bodyOf(request); state.settings = sanitiseSettings({ ...state.settings, ...payload }); await writeJson(FILES.settings, state.settings); await logEvent('settings', 'Настройки характера обновлены.'); return json(response, 200, { settings: publicState().settings });
    }
    if (url.pathname.startsWith('/api/')) return json(response, 404, { error: 'Маршрут не найден.' });
    if (url.pathname.startsWith('/assets/')) return staticFile(response, ASSETS_DIR, url.pathname.slice('/assets/'.length));
    return staticFile(response, WEB_DIR, url.pathname === '/' ? 'index.html' : url.pathname.slice(1), url.pathname === '/' ? 'no-cache' : 'public, max-age=300');
  } catch (error) { console.error(error); return json(response, 400, { error: error.message || 'Ошибка NEXUS.' }); }
}

await boot();
const server = http.createServer(handle);
server.listen(PORT, HOST, () => console.log(`JARVIS NEXUS ULTRA: http://${HOST}:${PORT}`));
for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, () => server.close(() => process.exit(0)));
