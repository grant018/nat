const { EventEmitter } = require('events');
const crypto = require('crypto');

const runs = new Map();

function createRun(meta) {
  const id = crypto.randomBytes(6).toString('hex');
  const emitter = new EventEmitter();
  emitter.setMaxListeners(0);
  const run = {
    id,
    meta,
    startedAt: new Date().toISOString(),
    events: [],
    finished: false,
    emitter,
  };
  emitter.on('event', (e) => {
    run.events.push(e);
    if (e.type === 'done' || e.type === 'fatal') run.finished = true;
  });
  runs.set(id, run);
  return run;
}

function getRun(id) {
  return runs.get(id);
}

module.exports = { createRun, getRun };
