import { createHash, timingSafeEqual } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { appendFile, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';

// 只下载锁文件中的生产 HAR 并提取 JS 核心，不执行安装脚本，不修改 oh_modules。
const lock = JSON.parse(await readFile(new URL('../entry/oh-package-lock.json5', import.meta.url), 'utf8'));
const entry = lock.packages['@ohos/jszip@1.0.1'];
if (entry?.name !== '@ohos/jszip' || entry.version !== '1.0.1' ||
  entry.resolved !== 'https://ohpm.openharmony.cn/ohpm/@ohos/jszip/-/jszip-1.0.1.har' ||
  !entry.integrity?.startsWith('sha512-')) throw new Error('Pinned JSZip lock entry changed; review dependency preparation.');
const githubEnv = process.argv.includes('--github-env');
if (githubEnv && !process.env.GITHUB_ENV) throw new Error('--github-env requires the GitHub Actions environment file.');
let response;
try {
  response = await fetch(entry.resolved, { signal: AbortSignal.timeout(60000) });
} catch (_) {
  throw new Error('Pinned JSZip HAR download failed.');
}
if (!response.ok || new URL(response.url).protocol !== 'https:') throw new Error('Pinned JSZip HAR download failed.');
const archive = Buffer.from(await response.arrayBuffer());
const expected = Buffer.from(entry.integrity.substring(7), 'base64');
const actual = createHash('sha512').update(archive).digest();
if (expected.length !== actual.length || !timingSafeEqual(expected, actual)) throw new Error('Pinned JSZip HAR integrity mismatch.');
const root = await mkdtemp(join(tmpdir(), 'ohtotp-jszip-'));
try {
  const path = join(root, 'package.har');
  await writeFile(path, archive, { flag: 'wx' });
  execFileSync('tar', ['-xzf', 'package.har', '--strip-components=5',
    'package/src/main/core/jszip-master/lib'], { cwd: root, timeout: 60000, stdio: 'pipe' });
  await readFile(join(root, 'lib', 'index.js'));
  await rm(path);
  if (githubEnv) {
    await appendFile(process.env.GITHUB_ENV, `ICON_PACK_JSZIP_LIB=${root}\n`);
    console.log('Integrity-checked production JSZip core prepared for Node regression.');
  } else {
    console.log(root);
  }
} catch (_) {
  await rm(root, { recursive: true, force: true });
  throw new Error('Pinned JSZip core preparation failed.');
}
