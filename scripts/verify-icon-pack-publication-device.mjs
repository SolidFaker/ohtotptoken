import { spawn } from 'node:child_process';
import { existsSync } from 'node:fs';
import { resolve } from 'node:path';

const options = process.argv.slice(2);
function argument(name, fallback) {
  const index = options.indexOf(name);
  return index < 0 ? fallback : options[index + 1];
}
const device = argument('--device');
const checkpoint = argument('--checkpoint', 'directory');
const mode = argument('--mode', 'local');
const action = argument('--action', 'restart');
if (!device || !['directory', 'zip', 'metadata', 'commit', 'commit-sync', 'prune'].includes(checkpoint) ||
  !['local', 'cloud'].includes(mode) || !['restart', 'run', 'cleanup', 'import'].includes(action)) {
  throw new Error('Use --device <target> --mode local|cloud --action run|restart|cleanup|import --checkpoint <fixed checkpoint>');
}
const candidates = [process.env.DEVECO_HDC, 'C:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/toolchains/hdc.exe'];
const hdc = candidates.find(path => path && existsSync(path)) || 'hdc';
const bundle = 'smartcityshenzhen.yylx.totptoken';
const runner = action === 'import' ? 'IconPackImportGateTestRunner' : 'IconPackPublicationTestRunner';
const resultPath = argument('--result');
const modeMarker = action === 'import' ? 'ICON_IMPORT_FIXTURE_MODE=ISOLATED' : `ICON_FIXTURE_MODE=${mode.toUpperCase()}`;

function command(arguments_, timeout = 60000, onText) {
  const child = spawn(hdc, ['-t', device, ...arguments_], { stdio: ['ignore', 'pipe', 'pipe'] });
  let text = '';
  let timedOut = false;
  let startError = false;
  let timer;
  let done = false;
  let finish;
  const finished = new Promise(resolve => {
    finish = (code, signal) => {
      if (done) return;
      done = true;
      clearTimeout(timer);
      child.stdout.destroy();
      child.stderr.destroy();
      resolve({ code, signal, timedOut, startError, text });
    };
    child.on('close', finish);
    child.on('error', () => { startError = true; finish(null, null); });
  });
  const cancel = () => {
    child.kill();
    child.unref();
    finish(null, 'CONTROLLER_CANCELLED');
  };
  timer = setTimeout(() => { timedOut = true; cancel(); }, timeout);
  const receive = data => { text += data.toString('utf8'); onText?.(text); };
  child.stdout.on('data', receive);
  child.stderr.on('data', receive);
  return { child, finished, cancel };
}
function args(phase) {
  return ['shell', 'aa', 'test', '-b', bundle, '-m', 'entry_test', '-s', 'unittest', runner,
    '-s', 'fixturePhase', phase, '-s', 'fixtureCheckpoint', checkpoint,
    '-s', 'cloudBackupOwnedFixture', String(mode === 'cloud'), '-s', 'timeout', '180000', '-w', '240'];
}
function summary(output) {
  const match = [...output.matchAll(/Tests run:\s*(\d+),\s*Failure:\s*(\d+),\s*Error:\s*(\d+),\s*Pass:\s*(\d+),\s*Ignore:\s*(\d+)/g)].at(-1);
  if (!match) return undefined;
  return { tests: Number(match[1]), failure: Number(match[2]), error: Number(match[3]), pass: Number(match[4]), ignore: Number(match[5]) };
}
function reportCode(output) {
  const match = [...output.matchAll(/OHOS_REPORT_CODE:\s*(-?\d+)/g)].at(-1);
  return match ? Number(match[1]) : undefined;
}
function safeOutput(text) {
  const markers = text.match(/\bICON_(?:FIXTURE_MODE=(?:LOCAL|CLOUD)|IMPORT_FIXTURE_MODE=ISOLATED|FIXTURE_CHECKPOINT=(?:directory|zip|metadata|commit-sync|commit|prune)|FIXTURE_FAILED code=(?:UNKNOWN|13900002|13900005|13900012|13900020|13900031|900001|900003)|IMPORT_FIXTURE_(?:FAILED|CLEANUP_FAILED)|FIXTURE_CLEANUP=AUDITED_ABSENT)\b/g) || [];
  const result = summary(text);
  if (result) markers.push(`Tests run: ${result.tests}, Failure: ${result.failure}, Error: ${result.error}, Pass: ${result.pass}, Ignore: ${result.ignore}`);
  const code = reportCode(text);
  if (code !== undefined) markers.push(`OHOS_REPORT_CODE: ${code}`);
  return markers.join('\n');
}
function successfulCommand(result) {
  return result.code === 0 && !result.signal && !result.timedOut && !result.startError;
}
function passedTest(run, expectedCount) {
  const result = summary(run.text);
  const markerCount = run.text.split(modeMarker).length - 1;
  return successfulCommand(run) && reportCode(run.text) === 0 && markerCount === expectedCount &&
    result?.tests === expectedCount && result.pass === expectedCount && result.failure === 0 &&
    result.error === 0 && result.ignore === 0;
}
async function stopFixtureProcess() {
  const result = await command(['shell', 'aa', 'force-stop', bundle]).finished;
  return successfulCommand(result) && /stop.*success|success.*stop/i.test(result.text);
}
async function settleArm(arm) {
  let timer;
  try {
    const settled = await Promise.race([arm.finished.then(() => true),
      new Promise(resolve => { timer = setTimeout(() => resolve(false), 3000); })]);
    if (!settled) { arm.cancel(); await arm.finished; }
  } finally {
    clearTimeout(timer);
  }
}

let final;
if (action === 'restart') {
  let reached;
  let checkpointTimer;
  const checkpointReached = new Promise(resolve => { reached = resolve; });
  const arm = command(args('arm'), 250000, text => {
    if (text.includes(`ICON_FIXTURE_CHECKPOINT=${checkpoint}`) && text.includes(modeMarker)) reached(true);
  });
  let atCheckpoint;
  try {
    atCheckpoint = await Promise.race([checkpointReached, arm.finished.then(() => false),
      new Promise(resolve => { checkpointTimer = setTimeout(() => resolve(false), 80000); })]);
  } finally {
    clearTimeout(checkpointTimer);
  }
  const stopped = await stopFixtureProcess();
  // arm 的进程终止是本测试的预期动作，不用其退出状态判断文件系统是否失败。
  await settleArm(arm);
  if (!atCheckpoint || !stopped) {
    const cleanup = stopped ? await command(args('cleanup'), 250000).finished : undefined;
    console.log('Restart checkpoint or process stop not confirmed; no test pass claimed.');
    if (cleanup) console.log(safeOutput(cleanup.text));
    final = { mode, action, checkpoint, checkpointReached: !!atCheckpoint, stopConfirmed: stopped,
      cleanup: cleanup ? summary(cleanup.text) : undefined, passed: false };
    process.exitCode = 1;
  } else {
    console.log(`Reached ${checkpoint} in ${mode.toUpperCase()} fixture; stopped test process.`);
    const verify = await command(args('verify'), 250000).finished;
    console.log(safeOutput(verify.text));
    const passed = passedTest(verify, 1);
    final = { mode, action, checkpoint, checkpointReached: true, stopConfirmed: true,
      verification: summary(verify.text), passed };
    if (!passed) process.exitCode = 1;
  }
} else {
  const run = await command(args(action === 'import' ? 'run' : action), 250000).finished;
  console.log(safeOutput(run.text));
  const count = action === 'import' ? 7 : action === 'run' ? 5 : 1;
  const passed = passedTest(run, count) &&
    (action !== 'import' || run.text.includes('ICON_FIXTURE_CLEANUP=AUDITED_ABSENT'));
  final = { mode: action === 'import' ? 'isolated' : mode, action, verification: summary(run.text),
    cleanupAudited: action === 'import' && run.text.includes('ICON_FIXTURE_CLEANUP=AUDITED_ABSENT'), passed };
  if (!passed) { await stopFixtureProcess(); process.exitCode = 1; }
}
if (resultPath) {
  const { writeFile } = await import('node:fs/promises');
  await writeFile(resolve(resultPath), JSON.stringify(final, null, 2) + '\n', { flag: 'wx' });
}
