import assert from 'node:assert/strict';
import { mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import {
  getMealsToday, getMealSummary, getWeather, listDirSafe, logMeal, readFileSafe, webSearch,
} from '../jarvis-tools.mjs';

const publicResolver = async () => [{ address: '142.250.74.206', family: 4 }];

function htmlResponse(body, status = 200) {
  return new Response(body, { status, headers: { 'content-type': 'text/html; charset=utf-8' } });
}

function jsonResponse(body, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } });
}

test('webSearch parses DuckDuckGo results and filters insecure and private hosts', async () => {
  const html = [
    '<html><body>',
    '<a rel="nofollow" class="result__a" href="https://example.com/first">First Result</a>',
    '<a class="result__snippet" href="https://example.com/first">Snippet one</a>',
    '<a class="result__a" href="https://example.org/second">Second Result</a>',
    '<a class="result__a" href="http://insecure.example.com/third">Insecure Result</a>',
    '<a class="result__a" href="https://192.168.1.1/admin">Private Host</a>',
    '</body></html>',
  ].join('');
  const results = await webSearch('example', {
    fetchImpl: async () => htmlResponse(html),
    resolveHost: publicResolver,
  });
  assert.equal(results.length, 2);
  assert.equal(results[0].title, 'First Result');
  assert.equal(results[0].url, 'https://example.com/first');
  assert.equal(results[0].snippet, 'Snippet one');
  assert.equal(results[1].title, 'Second Result');
});

test('webSearch falls back to Wikipedia when DuckDuckGo and Brave return nothing', async () => {
  const calls = [];
  const fetchImpl = async (url) => {
    calls.push(String(url));
    if (String(url).includes('duckduckgo')) return htmlResponse('<html><body>no results</body></html>');
    if (String(url).includes('brave')) return htmlResponse('<html><body></body></html>');
    return jsonResponse(['test', ['Test Article', 'Other'], ['desc one', 'desc two'], ['https://en.wikipedia.org/wiki/Test_Article', 'https://en.wikipedia.org/wiki/Other']]);
  };
  const results = await webSearch('test', { fetchImpl, resolveHost: publicResolver });
  assert.equal(calls.length, 3);
  assert.equal(results.length, 2);
  assert.equal(results[0].title, 'Test Article');
  assert.equal(results[0].url, 'https://en.wikipedia.org/wiki/Test_Article');
  assert.equal(results[0].snippet, 'desc one');
});

test('webSearch rejects redirects to loopback addresses', async () => {
  const fetchImpl = async (url) => {
    if (String(url).includes('duckduckgo')) return new Response('', { status: 302, headers: { location: 'https://127.0.0.1/secret' } });
    if (String(url).includes('brave')) return htmlResponse('<html></html>');
    return jsonResponse(['x', [], [], []]);
  };
  assert.deepEqual(await webSearch('test', { fetchImpl, resolveHost: publicResolver }), []);
});

test('getWeather maps geocode and forecast including WMO weather codes', async () => {
  const fetchImpl = async (url) => {
    if (String(url).includes('geocoding-api')) return jsonResponse({ results: [{ name: 'London', latitude: 51.5, longitude: -0.12 }] });
    return jsonResponse({ current: { temperature_2m: 21.5, relative_humidity_2m: 66, apparent_temperature: 20.1, weather_code: 0 }, daily: { temperature_2m_max: [24], temperature_2m_min: [14] } });
  };
  const weather = await getWeather('London', { fetchImpl });
  assert.equal(weather.location, 'London');
  assert.equal(weather.temperatureC, 21.5);
  assert.equal(weather.feelsLikeC, 20.1);
  assert.equal(weather.humidityPercent, 66);
  assert.equal(weather.condition, 'clear');
  assert.equal(weather.todayMaxC, 24);
  assert.equal(weather.todayMinC, 14);
});

test('getWeather maps rain from code 61 and fails gracefully', async () => {
  const fetchImpl = async (url) => {
    if (String(url).includes('geocoding-api')) return jsonResponse({ results: [{ name: 'Oslo', latitude: 59.9, longitude: 10.7 }] });
    return jsonResponse({ current: { temperature_2m: 10, relative_humidity_2m: 80, apparent_temperature: 9, weather_code: 61 }, daily: { temperature_2m_max: [12], temperature_2m_min: [6] } });
  };
  const weather = await getWeather('Oslo', { fetchImpl });
  assert.equal(weather.condition, 'rain');

  const failed = await getWeather('Nowhere', { fetchImpl: async () => new Response('oops', { status: 500 }) });
  assert.deepEqual(failed, { error: 'weather unavailable' });
});

test('logMeal persists meals, extracts calories and redacts emails', async () => {
  const dataDir = await mkdtemp(path.join(os.tmpdir(), 'jarvis-tools-meals-'));
  try {
    const first = await logMeal('Oatmeal with berries 250 kcal', { dataDir });
    const second = await logMeal('Contact chef@example.com for the lunch menu', { dataDir });
    assert.equal(first.text, 'Oatmeal with berries 250 kcal');
    assert.equal(first.calories, 250);
    assert.equal(second.text.includes('[EMAIL]'), true);
    assert.equal(second.text.includes('chef@example.com'), false);

    assert.equal((await getMealsToday({ dataDir })).length, 2);

    const summary = await getMealSummary({ dataDir });
    assert.equal(summary.count, 2);
    assert.equal(summary.items.length, 2);

    const stored = JSON.parse(await readFile(path.join(dataDir, 'nutrition.json'), 'utf8'));
    assert.equal(stored.meals.length, 2);
    assert.equal(stored.meals[0].text, 'Oatmeal with berries 250 kcal');
  } finally {
    await rm(dataDir, { recursive: true, force: true });
  }
});

test('meal readers return empty results when no file exists', async () => {
  const dataDir = await mkdtemp(path.join(os.tmpdir(), 'jarvis-tools-meals-empty-'));
  try {
    assert.deepEqual(await getMealsToday({ dataDir }), []);
    assert.deepEqual(await getMealSummary({ dataDir }), { count: 0, items: [] });
  } finally {
    await rm(dataDir, { recursive: true, force: true });
  }
});

test('readFileSafe and listDirSafe enforce roots, size and text safety', async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), 'jarvis-tools-fs-'));
  const outside = await mkdtemp(path.join(os.tmpdir(), 'jarvis-tools-outside-'));
  try {
    await writeFile(path.join(root, 'note.txt'), 'hello world', 'utf8');
    await mkdir(path.join(root, 'sub'));
    await writeFile(path.join(root, 'sub', 'nested.txt'), 'nested', 'utf8');
    await writeFile(path.join(root, 'big.txt'), 'x'.repeat(100), 'utf8');
    await writeFile(path.join(root, 'bin.dat'), Buffer.from([0xff, 0xfe, 0xfd]));
    await writeFile(path.join(outside, 'secret.txt'), 'secret', 'utf8');

    const good = await readFileSafe(path.join(root, 'note.txt'), { allowedRoots: [root] });
    assert.equal(good.ok, true);
    assert.equal(good.text, 'hello world');

    const nested = await readFileSafe(path.join(root, 'sub', 'nested.txt'), { allowedRoots: [root] });
    assert.equal(nested.ok, true);

    const outsideRead = await readFileSafe(path.join(outside, 'secret.txt'), { allowedRoots: [root] });
    assert.equal(outsideRead.ok, false);
    assert.equal(outsideRead.error.includes('outside'), true);

    const noRoots = await readFileSafe(path.join(root, 'note.txt'), { allowedRoots: [] });
    assert.equal(noRoots.ok, false);

    const tooBig = await readFileSafe(path.join(root, 'big.txt'), { maxBytes: 10, allowedRoots: [root] });
    assert.equal(tooBig.ok, false);
    assert.equal(tooBig.error.includes('large'), true);

    const binary = await readFileSafe(path.join(root, 'bin.dat'), { allowedRoots: [root] });
    assert.equal(binary.ok, false);
    assert.equal(binary.error.includes('binary'), true);

    const listing = await listDirSafe(root, { allowedRoots: [root] });
    assert.equal(listing.ok, true);
    const names = listing.entries.map((entry) => entry.name);
    assert.equal(names.includes('note.txt'), true);
    assert.equal(listing.entries.find((entry) => entry.name === 'sub')?.isDirectory, true);

    const outsideList = await listDirSafe(outside, { allowedRoots: [root] });
    assert.equal(outsideList.ok, false);
  } finally {
    await rm(root, { recursive: true, force: true });
    await rm(outside, { recursive: true, force: true });
  }
});
