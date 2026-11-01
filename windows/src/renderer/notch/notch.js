'use strict';
/* Notch HUD: live agent jobs, approval prompts, always-available Stop button. */
(function () {
  const root = document.getElementById('notch');
  const api = window.clicky;
  let state = { jobs: [], prompts: [] };
  let answerDraft = {};

  function esc(s) {
    return String(s == null ? '' : s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
  }

  function promptHtml(p) {
    if (p.kind === 'question') {
      return `<div class="prompt" data-job="${p.jobId}"><div class="ptext">${esc(p.text)}</div>
        <input class="field" data-answer="${p.jobId}" placeholder="Type your answer, or just say it out loud" value="${esc(answerDraft[p.jobId] || '')}">
        <div class="pbtns"><button class="btn btn-secondary" data-act="skip" data-id="${p.jobId}">Skip</button><button class="btn btn-primary" style="animation:none;padding:6px 16px" data-act="answer" data-id="${p.jobId}">Send</button></div></div>`;
    }
    const label = p.kind === 'approve-command' ? 'Run' : 'Allow';
    return `<div class="prompt" data-job="${p.jobId}"><div class="ptext">${esc(p.text)}</div>
      <div class="pbtns"><button class="btn btn-secondary" data-act="deny" data-id="${p.jobId}">Deny</button><button class="btn btn-primary" style="animation:none;padding:6px 18px" data-act="allow" data-id="${p.jobId}">${label}</button></div>
      <div class="hint">You can also say "yes" or "no".</div></div>`;
  }

  function render() {
    const jobs = state.jobs || [];
    if (!jobs.length) {
      root.innerHTML = '';
      api.invoke('notch:resize', { height: 40, visible: false });
      return;
    }
    const hadFocus = document.activeElement && document.activeElement.dataset && document.activeElement.dataset.answer;
    const html = jobs
      .map((j) => {
        const waiting = j.status === 'waiting';
        const p = (state.prompts || []).find((x) => x.jobId === j.id);
        return `<div class="job"><div class="orb ${waiting ? 'waiting' : ''}"><i></i></div>
          <div style="min-width:0"><div class="jname">${esc(j.name)}</div><div class="jnote">${esc(waiting ? 'Waiting for you' : j.note || 'working')}</div></div>
          <button class="btn btn-destructive jstop" data-act="stop" data-id="${j.id}">Stop</button></div>${p ? promptHtml(p) : ''}`;
      })
      .join('');
    root.innerHTML = html;
    if (hadFocus) {
      const el = root.querySelector(`[data-answer="${hadFocus}"]`);
      if (el) el.focus();
    }
    const needsInput = (state.prompts || []).some((p) => p.kind === 'question');
    api.invoke('notch:resize', { height: root.offsetHeight + 4, visible: true, focusable: needsInput });
  }

  root.addEventListener('click', (e) => {
    const el = e.target.closest('[data-act]');
    if (!el) return;
    const id = el.dataset.id;
    switch (el.dataset.act) {
      case 'stop': api.invoke('job:stop', { id }); break;
      case 'allow': api.invoke('job:respond', { id, approved: true, answer: '' }); break;
      case 'deny': api.invoke('job:respond', { id, approved: false, answer: '' }); break;
      case 'skip': api.invoke('job:respond', { id, approved: false, answer: '' }); break;
      case 'answer': {
        const input = root.querySelector(`[data-answer="${id}"]`);
        api.invoke('job:respond', { id, approved: true, answer: (input && input.value) || '' });
        break;
      }
      default: break;
    }
  });
  root.addEventListener('input', (e) => {
    if (e.target.dataset && e.target.dataset.answer) answerDraft[e.target.dataset.answer] = e.target.value;
  });
  root.addEventListener('keydown', (e) => {
    if (e.key === 'Enter' && e.target.dataset && e.target.dataset.answer) {
      api.invoke('job:respond', { id: e.target.dataset.answer, approved: true, answer: e.target.value });
    }
  });

  api.on('notch:state', (s) => { state = s || { jobs: [], prompts: [] }; render(); });
  render();
})();
