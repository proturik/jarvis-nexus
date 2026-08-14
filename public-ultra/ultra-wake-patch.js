(() => {
  const voiceKey = document.querySelector('#voice-key');
  const help = document.querySelector('#command-help');
  const core = document.querySelector('#holo-core');
  const coreText = document.querySelector('#core-text');
  const Recognition = window.SpeechRecognition || window.webkitSpeechRecognition;
  if (!voiceKey || !Recognition) {
    if (voiceKey) voiceKey.disabled = true;
    if (help) help.textContent = 'Голосовой ввод в этом окне недоступен.';
    return;
  }

  let recognizer = null;
  let wakeMode = false;
  let listening = false;
  let transcript = '';
  let restartTimer = 0;

  function setStatus(mode, text) {
    core?.classList.toggle('is-listening', mode === 'listening');
    core?.classList.toggle('is-speaking', false);
    if (coreText) coreText.textContent = text;
  }

  function clearRestart() {
    if (restartTimer) window.clearTimeout(restartTimer);
    restartTimer = 0;
  }

  function stopWake() {
    wakeMode = false;
    clearRestart();
    if (listening) recognizer?.stop();
    voiceKey.classList.remove('is-live');
    setStatus('idle', 'СЛУШАЮ КОМАНДУ');
    if (help) help.textContent = 'Голосовой режим выключен. Нажми микрофон, затем скажи: «JARVIS, открой блокнот».');
  }

  function beginListening() {
    if (!wakeMode || listening) return;
    if (window.speechSynthesis?.speaking) {
      scheduleWake(250);
      return;
    }
    try { recognizer.start(); } catch { scheduleWake(300); }
  }

  function scheduleWake(delay = 350) {
    clearRestart();
    if (!wakeMode) return;
    restartTimer = window.setTimeout(beginListening, delay);
  }

  function commandAfterWake(value) {
    const cleaned = value.trim();
    const match = cleaned.match(/(?:^|[\s,.:;!?])(?:jarvis|джарвис)(?=$|[\s,.:;!?])[\s,.:;!?-]*(.*)$/iu);
    return match ? match[1].trim() : null;
  }

  function initialiseWake() {
    if (recognizer) return;
    recognizer = new Recognition();
    recognizer.lang = 'ru-RU';
    recognizer.interimResults = true;
    recognizer.continuous = false;
    recognizer.onstart = () => {
      transcript = '';
      listening = true;
      voiceKey.classList.add('is-live');
      setStatus('listening', 'ЖДУ ФРАЗУ JARVIS');
      if (help) help.textContent = 'Режим JARVIS включён. Скажи: «JARVIS, …команда…»';
    };
    recognizer.onresult = (event) => {
      let interim = '';
      for (let index = event.resultIndex; index < event.results.length; index += 1) {
        const phrase = event.results[index][0].transcript;
        if (event.results[index].isFinal) transcript += `${transcript ? ' ' : ''}${phrase}`;
        else interim += phrase;
      }
      const input = document.querySelector('#command-input');
      if (input) input.value = transcript || interim;
    };
    recognizer.onerror = (event) => {
      if (event.error === 'not-allowed' || event.error === 'service-not-allowed') {
        wakeMode = false;
        voiceKey.classList.remove('is-live');
        if (help) help.textContent = 'Windows или Edge не дали доступ к микрофону. Разреши микрофон для JARVIS и нажми его ещё раз.';
      } else if (event.error !== 'aborted' && help) {
        help.textContent = `Голосовой контур: ${event.error}. Продолжаю ждать фразу JARVIS.`;
      }
    };
    recognizer.onend = async () => {
      const phrase = transcript.trim();
      transcript = '';
      listening = false;
      voiceKey.classList.remove('is-live');
      if (!wakeMode) return;
      const command = commandAfterWake(phrase);
      if (command) {
        if (help) help.textContent = `JARVIS услышал: «${command}»`;
        await window.nexus.send(command, 'voice');
      } else if (phrase) {
        if (help) help.textContent = 'Сначала скажи «JARVIS», затем команду. Например: «JARVIS, открой блокнот».');
      } else if (help) {
        help.textContent = 'Жду фразу JARVIS.';
      }
      scheduleWake(450);
    };
  }

  voiceKey.disabled = false;
  voiceKey.addEventListener('click', (event) => {
    event.preventDefault();
    event.stopImmediatePropagation();
    initialiseWake();
    if (wakeMode) {
      stopWake();
      return;
    }
    wakeMode = true;
    window.speechSynthesis?.cancel();
    if (help) help.textContent = 'Режим JARVIS включён. Скажи: «JARVIS, …команда…»';
    beginListening();
  }, true);

  window.addEventListener('beforeunload', stopWake);
})();
