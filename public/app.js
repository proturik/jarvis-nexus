const $ = (selector, root = document) => root.querySelector(selector);
const $$ = (selector, root = document) => [...root.querySelectorAll(selector)];

const dom = {
  activityList: $('#activity-list'),
  clearChat: $('#clear-chat'),
  cloudChip: $('#cloud-chip'),
  commandForm: $('#command-form'),
  commandInput: $('#command-input'),
  confirmAction: $('#confirm-action'),
  confirmDetail: $('#confirm-detail'),
  confirmDialog: $('#confirm-dialog'),
  conversation: $('#conversation'),
  coreStage: $('#core-stage'),
  coreState: $('#core-state'),
  cpuCores: $('#cpu-cores'),
  focusCommand: $('#focus-command'),
  homeStatusCopy: $('#home-status-copy'),
  homeStatusTitle: $('#home-status-title'),
  inputNote: $('#input-note'),
  memoryList: $('#memory-list'),
  memoryPercent: $('#memory-percent'),
  meterValue: $('#meter-value'),
  micButton: $('#mic-button'),
  modelInput: $('#model-input'),
  openSettings: $('#open-settings'),
  personalitySelect: $('#personality-select'),
  refreshData: $('#refresh-data'),
  refreshHome: $('#refresh-home'),
  saveSettings: $('#save-settings'),
  settingsDialog: $('#settings-dialog'),
  settingsForm: $('#settings-form'),
  taskList: $('#task-list'),
  toggleVoice: $('#toggle-voice'),
  toastRegion: $('#toast-region'),
  uptime: $('#uptime'),
  voiceEnabled: $('#voice-enabled'),
  voiceToggleLabel: $('#voice-toggle-label'),
};

const app = {
  bootstrap: null,
  history: [],
  recognition: null,
  isListening: false,
  isSending: false,
  pendingAction: null,
  activeView: 'core',
};

const viewTitles = {
  core: 'ЯДРО / ГОЛОСОВОЙ КОНТУР',
  memory: 'ПАМЯТЬ / ЛОКАЛЬНЫЙ СЛОЙ',
  automations: 'СЦЕНАРИИ / ОЧЕРЕДЬ ЗАДАЧ',
  home: 'ДОМ / ЗАЩИЩЁННЫЙ МОСТ',
};

async function request(path, options = {}) {
  const response = await fetch(path, {
    headers: { 'Content-Type': 'application/json', ...(options.headers || {}) },
    ...options,
  });
  const payload = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(payload.error || 'Контур ответил с ошибкой.');
  return payload;
}

function showToast(message, type = 'success') {
  const toast = document.createElement('div');
  toast.className = `toast${type === 'error' ? ' is-error' : ''}`;
  toast.textContent = message;
  dom.toastRegion.append(toast);
  window.setTimeout(() => toast.remove(), 4600);
}

function formatTime(value) {
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return 'сейчас';
  const delta = Date.now() - date.getTime();
  if (delta < 60_000) return 'сейчас';
  if (delta < 3_600_000) return `${Math.floor(delta / 60_000)} мин назад`;
  return new Intl.DateTimeFormat('ru-RU', { hour: '2-digit', minute: '2-digit' }).format(date);
}

function updateClock() {
  $('#clock').textContent = new Intl.DateTimeFormat('ru-RU', { hour: '2-digit', minute: '2-digit', second: '2-digit' }).format(new Date());
}

function renderSystem(system) {
  if (!system) return;
  const percent = Number(system.memory?.usedPercent || 0);
  dom.memoryPercent.textContent = `${percent}%`;
  dom.meterValue.style.strokeDashoffset = String(Math.max(0, 132 - (132 * percent) / 100));
  dom.cpuCores.textContent = String(system.cores ?? '—');
  dom.uptime.textContent = system.uptimeMinutes == null ? '—' : `${system.uptimeMinutes} мин`;
}

function renderSettings(settings) {
  if (!settings) return;
  dom.personalitySelect.value = settings.personality;
  dom.voiceEnabled.checked = Boolean(settings.voiceEnabled);
  dom.modelInput.value = settings.model || '';
  dom.voiceToggleLabel.textContent = settings.voiceEnabled ? 'Голос включён' : 'Голос выключен';
  dom.cloudChip.classList.toggle('is-cloud', Boolean(settings.cloudConnected));
  dom.cloudChip.lastElementChild.textContent = settings.cloudConnected ? `МОЗГ: ${settings.model || 'ОБЛАКО'}` : 'МОЗГ: ЛОКАЛЬНЫЙ';
}

function renderActivity(events = []) {
  dom.activityList.replaceChildren();
  if (!events.length) {
    const empty = document.createElement('li');
    empty.innerHTML = '<span></span><div><b>Ядро ожидает первую команду</b><small>сейчас</small></div>';
    dom.activityList.append(empty);
    return;
  }
  for (const event of events.slice(0, 7)) {
    const item = document.createElement('li');
    const signal = document.createElement('span');
    const copy = document.createElement('div');
    const title = document.createElement('b');
    const time = document.createElement('small');
    title.textContent = event.message;
    time.textContent = formatTime(event.at);
    copy.append(title, time);
    item.append(signal, copy);
    dom.activityList.append(item);
  }
}

function renderMemories(memories = []) {
  dom.memoryList.replaceChildren();
  if (!memories.length) {
    const empty = document.createElement('p');
    empty.className = 'empty-state';
    empty.textContent = 'Пока пусто. Скажи «Запомни: …», и здесь появится первая полезная заметка.';
    dom.memoryList.append(empty);
    return;
  }
  for (const memory of memories) {
    const row = document.createElement('article');
    row.className = 'memory-row';
    const glyph = document.createElement('div');
    glyph.className = 'memory-glyph';
    glyph.textContent = '◈';
    const copy = document.createElement('div');
    const text = document.createElement('b');
    const time = document.createElement('small');
    text.textContent = memory.text;
    time.textContent = `Сохранено ${formatTime(memory.at)}`;
    copy.append(text, time);
    row.append(glyph, copy);
    dom.memoryList.append(row);
  }
}

function renderTasks(tasks = []) {
  dom.taskList.replaceChildren();
  if (!tasks.length) {
    const empty = document.createElement('p');
    empty.className = 'empty-state';
    empty.textContent = 'Очередь чистая. Добавь задачу голосом: «Добавь задачу: …»';
    dom.taskList.append(empty);
    return;
  }
  for (const task of tasks) {
    const row = document.createElement('article');
    row.className = `task-row${task.done ? ' is-done' : ''}`;
    const checkbox = document.createElement('input');
    checkbox.className = 'task-checkbox';
    checkbox.type = 'checkbox';
    checkbox.checked = Boolean(task.done);
    checkbox.setAttribute('aria-label', `Отметить задачу «${task.title}»`);
    checkbox.addEventListener('change', async () => {
      try {
        await request('/api/tasks/toggle', { method: 'POST', body: JSON.stringify({ id: task.id }) });
        await refreshBootstrap();
      } catch (error) {
        checkbox.checked = !checkbox.checked;
        showToast(error.message, 'error');
      }
    });
    const copy = document.createElement('div');
    const title = document.createElement('b');
    const meta = document.createElement('small');
    title.textContent = task.title;
    meta.textContent = task.done ? `Готово ${formatTime(task.completedAt)}` : `Добавлено ${formatTime(task.createdAt)}`;
    copy.append(title, meta);
    row.append(checkbox, copy);
    dom.taskList.append(row);
  }
}

function addMessage(role, content) {
  const template = $('#message-template');
  const element = template.content.firstElementChild.cloneNode(true);
  const isAssistant = role === 'assistant';
  element.classList.add(isAssistant ? 'message-assistant' : 'message-user');
  $('.message-avatar', element).textContent = isAssistant ? 'J' : 'Я';
  $('.message-name', element).innerHTML = isAssistant ? 'JARVIS <span>СЕЙЧАС</span>' : 'ТЫ <span>КОМАНДА</span>';
  $('.message-copy', element).textContent = content;
  dom.conversation.append(element);
  dom.conversation.scrollTop = dom.conversation.scrollHeight;
  return element;
}

function addActionCard(action) {
  const card = document.createElement('section');
  card.className = 'action-card';
  const copy = document.createElement('div');
  const label = document.createElement('b');
  const detail = document.createElement('small');
  label.textContent = action.label;
  detail.textContent = action.detail;
  copy.append(label, detail);
  const button = document.createElement('button');
  button.type = 'button';
  button.textContent = 'Подтвердить';
  button.addEventListener('click', () => openActionDialog(action));
  card.append(copy, button);
  dom.conversation.append(card);
  dom.conversation.scrollTop = dom.conversation.scrollHeight;
}

function openActionDialog(action) {
  app.pendingAction = action;
  $('#confirm-title').textContent = action.label;
  dom.confirmDetail.textContent = `${action.detail} Это безопасный шлюз: действие произойдёт только после подтверждения.`;
  if (!dom.confirmDialog.open) dom.confirmDialog.showModal();
}

async function confirmAction() {
  if (!app.pendingAction) return;
  const action = app.pendingAction;
  dom.confirmAction.disabled = true;
  dom.confirmAction.textContent = 'Выполняю…';
  try {
    const result = await request('/api/actions/execute', { method: 'POST', body: JSON.stringify({ token: action.token }) });
    dom.confirmDialog.close();
    addMessage('assistant', result.message || 'Сделано.');
    showToast(result.message || 'Действие выполнено.');
    await refreshBootstrap();
  } catch (error) {
    showToast(error.message, 'error');
  } finally {
    app.pendingAction = null;
    dom.confirmAction.disabled = false;
    dom.confirmAction.textContent = 'Подтвердить →';
  }
}

function transitionCore(mode, text) {
  dom.coreStage.classList.toggle('is-listening', mode === 'listening');
  dom.coreStage.classList.toggle('is-speaking', mode === 'speaking');
  dom.coreState.textContent = text;
}

function speak(text) {
  if (!app.bootstrap?.settings?.voiceEnabled || !('speechSynthesis' in window)) return;
  window.speechSynthesis.cancel();
  const utterance = new SpeechSynthesisUtterance(text);
  utterance.lang = 'ru-RU';
  utterance.rate = .98;
  utterance.pitch = .86;
  const preferred = speechSynthesis.getVoices().find((voice) => /pavel|ирина|irina|russian|ru-ru/iu.test(voice.name) || /^ru/iu.test(voice.lang));
  if (preferred) utterance.voice = preferred;
  utterance.onstart = () => transitionCore('speaking', 'ОТВЕЧАЮ');
  utterance.onend = () => transitionCore('', 'СЛУШАЮ КОМАНДУ');
  utterance.onerror = () => transitionCore('', 'СЛУШАЮ КОМАНДУ');
  window.speechSynthesis.speak(utterance);
}

async function sendCommand(forcedMessage = '') {
  const message = (forcedMessage || dom.commandInput.value).trim();
  if (!message || app.isSending) return;
  app.isSending = true;
  dom.commandInput.value = '';
  addMessage('user', message);
  app.history.push({ role: 'user', content: message });
  transitionCore('speaking', 'ДУМАЮ');
  try {
    const result = await request('/api/chat', {
      method: 'POST',
      body: JSON.stringify({ message, history: app.history.slice(-8) }),
    });
    addMessage('assistant', result.reply);
    app.history.push({ role: 'assistant', content: result.reply });
    if (result.action) addActionCard(result.action);
    else speak(result.reply);
    await refreshBootstrap();
  } catch (error) {
    addMessage('assistant', `Контур споткнулся: ${error.message}`);
    showToast(error.message, 'error');
  } finally {
    app.isSending = false;
    if (!window.speechSynthesis?.speaking) transitionCore('', 'СЛУШАЮ КОМАНДУ');
  }
}

function initialiseRecognition() {
  const Recognition = window.SpeechRecognition || window.webkitSpeechRecognition;
  if (!Recognition) {
    dom.inputNote.textContent = 'Этот браузер не даёт доступ к распознаванию речи. Текстовый контур работает полностью.';
    dom.micButton.disabled = true;
    return;
  }
  const recognition = new Recognition();
  recognition.lang = 'ru-RU';
  recognition.interimResults = true;
  recognition.continuous = false;
  recognition.maxAlternatives = 1;
  let finalText = '';
  recognition.onstart = () => {
    app.isListening = true;
    dom.micButton.classList.add('is-active');
    transitionCore('listening', 'СЛУШАЮ ТЕБЯ');
    dom.inputNote.textContent = 'Слушаю. Скажи команду нормальным голосом — я пойму.';
  };
  recognition.onresult = (event) => {
    let interim = '';
    for (let index = event.resultIndex; index < event.results.length; index += 1) {
      const text = event.results[index][0].transcript;
      if (event.results[index].isFinal) finalText += text;
      else interim += text;
    }
    dom.commandInput.value = finalText || interim;
  };
  recognition.onerror = (event) => {
    if (event.error !== 'aborted') showToast(`Голосовой контур: ${event.error}. Можно написать команду.`, 'error');
  };
  recognition.onend = () => {
    app.isListening = false;
    dom.micButton.classList.remove('is-active');
    if (!window.speechSynthesis?.speaking) transitionCore('', 'СЛУШАЮ КОМАНДУ');
    dom.inputNote.textContent = 'Голосовое распознавание использует возможности браузера. Чувствительные действия всегда требуют подтверждения.';
    if (finalText.trim()) sendCommand(finalText.trim());
  };
  app.recognition = recognition;
}

function setActiveView(view) {
  app.activeView = view;
  $$('.nav-button').forEach((button) => button.classList.toggle('is-active', button.dataset.view === view));
  $$('[data-view-panel]').forEach((panel) => panel.classList.toggle('is-visible', panel.dataset.viewPanel === view));
  $('#view-title').textContent = viewTitles[view] || viewTitles.core;
  if (view === 'home') refreshHome();
}

async function refreshHome() {
  try {
    const result = await request('/api/home/status');
    dom.homeStatusTitle.textContent = result.connected ? 'Home Assistant на линии' : 'Дом ждёт подключения';
    dom.homeStatusCopy.textContent = result.message;
  } catch (error) {
    dom.homeStatusTitle.textContent = 'Мост недоступен';
    dom.homeStatusCopy.textContent = error.message;
  }
}

async function refreshBootstrap() {
  const bootstrap = await request('/api/bootstrap');
  app.bootstrap = bootstrap;
  renderSettings(bootstrap.settings);
  renderSystem(bootstrap.system);
  renderActivity(bootstrap.events);
  renderMemories(bootstrap.memories);
  renderTasks(bootstrap.tasks);
}

async function saveSettings(event) {
  event.preventDefault();
  dom.saveSettings.disabled = true;
  try {
    const result = await request('/api/settings', {
      method: 'POST',
      body: JSON.stringify({
        personality: dom.personalitySelect.value,
        voiceEnabled: dom.voiceEnabled.checked,
        model: dom.modelInput.value.trim(),
      }),
    });
    app.bootstrap.settings = result.settings;
    renderSettings(result.settings);
    dom.settingsDialog.close();
    showToast('Характер JARVIS обновлён.');
  } catch (error) {
    showToast(error.message, 'error');
  } finally {
    dom.saveSettings.disabled = false;
  }
}

function installEvents() {
  dom.commandForm.addEventListener('submit', (event) => { event.preventDefault(); sendCommand(); });
  dom.micButton.addEventListener('click', () => {
    if (!app.recognition) return;
    if (app.isListening) app.recognition.stop();
    else {
      try { app.recognition.start(); } catch { /* recognition is already restarting */ }
    }
  });
  dom.focusCommand.addEventListener('click', () => dom.commandInput.focus());
  dom.clearChat.addEventListener('click', () => {
    dom.conversation.replaceChildren();
    app.history = [];
    addMessage('assistant', 'Чисто. Контекст этого окна с нуля, локальная память и задачи на месте.');
  });
  dom.toggleVoice.addEventListener('click', async () => {
    const enabled = !app.bootstrap?.settings?.voiceEnabled;
    try {
      const result = await request('/api/settings', { method: 'POST', body: JSON.stringify({ voiceEnabled: enabled }) });
      app.bootstrap.settings = result.settings;
      renderSettings(result.settings);
      showToast(enabled ? 'Голос включён.' : 'Голос выключен.');
    } catch (error) { showToast(error.message, 'error'); }
  });
  dom.openSettings.addEventListener('click', () => dom.settingsDialog.showModal());
  dom.settingsForm.addEventListener('submit', saveSettings);
  dom.confirmAction.addEventListener('click', confirmAction);
  dom.refreshData.addEventListener('click', () => refreshBootstrap().catch((error) => showToast(error.message, 'error')));
  dom.refreshHome.addEventListener('click', refreshHome);
  $$('.nav-button').forEach((button) => button.addEventListener('click', () => setActiveView(button.dataset.view)));
  $$('.routine-card').forEach((button) => button.addEventListener('click', () => {
    const command = button.dataset.command || '';
    if (command.endsWith(': ')) { dom.commandInput.value = command; dom.commandInput.focus(); return; }
    sendCommand(command);
  }));
  window.addEventListener('keydown', (event) => {
    if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === 'k') {
      event.preventDefault();
      dom.commandInput.focus();
    }
    if (event.key === 'Escape' && app.isListening) app.recognition?.stop();
  });
  dom.coreStage.addEventListener('pointermove', (event) => {
    const rect = dom.coreStage.getBoundingClientRect();
    const x = (event.clientX - rect.left) / rect.width - .5;
    const y = (event.clientY - rect.top) / rect.height - .5;
    dom.coreStage.style.setProperty('--pointer-x', String(x));
    dom.coreStage.style.setProperty('--pointer-y', String(y));
    $('.core-shell').style.transform = `rotate(45deg) translate(${x * 8}px, ${y * 8}px)`;
  });
  dom.coreStage.addEventListener('pointerleave', () => $('.core-shell').style.removeProperty('transform'));
}

async function start() {
  updateClock();
  window.setInterval(updateClock, 1000);
  installEvents();
  initialiseRecognition();
  try {
    await refreshBootstrap();
    await refreshHome();
  } catch (error) {
    showToast(`Не удалось запустить NEXUS: ${error.message}`, 'error');
  }
}

start();
