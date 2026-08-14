const $ = (selector, root = document) => root.querySelector(selector);
const $$ = (selector, root = document) => [...root.querySelectorAll(selector)];

const ui = {
  brain: $('#brain-status'), clock: $('#clock'), commandForm: $('#command-form'), commandInput: $('#command-input'), commandHelp: $('#command-help'), confirmAction: $('#confirm-action'), confirmDetail: $('#confirm-detail'), confirmDialog: $('#confirm-dialog'), confirmTitle: $('#confirm-title'), contextDays: $('#context-days'), conversation: $('#conversation'), core: $('#holo-core'), coreText: $('#core-text'), cpu: $('#cpu-cores'), memoryCount: $('#memory-count'), memoryList: $('#memory-list'), meter: $('#meter-progress'), model: $('#model'), openSettings: $('#open-settings'), personality: $('#personality'), profileAvatar: $('#profile-avatar'), profileHint: $('#profile-hint'), profileName: $('#profile-name'), ram: $('#ram-percent'), refresh: $('#refresh-data'), settingsDialog: $('#settings-dialog'), settingsForm: $('#settings-form'), taskList: $('#task-list'), timeline: $('#timeline'), toastStack: $('#toast-stack'), uptime: $('#uptime'), voiceEnabled: $('#voice-enabled'), voiceKey: $('#voice-key'), vision: $('#vision-explainer'), clearView: $('#clear-view'), messageTemplate: $('#message-template')
};

let state = {};
let pendingAction = null;
let listening = false;
let recognition = null;
let sending = false;

async function api(path, options = {}) {
  const response = await fetch(path, { headers: { 'Content-Type': 'application/json', ...(options.headers || {}) }, ...options });
  const payload = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(payload.error || 'Контур вернул ошибку.');
  return payload;
}

function ago(value) {
  const time = new Date(value).getTime();
  const elapsed = Date.now() - time;
  if (!Number.isFinite(time) || elapsed < 60_000) return 'сейчас';
  if (elapsed < 3_600_000) return `${Math.floor(elapsed / 60_000)} мин назад`;
  return new Intl.DateTimeFormat('ru-RU', { hour: '2-digit', minute: '2-digit' }).format(new Date(value));
}

function toast(message, error = false) {
  const item = document.createElement('div');
  item.className = `toast${error ? ' error' : ''}`;
  item.textContent = message;
  ui.toastStack.append(item);
  window.setTimeout(() => item.remove(), 4700);
}

function setCore(mode = 'idle', caption = 'СЛУШАЮ КОМАНДУ') {
  ui.core.classList.toggle('is-listening', mode === 'listening');
  ui.core.classList.toggle('is-speaking', mode === 'speaking');
  ui.coreText.textContent = caption;
}

function message(role, text, timestamp = null) {
  const item = ui.messageTemplate.content.firstElementChild.cloneNode(true);
  item.classList.add(role === 'assistant' ? 'assistant' : 'user');
  $('.message-meta', item).textContent = role === 'assistant' ? `JARVIS // ${timestamp ? ago(timestamp) : 'СЕЙЧАС'}` : `ТЫ // ${timestamp ? ago(timestamp) : 'КОМАНДА'}`;
  $('.message-copy', item).textContent = text;
  ui.conversation.append(item);
  ui.conversation.scrollTop = ui.conversation.scrollHeight;
  return item;
}

function renderConversation(turns = []) {
  ui.conversation.replaceChildren();
  if (!turns.length) {
    message('assistant', 'Шеф, я загрузил пустой контур. Скажи, как тебя звать, или дай первую задачу.');
    return;
  }
  turns.slice(-30).forEach((turn) => message(turn.role === 'assistant' ? 'assistant' : 'user', turn.text, turn.at));
}

function actionCard(action) {
  const card = document.createElement('section');
  card.className = 'action-mini';
  const copy = document.createElement('div');
  const title = document.createElement('b');
  const detail = document.createElement('small');
  title.textContent = action.label;
  detail.textContent = action.detail;
  copy.append(title, detail);
  const button = document.createElement('button');
  button.type = 'button';
  button.textContent = 'ПОДТВЕРДИТЬ';
  button.addEventListener('click', () => {
    pendingAction = action;
    ui.confirmTitle.textContent = action.label;
    ui.confirmDetail.textContent = `${action.detail} Нажатие запустит именно это действие и ничего больше.`;
    ui.confirmDialog.showModal();
  });
  card.append(copy, button);
  ui.conversation.append(card);
  ui.conversation.scrollTop = ui.conversation.scrollHeight;
}

function renderProfile(profile = {}) {
  const name = profile.name || '';
  ui.profileName.textContent = name ? name : 'Твой напарник ждёт имя';
  ui.profileAvatar.textContent = name ? name.slice(0, 1).toLocaleUpperCase('ru-RU') : '?';
  ui.profileHint.textContent = name ? 'Профиль сохранён на этом ПК. Я помню это после перезапуска.' : 'Скажи: «Меня зовут …» — и я это сохраню.';
  ui.memoryCount.textContent = String(profile.facts?.length || 0);
}

function renderMemory(memories = [], profile = {}) {
  ui.memoryList.replaceChildren();
  const facts = profile.facts || [];
  const entries = [...facts.slice(-12).map((item) => ({ ...item, kind: 'profile' })), ...memories.slice(0, 18)];
  if (!entries.length) {
    const empty = document.createElement('p'); empty.className = 'empty'; empty.textContent = 'Память ещё пуста. «Запомни: …» — и этот факт останется после рестарта.'; ui.memoryList.append(empty); return;
  }
  entries.reverse().forEach((entry) => {
    const row = document.createElement('article'); row.className = 'memory-row';
    const glyph = document.createElement('i'); glyph.textContent = entry.kind === 'profile' ? '◆' : '◈';
    const copy = document.createElement('div'); const text = document.createElement('b'); const meta = document.createElement('small');
    text.textContent = entry.text; meta.textContent = `${entry.kind === 'profile' ? 'Профиль' : 'Память'} · ${ago(entry.at)}`;
    copy.append(text, meta); row.append(glyph, copy); ui.memoryList.append(row);
  });
}

function renderTasks(tasks = []) {
  ui.taskList.replaceChildren();
  if (!tasks.length) { const empty = document.createElement('p'); empty.className = 'empty'; empty.textContent = 'Пусто. Скажи: «Добавь задачу: …»'; ui.taskList.append(empty); return; }
  tasks.forEach((task) => {
    const row = document.createElement('article'); row.className = `task-row${task.done ? ' is-done' : ''}`;
    const check = document.createElement('input'); check.type = 'checkbox'; check.checked = Boolean(task.done); check.setAttribute('aria-label', `Готово: ${task.title}`);
    check.addEventListener('change', async () => { try { await api('/api/tasks/toggle', { method: 'POST', body: JSON.stringify({ id: task.id }) }); await refresh(); } catch (error) { check.checked = !check.checked; toast(error.message, true); } });
    const copy = document.createElement('div'); const title = document.createElement('b'); const meta = document.createElement('small');
    title.textContent = task.title; meta.textContent = task.done ? `Выполнено ${ago(task.completedAt)}` : `Добавлено ${ago(task.createdAt)}`;
    copy.append(title, meta); row.append(check, copy); ui.taskList.append(row);
  });
}

function renderEvents(events = []) {
  ui.timeline.replaceChildren();
  events.slice(0, 8).forEach((entry) => {
    const item = document.createElement('li'); const dot = document.createElement('i'); const copy = document.createElement('div'); const title = document.createElement('b'); const time = document.createElement('small');
    title.textContent = entry.message; time.textContent = ago(entry.at); copy.append(title, time); item.append(dot, copy); ui.timeline.append(item);
  });
  if (!events.length) ui.timeline.innerHTML = '<li><i></i><div><b>Жду первую команду</b><small>сейчас</small></div></li>';
}

function renderSystem(system = {}, settings = {}) {
  const value = Number(system.memory?.usedPercent || 0);
  ui.ram.textContent = `${value}%`; ui.meter.style.strokeDashoffset = String(Math.max(0, 151 - (151 * value) / 100));
  ui.cpu.textContent = system.cores ?? '—'; ui.uptime.textContent = system.uptimeMinutes == null ? '—' : `${system.uptimeMinutes} мин`;
  ui.brain.textContent = settings.cloudConnected ? 'CLOUD' : 'LOCAL';
  ui.brain.style.color = settings.cloudConnected ? 'var(--cyan)' : 'var(--green)';
}

function renderSettings(settings = {}) {
  ui.personality.value = settings.personality || 'street-kind'; ui.voiceEnabled.checked = Boolean(settings.voiceEnabled); ui.model.value = settings.model || '';
}

async function refresh() {
  state = await api('/api/bootstrap');
  renderProfile(state.profile); renderMemory(state.memories, state.profile); renderTasks(state.tasks); renderEvents(state.events); renderSystem(state.system, state.settings); renderSettings(state.settings);
  ui.contextDays.textContent = state.conversations?.length ? `${state.conversations.length} СОХРАНЁННЫХ РЕПЛИК` : 'КОНТЕКСТ ЧИСТ';
  if (!ui.conversation.dataset.loaded) { renderConversation(state.conversations); ui.conversation.dataset.loaded = 'yes'; }
  return state;
}

function speak(text) {
  if (!state.settings?.voiceEnabled || !('speechSynthesis' in window)) return;
  speechSynthesis.cancel();
  const voice = new SpeechSynthesisUtterance(text.replace(/\[.*?\]/gu, ''));
  voice.lang = 'ru-RU'; voice.rate = .99; voice.pitch = .83;
  const preferred = speechSynthesis.getVoices().find((candidate) => /pavel|irina|russian|ru-ru/iu.test(candidate.name) || candidate.lang.startsWith('ru'));
  if (preferred) voice.voice = preferred;
  voice.onstart = () => setCore('speaking', 'ОТВЕЧАЮ'); voice.onend = () => setCore(); voice.onerror = () => setCore();
  speechSynthesis.speak(voice);
}

async function send(forced = '') {
  const text = (forced || ui.commandInput.value).trim();
  if (!text || sending) return;
  sending = true; ui.commandInput.value = ''; message('user', text); setCore('speaking', 'ДУМАЮ');
  try {
    const result = await api('/api/chat', { method: 'POST', body: JSON.stringify({ message: text }) });
    message('assistant', result.reply); if (result.action) actionCard(result.action); else speak(result.reply);
    await refresh();
  } catch (error) { message('assistant', `Контур споткнулся: ${error.message}`); toast(error.message, true); }
  finally { sending = false; if (!speechSynthesis.speaking) setCore(); }
}

function initialiseVoice() {
  const Recognition = window.SpeechRecognition || window.webkitSpeechRecognition;
  if (!Recognition) { ui.voiceKey.disabled = true; ui.commandHelp.textContent = 'В этом браузере голосовой ввод недоступен. Текстовый контур работает полностью.'; return; }
  recognition = new Recognition(); recognition.lang = 'ru-RU'; recognition.interimResults = true; recognition.continuous = false; let finalText = '';
  recognition.onstart = () => { listening = true; ui.voiceKey.classList.add('is-live'); setCore('listening', 'СЛУШАЮ ТЕБЯ'); ui.commandHelp.textContent = 'Слушаю. Говори нормально, шеф.'; };
  recognition.onresult = (event) => { let interim = ''; for (let index = event.resultIndex; index < event.results.length; index += 1) { const phrase = event.results[index][0].transcript; if (event.results[index].isFinal) finalText += phrase; else interim += phrase; } ui.commandInput.value = finalText || interim; };
  recognition.onerror = (event) => { if (event.error !== 'aborted') toast(`Голосовой контур: ${event.error}`, true); };
  recognition.onend = () => { listening = false; ui.voiceKey.classList.remove('is-live'); if (!speechSynthesis.speaking) setCore(); ui.commandHelp.textContent = 'Голосовой контур использует браузер. Ввод, клики и системные действия всегда спрашивают разрешение.'; if (finalText.trim()) send(finalText.trim()); };
}

async function confirm() {
  if (!pendingAction) return;
  const action = pendingAction; ui.confirmAction.disabled = true; ui.confirmAction.textContent = 'ВЫПОЛНЯЮ…';
  try { const result = await api('/api/actions/execute', { method: 'POST', body: JSON.stringify({ token: action.token }) }); ui.confirmDialog.close(); message('assistant', result.message); toast(result.message); await refresh(); }
  catch (error) { toast(error.message, true); }
  finally { pendingAction = null; ui.confirmAction.disabled = false; ui.confirmAction.textContent = 'Подтвердить →'; }
}

function installEvents() {
  ui.commandForm.addEventListener('submit', (event) => { event.preventDefault(); send(); });
  ui.voiceKey.addEventListener('click', () => { if (!recognition) return; if (listening) recognition.stop(); else { try { recognition.start(); } catch { /* browser is restarting speech recognition */ } } });
  ui.clearView.addEventListener('click', () => { ui.conversation.replaceChildren(); ui.conversation.dataset.loaded = 'yes'; message('assistant', 'Экран чата чистый. Долговременная память и история на диске остались.'); });
  ui.confirmAction.addEventListener('click', confirm);
  ui.openSettings.addEventListener('click', () => ui.settingsDialog.showModal());
  ui.settingsForm.addEventListener('submit', async (event) => { event.preventDefault(); try { await api('/api/settings', { method: 'POST', body: JSON.stringify({ personality: ui.personality.value, voiceEnabled: ui.voiceEnabled.checked, model: ui.model.value.trim() }) }); ui.settingsDialog.close(); toast('Характер обновлён.'); await refresh(); } catch (error) { toast(error.message, true); } });
  ui.refresh.addEventListener('click', () => refresh().catch((error) => toast(error.message, true)));
  $$('.mode-button').forEach((button) => button.addEventListener('click', () => { $$('.mode-button').forEach((item) => item.classList.toggle('is-active', item === button)); $$('[data-panel-view]').forEach((panel) => panel.classList.toggle('is-visible', panel.dataset.panelView === button.dataset.panel)); }));
  $$('.quick-grid button').forEach((button) => button.addEventListener('click', () => send(button.dataset.command)));
  window.addEventListener('keydown', (event) => { if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === 'k') { event.preventDefault(); ui.commandInput.focus(); } });
  ui.core.addEventListener('pointermove', (event) => { const rect = ui.core.getBoundingClientRect(); const x = (event.clientX - rect.left) / rect.width - .5; const y = (event.clientY - rect.top) / rect.height - .5; $('.prism').style.transform = `rotate(45deg) translate(${x * 7}px,${y * 7}px)`; });
  ui.core.addEventListener('pointerleave', () => $('.prism').style.removeProperty('transform'));
}

function clock() { ui.clock.textContent = new Intl.DateTimeFormat('ru-RU', { hour: '2-digit', minute: '2-digit', second: '2-digit' }).format(new Date()); }

async function start() { clock(); window.setInterval(clock, 1000); installEvents(); initialiseVoice(); try { await refresh(); } catch (error) { toast(`NEXUS не запустился: ${error.message}`, true); } }
window.nexus = { api, get state() { return state; }, refresh, message, speak, toast, send };
start();
