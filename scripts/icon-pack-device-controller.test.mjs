import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { runInNewContext } from 'node:vm';
import { EventEmitter } from 'node:events';
import { PassThrough } from 'node:stream';

const source = (await readFile(new URL('./verify-icon-pack-publication-device.mjs', import.meta.url), 'utf8'))
  .replace(/^import .*;\r?\n/gm, '');
const functions = source.slice(0, source.indexOf('\nlet final;'));

function sandbox(spawn, action = 'run') {
  return { spawn, existsSync: () => true, process: {
    argv: ['node', 'script', '--device', 'synthetic-target', '--mode', 'cloud', '--action', action], env: {}
  }, console: { log() {} }, setTimeout, clearTimeout, resolve: value => value };
}
function api(spawn = () => {}) {
  return runInNewContext(functions + '\n({command, summary, passedTest, safeOutput, settleArm});', sandbox(spawn));
}
function report({ count = 5, pass = 5, ignore = 0, reportCode = 0, markers = 5 } = {}) {
  return Array(markers).fill('ICON_FIXTURE_MODE=CLOUD').join('\n') +
    `\nTests run: ${count}, Failure: 0, Error: 0, Pass: ${pass}, Ignore: ${ignore}\nOHOS_REPORT_CODE: ${reportCode}`;
}
function result(text = report()) {
  return { text, code: 0, signal: null, timedOut: false, startError: false };
}
function child() {
  const value = new EventEmitter();
  value.stdout = new PassThrough();
  value.stderr = new PassThrough();
  value.killed = false;
  value.unreferenced = false;
  value.kill = () => { value.killed = true; return true; };
  value.unref = () => { value.unreferenced = true; };
  return value;
}

for (const [name, change] of [
  ['ignore is not a pass', { text: report({ ignore: 1 }) }],
  ['pass count must equal expected tests', { text: report({ pass: 4 }) }],
  ['nonzero process exit is rejected', { code: 1 }],
  ['timeout rejects an already printed success', { timedOut: true }],
  ['report code must be zero', { text: report({ reportCode: -1 }) }],
  ['mode marker must match every expected case', { text: report({ markers: 1 }) }]
]) {
  test(name, () => {
    const gate = api();
    assert.equal(gate.passedTest(result(), 5), true);
    assert.equal(gate.passedTest({ ...result(), ...change }, 5), false);
  });
}

test('timeout settles without child close and cannot accept printed success', async () => {
  const host = child();
  const gate = api(() => host);
  const task = gate.command(['synthetic'], 10);
  host.stdout.write(report());
  const outcome = await task.finished;
  assert.equal(outcome.timedOut, true);
  assert.equal(host.killed, true);
  assert.equal(host.unreferenced, true);
  assert.equal(host.stdout.destroyed && host.stderr.destroyed, true);
  assert.equal(gate.passedTest(outcome, 5), false);
});

test('cancel resolves once even if late close reports success', async () => {
  const host = child();
  const gate = api(() => host);
  const task = gate.command(['synthetic']);
  task.cancel();
  const outcome = await task.finished;
  host.emit('close', 0, null);
  assert.equal(outcome.signal, 'CONTROLLER_CANCELLED');
  assert.equal(gate.passedTest(outcome, 5), false);
});

test('safe output extracts fixed tokens rather than retaining adjacent private text', () => {
  const gate = api();
  const output = gate.safeOutput('PRIVATE_PATH /private/archive.zip ICON_FIXTURE_MODE=CLOUD PRIVATE_TEXT\n' + report());
  assert.equal(output.includes('PRIVATE'), false);
  assert.equal(output.includes('/private'), false);
  assert.equal(output.includes('Tests run: 5'), true);
});
