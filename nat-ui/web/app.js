/* =========================================================================
   nat-ui  -  frontend logic
   ========================================================================= */

const UPN_RE = /^[^@\s]+@[^@\s]+\.[^@\s]+$/;

const STEPS = [
  { id: 'block-signin',    title: '1. Block sign-in and revoke sessions' },
  { id: 'remove-groups',   title: '2. Remove from all groups' },
  { id: 'auto-reply',      title: '3. Configure auto-reply' },
  { id: 'litigation-hold', title: '4. Place mailbox on litigation hold' },
  { id: 'convert-shared',  title: '5. Convert to shared mailbox' },
  { id: 'grant-delegates', title: '6. Grant delegate access' },
];

const LICENSES_STEPS = [
  { id: 'remove-licenses', title: 'Remove all assigned licenses' },
];

const SVG = {
  circle: `<svg class="icon icon-circle" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="12" cy="12" r="9"/></svg>`,
  spin:   `<svg class="icon icon-spin" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round"><path d="M21 12a9 9 0 1 1-6.2-8.56"/></svg>`,
  ok:     `<svg class="icon icon-ok"   viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><path d="M20 6 9 17l-5-5"/></svg>`,
  fail:   `<svg class="icon icon-fail" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round"><path d="M18 6 6 18M6 6l12 12"/></svg>`,
};

// ---------------------------- DOM refs ----------------------------
const $ = (sel) => document.querySelector(sel);
const els = {
  app: $('#app'),
  themeToggle: $('#theme-toggle'),
  // form
  viewForm: $('#view-form'),
  tabs: document.querySelectorAll('.tab'),
  whatif: $('#whatif'),
  userUPN: $('#userUPN'),
  userUPNHint: $('#userUPN-hint'),
  delegateInput: $('#delegate-input'),
  delegateEntry: $('#delegate-entry'),
  delegateChips: $('#delegate-chips'),
  autoreply: $('#autoreply'),
  autoreplyCount: $('#autoreply-count'),
  holdDays: $('#hold-days'),
  runBtn: $('#run-btn'),
  health: $('#health-banner'),
  healthMsg: $('#health-message'),
  preflight: $('#preflight-banner'),
  preflightSignals: $('#preflight-signals'),
  preflightAck: $('#preflight-ack'),
  // run
  viewRun: $('#view-run'),
  runTitle: $('#run-title'),
  runUPN: $('#run-upn'),
  runElapsed: $('#run-elapsed'),
  runDryrun: $('#run-dryrun'),
  runStatus: $('#run-status'),
  authIndicator: $('#auth-indicator'),
  steps: $('#steps'),
  log: $('#log'),
  logPaused: $('#log-paused'),
  openTranscript: $('#open-transcript'),
  runAnother: $('#run-another'),
  // modal
  modal: $('#modal'),
  confirmSummary: $('#confirm-summary'),
  confirmWarn: $('#confirm-warn'),
  confirmOnedrive: $('#confirm-onedrive'),
  cancelBtn: $('#cancel-btn'),
  confirmBtn: $('#confirm-btn'),
};

// ---------------------------- State -------------------------------
const state = {
  mode: 'terminate',
  delegates: [],
  preflightSignals: [],
  preflightAcked: false,
  currentRunId: null,
  pausedScroll: false,
};

// ---------------------------- Theme -------------------------------
function loadTheme() {
  const t = localStorage.getItem('nat-theme') || 'dark';
  document.documentElement.dataset.theme = t;
}
els.themeToggle.addEventListener('click', () => {
  const next = document.documentElement.dataset.theme === 'dark' ? 'light' : 'dark';
  document.documentElement.dataset.theme = next;
  localStorage.setItem('nat-theme', next);
});

// ---------------------------- Tabs --------------------------------
els.tabs.forEach((tab) => {
  tab.addEventListener('click', () => {
    els.tabs.forEach((t) => t.classList.remove('is-active'));
    tab.classList.add('is-active');
    state.mode = tab.dataset.mode;
    document.querySelectorAll('[data-only]').forEach((el) => {
      el.hidden = el.dataset.only !== state.mode;
    });
    els.runBtn.textContent = state.mode === 'licenses' ? 'Remove licenses' : 'Review and run';
    updateRunButton();
  });
});

// ---------------------------- UPN field ---------------------------
// Preflight (Test-AlreadyOffboarded) used to fire on UPN blur, but it has
// to Connect-MgGraph + Connect-ExchangeOnline first, so it kicked off an
// auth flow as soon as the user tabbed out of the UPN field. The same
// check still runs as the first step of the workflow itself - any
// already-offboarded signals surface in the live log during the run.
els.userUPN.addEventListener('input', () => {
  const v = els.userUPN.value.trim();
  els.userUPN.classList.toggle('invalid', v.length > 0 && !UPN_RE.test(v));
  updateRunButton();
});

// ---------------------------- Delegates (chips) -------------------
els.delegateInput.addEventListener('click', () => els.delegateEntry.focus());

els.delegateEntry.addEventListener('keydown', (e) => {
  if (e.key === 'Enter' || e.key === ',' || e.key === 'Tab') {
    if (e.key === 'Tab' && !els.delegateEntry.value.trim()) return;
    e.preventDefault();
    flushDelegateEntry();
  } else if (e.key === 'Backspace' && !els.delegateEntry.value && state.delegates.length) {
    state.delegates.pop();
    renderChips();
  }
});
els.delegateEntry.addEventListener('paste', (e) => {
  const text = (e.clipboardData || window.clipboardData).getData('text');
  if (!text || !/[,;\s]/.test(text)) return;
  e.preventDefault();
  text.split(/[,;\s]+/).forEach(addDelegate);
  renderChips();
});
els.delegateEntry.addEventListener('blur', flushDelegateEntry);

function flushDelegateEntry() {
  const v = els.delegateEntry.value.trim().replace(/,$/, '');
  if (v) addDelegate(v);
  els.delegateEntry.value = '';
  renderChips();
}
function addDelegate(raw) {
  const v = String(raw).trim();
  if (!v || state.delegates.includes(v)) return;
  state.delegates.push(v);
}
function renderChips() {
  els.delegateChips.innerHTML = state.delegates.map((d, i) => {
    const bad = !UPN_RE.test(d);
    return `<span class="chip ${bad ? 'invalid' : ''}">${escapeHtml(d)}<button data-i="${i}" aria-label="Remove">&times;</button></span>`;
  }).join('');
  els.delegateChips.querySelectorAll('button').forEach((btn) => {
    btn.addEventListener('click', () => {
      state.delegates.splice(Number(btn.dataset.i), 1);
      renderChips();
    });
  });
  updateRunButton();
}

// ---------------------------- Auto-reply --------------------------
els.autoreply.addEventListener('input', () => {
  els.autoreplyCount.textContent = `${els.autoreply.value.length} chars`;
});

// ---------------------------- Run button gating -------------------
function updateRunButton() {
  const upn = els.userUPN.value.trim();
  const upnOk = UPN_RE.test(upn);
  const delegatesOk = state.delegates.every((d) => UPN_RE.test(d));
  els.runBtn.disabled = !(upnOk && delegatesOk);
}

// ---------------------------- Confirm modal -----------------------
els.runBtn.addEventListener('click', () => {
  buildSummary();
  els.modal.hidden = false;
});
els.cancelBtn.addEventListener('click', () => { els.modal.hidden = true; });
els.modal.addEventListener('click', (e) => { if (e.target === els.modal) els.modal.hidden = true; });
document.addEventListener('keydown', (e) => { if (e.key === 'Escape' && !els.modal.hidden) els.modal.hidden = true; });

function buildSummary() {
  const upn = els.userUPN.value.trim();
  const whatif = els.whatif.checked;
  const rows = [];
  rows.push(['Mode', state.mode === 'licenses' ? 'Licenses only (post-OneDrive cleanup)' : 'Full termination']);
  rows.push(['User UPN', upn]);
  if (state.mode === 'terminate') {
    rows.push(['Delegates', state.delegates.length ? state.delegates.join(', ') : null]);
    rows.push(['Auto-reply', els.autoreply.value.trim() || null]);
    rows.push(['Litigation hold', `${els.holdDays.value || 1825} days`]);
  }
  rows.push(['Dry run', whatif ? 'Yes (no changes will be made)' : 'No']);

  els.confirmSummary.innerHTML = rows.map(([k, v]) =>
    `<dt>${escapeHtml(k)}</dt><dd class="${v ? '' : 'empty'}">${v ? escapeHtml(v) : '(none)'}</dd>`
  ).join('');
  els.confirmWarn.hidden = whatif;
  els.confirmOnedrive.hidden = state.mode !== 'licenses' || whatif;
}

els.confirmBtn.addEventListener('click', startRun);

// ---------------------------- Start run ---------------------------
async function startRun() {
  els.modal.hidden = true;
  const body = {
    mode: state.mode,
    userUPN: els.userUPN.value.trim(),
    delegateUPN: state.delegates,
    autoReplyMessage: els.autoreply.value,
    litigationHoldDays: Number(els.holdDays.value) || 1825,
    whatIf: els.whatif.checked,
  };

  showRunView(body);

  try {
    const r = await fetch('/api/run', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    });
    if (!r.ok) throw new Error(`Server returned ${r.status}`);
    const { runId } = await r.json();
    state.currentRunId = runId;
    streamRun(runId);
  } catch (err) {
    appendLog({ type: 'log', level: 'ERROR', message: `Failed to start run: ${err.message}`, ts: new Date().toISOString() });
    setRunStatus('fail');
  }
}

function showRunView(body) {
  els.viewForm.hidden = true;
  els.viewRun.hidden = false;
  els.runTitle.textContent = body.mode === 'licenses' ? 'License removal' : 'Termination';
  els.runUPN.textContent = body.userUPN;
  els.runDryrun.hidden = !body.whatIf;
  els.runStatus.textContent = 'running';
  els.runStatus.className = 'badge';
  els.openTranscript.hidden = true;
  els.runAnother.hidden = true;
  els.log.innerHTML = '';
  els.authIndicator.hidden = true;

  const steps = body.mode === 'licenses' ? LICENSES_STEPS : STEPS;
  els.steps.innerHTML = steps.map((s) =>
    `<li class="step" data-id="${s.id}" data-status="pending">
       <span class="icon-slot">${SVG.circle}</span>
       <span class="title">${s.title}</span>
       <span class="ms"></span>
     </li>`
  ).join('');

  startElapsed();
}

let elapsedTimer = null;
let elapsedStart = 0;
function startElapsed() {
  elapsedStart = Date.now();
  clearInterval(elapsedTimer);
  elapsedTimer = setInterval(() => {
    const s = Math.floor((Date.now() - elapsedStart) / 1000);
    els.runElapsed.textContent = s < 60 ? `${s}s` : `${Math.floor(s / 60)}m ${s % 60}s`;
  }, 250);
}
function stopElapsed() { clearInterval(elapsedTimer); elapsedTimer = null; }

// ---------------------------- SSE --------------------------------
function streamRun(runId) {
  const es = new EventSource(`/api/runs/${runId}/stream`);
  es.onmessage = (msg) => {
    try {
      const evt = JSON.parse(msg.data);
      handleEvent(evt);
    } catch (_) { /* ignore */ }
  };
  es.onerror = () => { es.close(); stopElapsed(); };
}

function handleEvent(evt) {
  switch (evt.type) {
    case 'log':
      appendLog(evt);
      // "Connecting to ..." means an auth window may pop. Any other log
      // line that follows means auth has resolved - clear the indicator.
      if (/Connecting to /i.test(evt.message)) showAuthIndicator(true);
      else showAuthIndicator(false);
      break;
    case 'step-start':
      setStep(evt.step, 'running');
      showAuthIndicator(false);
      break;
    case 'step-end':
      setStep(evt.step, evt.status, evt.durationMs);
      showAuthIndicator(false);
      break;
    case 'preflight':
      if (evt.signals && evt.signals.length) {
        appendLog({ type: 'log', level: 'WARN', message: `Pre-flight signals: ${evt.signals.join('; ')}`, ts: evt.ts });
      }
      break;
    case 'done':
      stopElapsed();
      setRunStatus(evt.status === 'success' ? 'ok' : 'fail');
      finalizeRun(evt);
      break;
    case 'fatal':
      stopElapsed();
      appendLog({ type: 'log', level: 'ERROR', message: `FATAL: ${evt.message}`, ts: evt.ts });
      setRunStatus('fail');
      finalizeRun(evt);
      break;
  }
}

function setStep(id, status, ms) {
  const li = els.steps.querySelector(`[data-id="${id}"]`);
  if (!li) return;
  li.dataset.status = status;
  const slot = li.querySelector('.icon-slot');
  slot.innerHTML = status === 'running' ? SVG.spin
                : status === 'ok'      ? SVG.ok
                : status === 'fail'    ? SVG.fail
                :                        SVG.circle;
  if (typeof ms === 'number') li.querySelector('.ms').textContent = formatMs(ms);
}
function formatMs(ms) {
  if (ms < 1000) return `${ms} ms`;
  const s = ms / 1000;
  return s < 60 ? `${s.toFixed(1)}s` : `${Math.floor(s / 60)}m ${Math.floor(s % 60)}s`;
}

function setRunStatus(s) {
  els.runStatus.textContent = s === 'ok' ? 'complete' : s === 'fail' ? 'failed' : 'running';
  els.runStatus.className = 'badge ' + (s === 'ok' ? 'badge-ok' : s === 'fail' ? 'badge-err' : '');
}

function appendLog(evt) {
  const ts = (evt.ts || new Date().toISOString()).slice(11, 19);
  const line = document.createElement('span');
  line.className = `ln ${evt.level || 'INFO'}`;
  line.innerHTML = `<span class="ts">${ts}</span><span class="lvl">${evt.level || 'INFO'}</span>${escapeHtml(evt.message)}\n`;
  els.log.appendChild(line);
  if (!state.pausedScroll) els.log.scrollTop = els.log.scrollHeight;
}

els.log.addEventListener('mouseenter', () => { state.pausedScroll = true; els.logPaused.hidden = false; });
els.log.addEventListener('mouseleave', () => { state.pausedScroll = false; els.logPaused.hidden = true; els.log.scrollTop = els.log.scrollHeight; });

function showAuthIndicator(show) { els.authIndicator.hidden = !show; }

function finalizeRun(evt) {
  els.openTranscript.hidden = !evt.transcript;
  els.runAnother.hidden = false;
  // Mark any still-running step as failed.
  els.steps.querySelectorAll('.step[data-status="running"]').forEach((li) => setStep(li.dataset.id, 'fail'));
  // Any pending steps that never started are left as pending icons.
}

els.openTranscript.addEventListener('click', async () => {
  if (!state.currentRunId) return;
  await fetch(`/api/runs/${state.currentRunId}/open-transcript`, { method: 'POST' });
});
els.runAnother.addEventListener('click', () => {
  state.currentRunId = null;
  els.viewRun.hidden = true;
  els.viewForm.hidden = false;
});

// ---------------------------- Health check ------------------------
async function checkHealth() {
  try {
    const r = await fetch('/api/health');
    if (r.ok) return;
    const data = await r.json();
    els.healthMsg.textContent = data.error || 'PowerShell modules missing.';
    els.health.hidden = false;
  } catch (err) {
    els.healthMsg.textContent = err.message;
    els.health.hidden = false;
  }
}

// ---------------------------- Utils -------------------------------
function escapeHtml(s) {
  return String(s).replace(/[&<>"']/g, (c) => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
  }[c]));
}

// ---------------------------- Boot --------------------------------
loadTheme();
checkHealth();
updateRunButton();
