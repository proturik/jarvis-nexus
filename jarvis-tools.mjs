import { randomUUID } from 'node:crypto';
import { lookup } from 'node:dns/promises';
import { lstat, mkdir, readFile, readdir, rename, writeFile } from 'node:fs/promises';
import net from 'node:net';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = path.dirname(fileURLToPath(import.meta.url));
const DEFAULT_DATA_DIR = process.env.JARVIS_DATA_DIR ? path.resolve(process.env.JARVIS_DATA_DIR) : path.join(ROOT, 'data');
const NUTRITION_FILE = 'nutrition.json';
const MAX_BODY_BYTES = 512 * 1024;
const MAX_TITLE = 160;
const MAX_SNIPPET = 400;
const MAX_MEAL_TEXT = 400;
const MAX_REDIRECTS = 3;
const MAX_DIR_ENTRIES = 200;
const BROWSER_USER_AGENT = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36';

function clean(value, limit = 500) {
  return String(value ?? '').replace(/[\u0000-\u001F\u007F]/gu, ' ').replace(/\s+/gu, ' ').trim().slice(0, limit);
}

function isPrivateIp(address) {
  if (net.isIPv4(address)) {
    const [a, b] = address.split('.').map(Number);
    return a === 10 || a === 127 || a === 0 || (a === 169 && b === 254)
      || (a === 172 && b >= 16 && b <= 31) || (a === 192 && b === 168)
      || (a === 100 && b >= 64 && b <= 127) || a >= 224;
  }
  if (net.isIPv6(address)) {
    const value = address.toLocaleLowerCase('en-US');
    if (value.startsWith('::ffff:')) return isPrivateIp(value.slice(7));
    return value === '::1' || value === '::' || value.startsWith('fc') || value.startsWith('fd')
      || /^fe[89ab]/u.test(value) || value.startsWith('ff');
  }
  return true;
}

function isUnsafeHostname(hostname) {
  const host = clean(hostname, 300).toLocaleLowerCase('en-US').replace(/\.$/u, '');
  if (!host) return true;
  if (host === 'localhost' || host.endsWith('.localhost') || host.endsWith('.local') || host.endsWith('.internal') || host.endsWith('.home.arpa')) return true;
  const bare = host.startsWith('[') && host.endsWith(']') ? host.slice(1, -1) : host;
  if (net.isIPv4(bare) || net.isIPv6(bare)) return isPrivateIp(bare);
  return false;
}

function safeHttpsUrl(rawUrl) {
  try {
    const parsed = new URL(String(rawUrl ?? ''));
    if (parsed.protocol !== 'https:') return '';
    if (parsed.username || parsed.password) return '';
    if (isUnsafeHostname(parsed.hostname)) return '';
    parsed.hash = '';
    return parsed.toString();
  } catch { return ''; }
}

async function assertSafeUrl(rawUrl, resolveHost) {
  let parsed;
  try { parsed = new URL(String(rawUrl ?? '')); } catch { throw new Error('invalid URL'); }
  if (parsed.protocol !== 'https:' || parsed.username || parsed.password) throw new Error('unsafe URL');
  if (isUnsafeHostname(parsed.hostname)) throw new Error('unsafe hostname');
  const addresses = await resolveHost(parsed.hostname, { all: true, verbatim: true });
  if (!Array.isArray(addresses) || !addresses.length || addresses.some((entry) => isPrivateIp(entry?.address))) throw new Error('unsafe resolved address');
  return parsed;
}

async function fetchWithGuard(rawUrl, { fetchImpl, resolveHost } = {}) {
  let current = await assertSafeUrl(rawUrl, resolveHost);
  for (let hop = 0; hop <= MAX_REDIRECTS; hop += 1) {
    const response = await fetchImpl(current, {
      method: 'GET', redirect: 'manual', signal: AbortSignal.timeout(20_000),
      headers: { 'User-Agent': BROWSER_USER_AGENT, Accept: 'text/html,application/json,text/plain;q=0.9' },
    });
    const status = Number(response.status);
    if ([301, 302, 303, 307, 308].includes(status)) {
      const location = response.headers?.get?.('location');
      await response.body?.cancel?.().catch(() => {});
      if (!location) throw new Error('redirect without location');
      current = await assertSafeUrl(new URL(location, current).toString(), resolveHost);
      continue;
    }
    if (!(response.ok ?? (status >= 200 && status < 300))) {
      await response.body?.cancel?.().catch(() => {});
      throw new Error(`HTTP ${status}`);
    }
    return response;
  }
  throw new Error('too many redirects');
}

async function readTextCapped(response, cap = MAX_BODY_BYTES) {
  try {
    const type = String(response.headers?.get?.('content-type') ?? '').toLocaleLowerCase('en-US');
    if (type && !/(?:text\/html|text\/plain|application\/json)/u.test(type)) return '';
    return String(await response.text() ?? '').slice(0, cap);
  } catch { return ''; }
}

function extractAttribute(tag, name) {
  const source = String(tag ?? '');
  const needle = `${name.toLocaleLowerCase('en-US')}=`;
  const index = source.toLocaleLowerCase('en-US').indexOf(needle);
  if (index === -1) return '';
  const quoteIndex = index + needle.length;
  const quote = source[quoteIndex];
  if (quote === '"' || quote === "'") {
    const end = source.indexOf(quote, quoteIndex + 1);
    return end === -1 ? '' : source.slice(quoteIndex + 1, end);
  }
  const end = source.indexOf(' ', quoteIndex);
  return source.slice(quoteIndex, end === -1 ? undefined : end);
}

function scanAnchors(source, limit, accept) {
  const html = String(source ?? '');
  const out = [];
  let cursor = 0;
  while (out.length < limit) {
    const open = html.indexOf('<a ', cursor);
    if (open === -1) break;
    const close = html.indexOf('>', open);
    if (close === -1) break;
    const tag = html.slice(open, close + 1);
    cursor = close + 1;
    const href = extractAttribute(tag, 'href');
    const endTag = html.indexOf('</a>', close);
    const text = stripTags(endTag === -1 ? '' : html.slice(close + 1, endTag));
    if (accept(tag, href, text)) out.push({ href, text });
  }
  return out;
}

function decodeEntities(text) {
  const named = { amp: '&', lt: '<', gt: '>', quot: '"', apos: "'", nbsp: ' ' };
  return String(text ?? '').replace(/&(#x[0-9a-f]+|#\d+|[a-z]+);/giu, (match, code) => {
    if (code[0] !== '#') return named[code.toLocaleLowerCase('en-US')] ?? match;
    const hex = code[1].toLocaleLowerCase('en-US') === 'x';
    const value = Number.parseInt(hex ? code.slice(2) : code.slice(1), hex ? 16 : 10);
    return Number.isFinite(value) && value > 0 && value <= 0x10ffff ? String.fromCodePoint(value) : match;
  });
}

function stripTags(text) {
  return String(text ?? '').replace(/<[^>]*>/gu, ' ');
}

function parseDuckDuckGo(html) {
  const source = String(html ?? '');
  const snippets = new Map();
  for (const item of scanAnchors(source, 30, (tag) => tag.includes('class="result__snippet"'))) {
    if (item.href && !snippets.has(item.href)) snippets.set(item.href, item.text);
  }
  return scanAnchors(source, 30, (tag) => tag.includes('class="result__a"')).map((item) => ({
    title: item.text, url: item.href, snippet: snippets.get(item.href) ?? '',
  }));
}

function parseBrave(html) {
  return scanAnchors(html, 30, (tag, href, text) => href && !href.startsWith('javascript:') && !href.startsWith('#') && text)
    .map((item) => ({ title: item.text, url: item.href, snippet: '' }));
}

function parseWikipediaJson(text) {
  try {
    const data = JSON.parse(String(text ?? ''));
    if (!Array.isArray(data)) return [];
    const [, titles = [], snippets = [], urls = []] = data;
    return titles.slice(0, 30).map((title, index) => ({
      title: String(title ?? ''), snippet: String(snippets[index] ?? ''), url: String(urls[index] ?? ''),
    }));
  } catch { return []; }
}

function normaliseResults(items, maxResults) {
  const seen = new Set();
  const out = [];
  for (const item of items) {
    if (out.length >= maxResults) break;
    const url = safeHttpsUrl(item?.url);
    if (!url || seen.has(url)) continue;
    const title = clean(decodeEntities(item?.title), MAX_TITLE);
    const snippet = clean(decodeEntities(item?.snippet), MAX_SNIPPET);
    if (!title && !snippet) continue;
    out.push({ title, url, snippet });
    seen.add(url);
  }
  return out;
}

async function searchProvider(url, parse, { fetchImpl, resolveHost, maxResults }) {
  try {
    const response = await fetchWithGuard(url, { fetchImpl, resolveHost });
    const text = await readTextCapped(response);
    return normaliseResults(parse(text), maxResults);
  } catch { return []; }
}

export async function webSearch(query, { maxResults = 5, fetchImpl = fetch, resolveHost = lookup } = {}) {
  const q = clean(query, 300);
  if (!q) return [];
  const limit = Math.max(1, Math.min(Number(maxResults) || 5, 20));
  const encoded = encodeURIComponent(q);
  const providers = [
    { url: `https://html.duckduckgo.com/html/?q=${encoded}`, parse: parseDuckDuckGo },
    { url: `https://search.brave.com/search?q=${encoded}`, parse: parseBrave },
    { url: `https://en.wikipedia.org/w/api.php?action=opensearch&search=${encoded}&limit=5&format=json`, parse: parseWikipediaJson },
  ];
  for (const provider of providers) {
    const results = await searchProvider(provider.url, provider.parse, { fetchImpl, resolveHost, maxResults: limit });
    if (results.length) return results;
  }
  return [];
}

function weatherCondition(code) {
  const value = Number(code);
  if (value === 0) return 'ясно';
  if (value === 1 || value === 2) return 'переменная облачность';
  if (value === 3) return 'пасмурно';
  if (value === 45 || value === 48) return 'туман';
  if (value >= 51 && value <= 67) return 'дождь';
  if (value >= 71 && value <= 77) return 'снег';
  if (value >= 80 && value <= 82) return 'ливни';
  if (value >= 95 && value <= 99) return 'гроза';
  return 'погода не определена';
}

function numberOrNull(value) {
  const number = Number(value);
  return Number.isFinite(number) ? number : null;
}

async function fetchJson(url, fetchImpl) {
  const response = await fetchImpl(url, { method: 'GET', redirect: 'follow', signal: AbortSignal.timeout(15_000), headers: { Accept: 'application/json', 'User-Agent': BROWSER_USER_AGENT } });
  if (!response.ok) return null;
  return response.json().catch(() => null);
}

const CITY_ALIASES = Object.freeze({
  питер: 'Санкт-Петербург',
  спб: 'Санкт-Петербург',
  петербург: 'Санкт-Петербург',
  москве: 'Москва',
  москву: 'Москва',
  казани: 'Казань',
  питере: 'Санкт-Петербург',
  самаре: 'Самара',
  самары: 'Самара',
  самару: 'Самара',
});

function cityCandidates(city) {
  const raw = clean(city, 120);
  const lower = raw.toLocaleLowerCase('ru-RU');
  const candidates = [];
  if (CITY_ALIASES[lower]) candidates.push(CITY_ALIASES[lower]);
  candidates.push(raw);
  // Russian oblique-case fallbacks: geocoding often fails on «в Казани»,
  // «в Москве», «в Питере», so retry with the trailing case ending stripped.
  for (const suffix of ['ом', 'ой', 'ем', 'ей', 'его', 'ого', 'у', 'ю', 'е', 'и', 'а', 'я', 'ь']) {
    if (raw.length - suffix.length >= 3 && lower.endsWith(suffix)) {
      candidates.push(raw.slice(0, raw.length - suffix.length));
      break;
    }
  }
  return [...new Set(candidates)];
}

async function geocodeCity(place, fetchImpl) {
  for (const candidate of cityCandidates(place)) {
    for (const language of ['ru', 'en']) {
      const geo = await fetchJson(`https://geocoding-api.open-meteo.com/v1/search?name=${encodeURIComponent(candidate)}&count=1&language=${language}&format=json`, fetchImpl);
      const first = Array.isArray(geo?.results) ? geo.results[0] : null;
      if (first && typeof first.latitude === 'number' && typeof first.longitude === 'number') return first;
    }
  }
  return null;
}

export async function getWeather(city, { fetchImpl = fetch } = {}) {
  const place = clean(city, 120);
  if (!place) return { error: 'weather unavailable' };
  try {
    const first = await geocodeCity(place, fetchImpl);
    if (!first) return { error: 'weather unavailable' };
    const data = await fetchJson(`https://api.open-meteo.com/v1/forecast?latitude=${first.latitude}&longitude=${first.longitude}&current=temperature_2m,relative_humidity_2m,apparent_temperature,weather_code&daily=temperature_2m_max,temperature_2m_min&timezone=auto`, fetchImpl);
    if (!data) return { error: 'weather unavailable' };
    const current = data.current ?? {};
    const daily = data.daily ?? {};
    return {
      location: clean(first.name, 120) || place,
      temperatureC: numberOrNull(current.temperature_2m),
      feelsLikeC: numberOrNull(current.apparent_temperature),
      humidityPercent: numberOrNull(current.relative_humidity_2m),
      condition: weatherCondition(current.weather_code),
      todayMaxC: numberOrNull(daily.temperature_2m_max?.[0]),
      todayMinC: numberOrNull(daily.temperature_2m_min?.[0]),
    };
  } catch { return { error: 'weather unavailable' }; }
}

const SECRET_PATTERNS = [
  [/\b(?:sk-[A-Za-z0-9_-]{16,}|github_pat_[A-Za-z0-9_]{16,}|gh[pousr]_[A-Za-z0-9]{16,}|xox[baprs]-[A-Za-z0-9-]{16,}|eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,})\b/gu, '[SECRET]'],
  [/\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b/giu, '[EMAIL]'],
];

function redactSecrets(value) {
  let text = String(value ?? '');
  for (const [pattern, replacement] of SECRET_PATTERNS) text = text.replace(pattern, replacement);
  return text;
}

function extractCalories(text) {
  const match = String(text ?? '').match(/(\d+(?:[.,]\d+)?)\s*(?:kcal|calories?|ккал)/iu);
  if (!match) return undefined;
  const value = Number.parseFloat(match[1].replace(',', '.'));
  return Number.isFinite(value) ? value : undefined;
}

async function readNutrition(dataDir) {
  try {
    const parsed = JSON.parse(await readFile(path.join(dataDir, NUTRITION_FILE), 'utf8'));
    return { meals: Array.isArray(parsed?.meals) ? parsed.meals.filter((meal) => meal && typeof meal === 'object') : [] };
  } catch { return { meals: [] }; }
}

async function writeNutrition(dataDir, nutrition) {
  await mkdir(dataDir, { recursive: true });
  const filename = path.join(dataDir, NUTRITION_FILE);
  const temporary = `${filename}.${process.pid}.${Date.now()}.tmp`;
  await writeFile(temporary, `${JSON.stringify(nutrition, null, 2)}\n`, 'utf8');
  await rename(temporary, filename);
}

function localDateKey(date) {
  const value = date instanceof Date && !Number.isNaN(date.getTime()) ? date : new Date();
  const month = String(value.getMonth() + 1).padStart(2, '0');
  const day = String(value.getDate()).padStart(2, '0');
  return `${value.getFullYear()}-${month}-${day}`;
}

export async function logMeal(text, { dataDir = DEFAULT_DATA_DIR } = {}) {
  const mealText = clean(redactSecrets(text), MAX_MEAL_TEXT);
  if (!mealText) return null;
  const nutrition = await readNutrition(dataDir);
  const meal = { id: randomUUID(), text: mealText, at: new Date().toISOString() };
  const calories = extractCalories(mealText);
  if (calories !== undefined) meal.calories = calories;
  nutrition.meals = [...nutrition.meals, meal].slice(-2000);
  await writeNutrition(dataDir, nutrition);
  return meal;
}

export async function getMealsToday({ dataDir = DEFAULT_DATA_DIR } = {}) {
  const nutrition = await readNutrition(dataDir);
  const today = localDateKey(new Date());
  return nutrition.meals.filter((meal) => localDateKey(new Date(meal?.at)) === today);
}

export async function getMealSummary({ dataDir = DEFAULT_DATA_DIR } = {}) {
  const nutrition = await readNutrition(dataDir);
  return { count: nutrition.meals.length, items: nutrition.meals.slice(-8) };
}

function isInside(target, root) {
  const relative = path.relative(root, target);
  if (relative === '') return true;
  const normalised = process.platform === 'win32' ? relative.toLocaleLowerCase('en-US') : relative;
  return !normalised.startsWith('..') && !path.isAbsolute(normalised);
}

function resolveRoots(allowedRoots) {
  return (Array.isArray(allowedRoots) ? allowedRoots : []).map((root) => path.resolve(String(root)));
}

export async function readFileSafe(filePath, { maxBytes = 65536, allowedRoots = [] } = {}) {
  try {
    const target = path.resolve(String(filePath ?? ''));
    const roots = resolveRoots(allowedRoots);
    if (roots.length === 0) return { ok: false, error: 'allowedRoots required' };
    if (!roots.some((root) => isInside(target, root))) return { ok: false, error: 'path outside allowed roots' };
    const info = await lstat(target);
    if (info.isSymbolicLink()) return { ok: false, error: 'symlinks not allowed' };
    if (!info.isFile()) return { ok: false, error: 'not a file' };
    if (info.size > maxBytes) return { ok: false, error: 'file too large' };
    const bytes = await readFile(target);
    if (bytes.includes(0)) return { ok: false, error: 'binary file' };
    let text;
    try {
      text = new TextDecoder('utf-8', { fatal: true }).decode(bytes);
    } catch { return { ok: false, error: 'binary or non-UTF-8 file' }; }
    return { ok: true, path: target, text };
  } catch (error) {
    return { ok: false, error: clean(error?.message, 160) || 'read failed' };
  }
}

export async function listDirSafe(dirPath, { allowedRoots = [] } = {}) {
  try {
    const target = path.resolve(String(dirPath ?? ''));
    const roots = resolveRoots(allowedRoots);
    if (roots.length === 0) return { ok: false, error: 'allowedRoots required' };
    if (!roots.some((root) => isInside(target, root))) return { ok: false, error: 'path outside allowed roots' };
    const entries = await readdir(target, { withFileTypes: true });
    const list = entries
      .sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0))
      .slice(0, MAX_DIR_ENTRIES)
      .map((entry) => ({ name: entry.name, isDirectory: entry.isDirectory() }));
    return { ok: true, entries: list };
  } catch (error) {
    return { ok: false, error: clean(error?.message, 160) || 'list failed' };
  }
}
