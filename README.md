# JARVIS NEXUS ULTRA

Локальный голосовой ассистент для Windows. Работает офлайн: распознавание речи (Vosk), синтез (Silero), локальный мозг (Ollama qwen3:8b), RAM-only Vision. Ядро — Node.js `ultra-server.mjs` на `http://127.0.0.1:3791`.

## Возможности

- **Голос и чат** — естественная речь, пробуждение «Джарвис» в любом месте фразы, короткие follow-up без кодового слова.
- **Память** — явно сохранённые факты, профиль, задачи, события + граф знаний (сущности и связи, извлекаются из разговоров, показываются в `/memory.html`).
- **Действия на ПК** — открытие приложений из проверенного списка, управление окнами, темы Windows, клики/ввод только через подтверждение.
- **Vision** — чтение экрана через локальную qwen3-vl, указатель с подтверждением, PoE2-наставник.
- **Инструменты** — веб-поиск (DuckDuckGo/Brave/Wikipedia, HTTPS-only), погода (Open-Meteo), дневник питания, безопасное чтение файлов.
- **MCP** — подключение внешних MCP-серверов через stdio (`mcp-servers.json`).
- **Диктовка** — режим `--dictation`: зажал hotkey → говоришь → текст вставляется в любое приложение.
- **Адаптивный тон** — подстраивается под тему: техническая, деловая, самочувствие.

## Запуск из исходников

```cmd
RUN-JARVIS-NEXUS-ULTRA.cmd
```

Требуется Node.js 20+ и Ollama. Пользовательские данные — в `data/` (переопределяется через `JARVIS_DATA_DIR`).

## Установка (Setup.exe)

Собери установщик с подпиской и автообновлением:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\installer\Build-Installer-SUBSCRIPTION-v12.ps1
```

Готовый `Setup.exe` + `.sha256.txt` появятся в `installer\dist-subscription`. Скачать опубликованные релизы можно на GitHub Releases.

## Приватный канал обновлений и подписка

- **Подписанные обновления** — релизный индекс на GitHub Pages (`https://proturik.github.io/jarvis-nexus/release-index.json`), пакеты проверяются по RSA-подписи и SHA-256, устанавливаются атомарно с откатом.
- **Подписка** — тарифы monthly/yearly/lifetime, жёсткий гейт: без действующей лицензии JARVIS не запускается. Страница покупки: `purchase.html`.
- Подробности — в `private-channel/README.md`.

## Тесты

```cmd
node --test evals/
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\private-channel\Test-PrivateChannel.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\private-channel\Test-Subscription.ps1
python sensors\test_dictation.py
```

## Безопасность

Локальная обработка, редизация секретов перед записью на диск, никаких облачных захватов экрана. Подтверждение для чувствительных действий. Секреты и модели никогда не попадают в пакеты обновлений.
