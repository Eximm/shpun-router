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
const suffix = url.replace(/^https:\/\/downloads\.openwrt\.org\//, '');
const endpoints = [
  url,
  'https://mirror-03.infra.openwrt.org/' + suffix,
  'https://mirrors.tuna.tsinghua.edu.cn/openwrt/' + suffix,
  'https://downloads.staging.openwrt.org/' + suffix,
];
const chunkSize = 4 * 1024 * 1024;
const chunks = Math.ceil(size / chunkSize);
const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'openwrt-sdk-ranges-'));
let completed = 0;

async function download(index) {
  const first = index * chunkSize;
  const end = Math.min(size, first + chunkSize) - 1;
  const target = path.join(dir, String(index));
  const piece = target + '.piece';
  const headerFile = target + '.headers';
  let start = first;
  for (let attempt = 0; attempt < 12 && start <= end; attempt++) {
    fs.rmSync(piece, { force: true });
    fs.rmSync(headerFile, { force: true });
    let status;
    try {
      ({ stdout: status } = await curl('curl', [
        '-4', '-fLsS', '--connect-timeout', '8', '--max-time', '35',
        '--range', start + '-' + end, '--max-filesize', String(end - start + 1),
        '--dump-header', headerFile, '-o', piece, '-w', '%{http_code}',
        endpoints[attempt % endpoints.length],
      ]));
    } catch (err) {
      status = err.stdout;
    }
    if (status !== '206' || !fs.existsSync(headerFile) || !fs.existsSync(piece)) continue;
    const headers = fs.readFileSync(headerFile, 'utf8');
    const range = 'content-range: bytes ' + start + '-' + end + '/' + size;
    if (!headers.toLowerCase().split(/\r?\n/).includes(range)) continue;
    const data = fs.readFileSync(piece);
    if (!data.length || data.length > end - start + 1) continue;
    fs.appendFileSync(target, data);
    start += data.length;
  }
  if (start <= end) throw new Error('SDK range ' + index + ' incomplete after ' + (start - first) + ' bytes');
  if (++completed % 8 === 0 || completed === chunks)
    console.log('SDK progress: ' + completed + '/' + chunks + ' ranges');
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
