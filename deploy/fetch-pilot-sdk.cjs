// Download a pinned OpenWrt SDK using small parallel requests. Each byte
// range and the reassembled archive are verified before it is extracted.
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const { execFile } = require('node:child_process');
const { promisify } = require('node:util');
const curl = promisify(execFile);
const [url, filename, sizeText, expectedHash] = process.argv.slice(2);
const size = Number(sizeText);
const mirror = url.replace('https://downloads.openwrt.org/', 'https://downloads.staging.openwrt.org/');
const chunkSize = 8 * 1024 * 1024;
const chunks = Math.ceil(size / chunkSize);
const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'openwrt-sdk-ranges-'));

async function download(index) {
  const start = index * chunkSize;
  const end = Math.min(size, start + chunkSize) - 1;
  const target = path.join(dir, String(index));
  for (const endpoint of [url, mirror]) {
    try {
      const { stdout } = await curl('curl', [
        '-4', '-fLsS', '--connect-timeout', '8', '--max-time', '24',
        '--range', start + '-' + end, '--max-filesize', String(end - start + 1),
        '--dump-header', target + '.headers', '-o', target, '-w', '%{http_code}', endpoint,
      ]);
      const headers = fs.readFileSync(target + '.headers', 'utf8');
      const range = 'content-range: bytes ' + start + '-' + end + '/' + size;
      if (stdout === '206' &&
          headers.toLowerCase().split(/\r?\n/).includes(range) &&
          fs.statSync(target).size === end - start + 1) return;
    } catch {}
  }
  throw new Error('SDK range ' + index + ' unavailable from both OpenWrt endpoints');
}

(async () => {
  let next = 0;
  const workers = Array.from({ length: 6 }, async () => {
    while (next < chunks) await download(next++);
  });
  const result = await Promise.allSettled(workers);
  const failed = result.find(worker => worker.status === 'rejected');
  if (failed) throw failed.reason;
  const hash = crypto.createHash('sha256');
  const file = fs.openSync(filename + '.partial', 'w');
  try {
    for (let i = 0; i < chunks; i++) {
      const data = fs.readFileSync(path.join(dir, String(i)));
      hash.update(data);
      let offset = 0;
      while (offset < data.length) offset += fs.writeSync(file, data, offset);
    }
  } finally {
    fs.closeSync(file);
  }
  if (hash.digest('hex') !== expectedHash) throw new Error('SDK SHA256 mismatch');
  fs.renameSync(filename + '.partial', filename);
  console.log('SDK verified: ' + chunks + ' ranges, ' + size + ' bytes, SHA256 ' + expectedHash);
})().catch(error => {
  console.error(error);
  process.exitCode = 1;
}).finally(() => fs.rmSync(dir, { recursive: true, force: true }));
