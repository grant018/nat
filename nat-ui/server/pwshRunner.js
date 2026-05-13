const { spawn } = require('child_process');
const path = require('path');
const readline = require('readline');

const SCRIPT_PATH = path.resolve(__dirname, '..', 'ps', 'Invoke-NatTermination.ps1');

function buildArgs(opts) {
  const args = ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', SCRIPT_PATH, '-UserUPN', opts.userUPN];

  if (opts.preflightOnly) {
    args.push('-PreflightOnly');
    return args;
  }

  if (opts.licensesOnly) {
    args.push('-LicensesOnly');
    if (opts.whatIf) args.push('-DryRun');
    return args;
  }

  if (Array.isArray(opts.delegateUPN) && opts.delegateUPN.length > 0) {
    args.push('-DelegateUPN', opts.delegateUPN.join(','));
  }
  if (typeof opts.autoReplyMessage === 'string' && opts.autoReplyMessage.length > 0) {
    args.push('-AutoReplyMessage', opts.autoReplyMessage);
  }
  if (typeof opts.litigationHoldDays === 'number' && opts.litigationHoldDays !== 1825) {
    args.push('-LitigationHoldDays', String(opts.litigationHoldDays));
  }
  if (opts.whatIf) args.push('-DryRun');
  return args;
}

function spawnPwsh(opts, run) {
  const args = buildArgs(opts);
  const child = spawn('pwsh', args, {
    windowsHide: true,
    env: { ...process.env, NAT_OUTPUT_MODE: 'json' },
  });

  const emit = (event) => run.emitter.emit('event', event);

  const stdoutRl = readline.createInterface({ input: child.stdout });
  stdoutRl.on('line', (line) => {
    const trimmed = line.trim();
    if (!trimmed) return;
    try {
      const evt = JSON.parse(trimmed);
      if (evt && typeof evt.type === 'string') {
        emit(evt);
        return;
      }
    } catch (_) {
      // not JSON - fall through
    }
    emit({ type: 'log', level: 'INFO', message: line, ts: new Date().toISOString() });
  });

  const stderrRl = readline.createInterface({ input: child.stderr });
  stderrRl.on('line', (line) => {
    if (!line.trim()) return;
    emit({ type: 'log', level: 'ERROR', message: line, ts: new Date().toISOString() });
  });

  child.on('error', (err) => {
    emit({ type: 'fatal', message: `Failed to spawn pwsh: ${err.message}`, ts: new Date().toISOString() });
  });

  child.on('exit', (code, signal) => {
    if (!run.finished) {
      emit({
        type: 'fatal',
        message: `pwsh exited unexpectedly (code=${code}, signal=${signal ?? 'none'})`,
        ts: new Date().toISOString(),
      });
    }
  });

  return child;
}

module.exports = { spawnPwsh, buildArgs };
