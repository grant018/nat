const express = require('express');
const path = require('path');
const { spawn } = require('child_process');
const { createRun, getRun } = require('./runs');
const { spawnPwsh } = require('./pwshRunner');

const app = express();
const PORT = Number(process.env.PORT) || 5757;
const WEB_DIR = path.resolve(__dirname, '..', 'web');

app.use(express.json({ limit: '64kb' }));
app.use(express.static(WEB_DIR, { extensions: ['html'] }));

// --- Health check ---------------------------------------------------------
const MODULE_PATH = path.resolve(__dirname, '..', 'ps', 'Nat.psm1');
app.get('/api/health', (_req, res) => {
  const probe = spawn(
    'pwsh.exe',
    [
      '-NoProfile',
      '-Command',
      `Import-Module '${MODULE_PATH}' -Force -ErrorAction Stop; try { Assert-RequiredModules; Write-Output 'OK' } catch { Write-Output $_.Exception.Message }`,
    ],
    { windowsHide: true },
  );
  let out = '';
  let err = '';
  probe.stdout.on('data', (c) => (out += c.toString()));
  probe.stderr.on('data', (c) => (err += c.toString()));
  probe.on('error', () => {
    res.status(500).json({ ok: false, error: 'pwsh.exe not found on PATH. Install PowerShell 7+.' });
  });
  probe.on('exit', () => {
    const trimmed = out.trim();
    if (trimmed === 'OK') return res.json({ ok: true });
    res.status(500).json({ ok: false, error: trimmed || err.trim() || 'Unknown PowerShell error' });
  });
});

// --- Preflight ------------------------------------------------------------
app.post('/api/preflight', (req, res) => {
  const { userUPN } = req.body || {};
  if (!isValidUPN(userUPN)) return res.status(400).json({ error: 'Invalid UPN' });

  const run = createRun({ kind: 'preflight', userUPN });
  spawnPwsh({ userUPN, preflightOnly: true }, run);

  const result = { signals: [], error: null };
  run.emitter.on('event', (e) => {
    if (e.type === 'preflight') result.signals = e.signals || [];
    if (e.type === 'fatal') result.error = e.message;
    if (e.type === 'done' || e.type === 'fatal') {
      res.json(result);
    }
  });
});

// --- Start a run ----------------------------------------------------------
app.post('/api/run', (req, res) => {
  const body = req.body || {};
  if (!isValidUPN(body.userUPN)) return res.status(400).json({ error: 'Invalid UPN' });

  const mode = body.mode === 'licenses' ? 'licenses' : 'terminate';
  const opts = {
    userUPN: body.userUPN,
    licensesOnly: mode === 'licenses',
    delegateUPN: Array.isArray(body.delegateUPN) ? body.delegateUPN.filter(isValidUPN) : [],
    autoReplyMessage: typeof body.autoReplyMessage === 'string' ? body.autoReplyMessage : '',
    litigationHoldDays: Number.isFinite(body.litigationHoldDays) ? Math.trunc(body.litigationHoldDays) : 1825,
    whatIf: Boolean(body.whatIf),
  };

  const run = createRun({ kind: mode, opts });
  spawnPwsh(opts, run);
  res.json({ runId: run.id });
});

// --- SSE stream -----------------------------------------------------------
app.get('/api/runs/:id/stream', (req, res) => {
  const run = getRun(req.params.id);
  if (!run) return res.status(404).end();

  res.set({
    'Content-Type': 'text/event-stream',
    'Cache-Control': 'no-cache',
    Connection: 'keep-alive',
    'X-Accel-Buffering': 'no',
  });
  res.flushHeaders();

  // Replay anything already emitted before this listener attached.
  for (const evt of run.events) {
    res.write(`data: ${JSON.stringify(evt)}\n\n`);
  }

  if (run.finished) {
    res.end();
    return;
  }

  const onEvent = (evt) => {
    res.write(`data: ${JSON.stringify(evt)}\n\n`);
    if (evt.type === 'done' || evt.type === 'fatal') {
      res.end();
    }
  };
  run.emitter.on('event', onEvent);

  req.on('close', () => {
    run.emitter.off('event', onEvent);
  });
});

// --- Open transcript in Explorer -----------------------------------------
app.post('/api/runs/:id/open-transcript', (req, res) => {
  const run = getRun(req.params.id);
  if (!run) return res.status(404).json({ error: 'No such run' });
  const final = [...run.events].reverse().find((e) => e.type === 'done' || e.type === 'fatal');
  const transcript = final && final.transcript;
  if (!transcript) return res.status(404).json({ error: 'No transcript for this run' });
  spawn('explorer.exe', ['/select,', transcript], { windowsHide: false, detached: true }).unref();
  res.json({ ok: true });
});

// --- Helpers --------------------------------------------------------------
function isValidUPN(s) {
  return typeof s === 'string' && /^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(s);
}

app.listen(PORT, '127.0.0.1', () => {
  console.log(`nat-ui listening on http://localhost:${PORT}`);
});
