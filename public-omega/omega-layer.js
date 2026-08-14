(() => {
  const nexus = window.nexus;
  const button = document.querySelector('#vision-explainer');
  if (!nexus || !button) return;

  let active = false;

  function paint(vision) {
    active = Boolean(vision?.active);
    button.classList.toggle('is-active', active);
    button.innerHTML = `<i></i><span>${active ? 'ГЛАЗА · ВКЛЮЧЕНЫ' : 'ГЛАЗА · ВЫКЛЮЧЕНЫ'}</span>`;
    button.title = active ? 'Экранный контур включён: нажмите, чтобы отключить.' : 'Включить экранный контур.';
  }

  async function state() {
    const snapshot = await nexus.api('/api/bootstrap');
    paint(snapshot.vision);
    return snapshot.vision;
  }

  button.addEventListener('click', async () => {
    try {
      if (active) {
        await nexus.api('/api/vision/toggle', { method: 'POST', body: JSON.stringify({ enabled: false }) });
        paint({ active: false });
        nexus.toast('Глаза NEXUS выключены. Новые кадры не захватываются.');
        return;
      }
      const accepted = window.confirm('Включить экранный контур? Пока он включён, при КАЖДОЙ твоей новой команде один сжатый снимок экрана будет отправлен в OpenAI для анализа. Это не запись видео. Выключить можно здесь же в один клик.');
      if (!accepted) return;
      const result = await nexus.api('/api/vision/toggle', { method: 'POST', body: JSON.stringify({ enabled: true, cloudConsent: true }) });
      paint(result.vision);
      nexus.toast('Глаза NEXUS включены. Скажи, что происходит — я буду смотреть вместе с тобой.');
    } catch (error) {
      nexus.toast(error.message, true);
    }
  });

  state().catch(() => paint({ active: false }));
})();
