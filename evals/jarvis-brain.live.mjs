import assert from 'node:assert/strict';

const baseUrl = process.env.JARVIS_TEST_BASE_URL || 'http://127.0.0.1:3791';

async function request(pathname, options = {}) {
  const response = await fetch(`${baseUrl}${pathname}`, { signal: AbortSignal.timeout(130_000), ...options });
  assert.equal(response.ok, true, `${pathname} returned ${response.status}`);
  return response.json();
}

async function chat(message) {
  return request('/api/chat', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json; charset=utf-8' },
    body: JSON.stringify({ message }),
  });
}

const bootstrap = await request('/api/bootstrap');
assert.equal(bootstrap.settings.provider, 'local');
assert.match(bootstrap.brain?.knowledgeVersion || '', /^2026\.08-core-/u);

const search = await chat('будь добр, отыщи в интернете способы безопасно ускорить запуск Windows');
assert.match(search.action?.label || '', /^Поиск:/u);
assert.equal(search.action?.risk, 'normal');
assert.doesNotMatch(search.action?.label || '', /[}✅⚠]|Внимание:/iu);

const advice = await chat('помоги мне разобраться почему в игре падает FPS');
assert.equal(advice.action, null);
assert.ok(advice.reply.length >= 120, 'diagnostic answer is too shallow');
assert.match(advice.reply, /(?:причин|процессор|видеокарт|драйвер|настройк)/iu);

const ambiguous = await chat('можешь сделать это');
assert.equal(ambiguous.action, null);
assert.match(ambiguous.reply, /(?:что именно|уточни|какое действие)/iu);

const missing = await chat('будь добр, запусти приложение TotallyFakeJarvisApp');
assert.equal(missing.action, null);
assert.match(missing.reply, /не открыл/iu);

console.log('JARVIS brain live exam: PASS');
