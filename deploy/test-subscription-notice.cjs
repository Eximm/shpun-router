// Semantic fixtures run in Node and (via prepare/verify) the real router ucode runtime.
const fs = require('node:fs'), path = require('node:path'), assert = require('node:assert/strict');
const base = path.join(__dirname, '../package/shpun-router/files');
const source = fs.readFileSync(path.join(base, 'etc/shpun/subscription-notice.uc'), 'utf8');
const rpcSource = fs.readFileSync(path.join(base, 'usr/share/rpcd/ucode/shpun.uc'), 'utf8');
// ucode binds lexical names in declaration order (unlike JavaScript function hoisting).
assert.ok(rpcSource.indexOf('function readfile(') < rpcSource.indexOf('function subscription_notice('));
assert.ok(rpcSource.includes('let now = clock()[0];'), 'RPC must use realtime seconds, not monotonic clock(true)');
const now = 1793031600;
const date = new Date(now * 1000).toUTCString();
const headers = (expire, extra = '') => `HTTP/2 200\r\nDate: ${date}\r\nsubscription-userinfo: upload=123; download=456; total=0; expire=${expire}\r\n${extra}\r\n`;
const input = (h, n = now) => ({headers: h, now: n, fingerprint: 'fixture-source'});
const cases = [
  ['expired', input(headers(now-10)), 'expired'],
  ['future', input(headers(now+100)), 'active'],
  ['unlimited', input(headers(0)), 'active'],
  ['equal', input(headers(now)), 'expired'],
  ['http-error', input(headers(now-10).replace('200','503')), 'unknown'],
  ['no-expiry', input(headers(now).replace(`expire=${now}`, '')), 'unknown'],
  ['duplicate-expiry', input(headers(now-10, 'subscription-userinfo: expire=1\r\n')), 'unknown'],
  ['conflicting-expiry', input(headers(`${now}; expire=${now+100}`)), 'unknown'],
  ['negative-expiry', input(headers(-1)), 'unknown'],
  ['oversized-expiry', input(headers('999999999999999999')), 'unknown'],
  ['bad-clock', input(headers(now-10), now-3600), 'unknown'],
  ['no-server-clock', input(headers(now-10).replace(/^Date:.*\r\n/m, '')), 'unknown'],
  ['stale-cache', input(headers(now-10, 'Age: 3600\r\n')), 'unknown'],
  ['proxy-connect-is-not-final', input(`HTTP/1.1 200 Connection established\r\nDate: ${date}\r\nsubscription-userinfo: expire=1\r\n\r\nHTTP/2 502\r\n\r\n`), 'unknown'],
  ['final-valid-response', input('HTTP/1.1 200 Connection established\r\n\r\n'+headers(now+100)), 'active'],
  ['transport-failure-after-expiry', {...input(''),previous:{fingerprint:'fixture-source',status:'expired',source_available:true,expires_at:now-10,last_confirmed_at:now-5}}, 'unknown'],
  ['renewal-clears-notice', {...input(headers(now+86400)),previous:{status:'expired',fingerprint:'fixture-source'}}, 'active'],
  ['invalid-header-value', input(headers('garbage')), 'unknown'],
];
function verify(name, result, wanted) {
  assert.equal(result.status,wanted,name);
  assert.equal(result.source_available,wanted!=='unknown',name);
  assert.ok(!JSON.stringify(result).match(/upload|download|subscription_url|userinfo/),name);
}
if(process.argv[2]==='prepare') {
  fs.mkdirSync(process.argv[3],{recursive:true});
  for(let i=0;i<cases.length;i++) fs.writeFileSync(path.join(process.argv[3],`${i}.json`),JSON.stringify(cases[i][1]));
  console.log(`PREPARED ${cases.length} metadata-only fixtures`);process.exit();
}
if(process.argv[2]==='verify') {
  for(let i=0;i<cases.length;i++) verify(cases[i][0],JSON.parse(fs.readFileSync(path.join(process.argv[3],`${i}.result.json`),'utf8')),cases[i][2]);
  console.log(`PASS actual ucode ${cases.length} cases`);process.exit();
}
const functions = source.slice(source.indexOf('function http_date'),source.indexOf('\nlet input;')).replaceAll(' in split(', ' of split(');
const run = new Function('match','int','index','trim','lc','length','split','push',functions+'\nreturn notice_state;')(
 (s,r)=>String(s).match(r),s=>parseInt(s,10),(a,v)=>a.indexOf(v),s=>s.trim(),s=>s.toLowerCase(),a=>a.length,(s,d)=>s.split(d),(a,v)=>a.push(v));
for(const [name,i,wanted] of cases)verify(name,run(i.headers,i.now,i.fingerprint,i.previous),wanted);
console.log(`PASS ${cases.length} metadata semantic cases`);

const widget = fs.readFileSync(path.join(base,'www/luci-static/resources/view/status/include/01_shpunvpn.js'),'utf8');
new Function(widget);
const elements = (tag,attrs,children)=>({tag,attrs:attrs||{},children:Array.isArray(children)?children:[children]});
const api = new Function('view','rpc','ui','poll','E','window','document',widget)(
 {extend:x=>x},{declare:()=>()=>Promise.resolve({})},{createHandlerFn:()=>()=>{}},{},elements,{},{getElementById:()=>null,createElement:()=>({}),head:{appendChild(){}}});
function flat(node) { if(node==null)return []; if(typeof node!=='object')return [String(node)];return [node,...(node.children||[]).flatMap(flat)]; }
for(const status of ['active','expired','unknown']) {
 const tree=flat(api.render({code:'fixture',has_sub:true,vpn_ready:true,subscription_url:'https://sub.netget.online/synthetic',subscription_notice:{status}}));
 const text=tree.filter(x=>typeof x==='string').join(' ');
 assert.equal(text.includes('Подписка истекла'),status==='expired');
 assert.equal(tree.some(x=>x.tag==='a'&&flat(x).includes('Продлить в ShpunApp')),status==='expired');
}
const unsafe=flat(api.render({code:'fixture',has_sub:true,subscription_notice:{status:'expired'},subscription_url:'javascript:alert(1)'}));
assert.ok(!unsafe.some(x=>x.tag==='a'&&x.attrs.href.startsWith('javascript:')));
console.log('PASS actual LuCI render expired/active/unknown and safe links');

const schedule=new Function('min','max',functions+'\nreturn schedule;')(Math.min,Math.max);
for(const [name,state,input,delay] of [
 ['active-six-hours',{status:'active',source_available:true,expires_at:now+86400},{},21600],
 ['unlimited',{status:'active',source_available:true,expires_at:0},{},21600],
 ['expiry-deadline',{status:'active',source_available:true,expires_at:now+120},{},120],
 ['near-expiry-minimum',{status:'active',source_available:true,expires_at:now+1},{},30],
 ['expired-five-minutes',{status:'expired',source_available:true},{},300],
 ['renewal-held',{status:'active',source_available:true,expires_at:now+86400},{portal_held:true},300],
 ['failure-first',{status:'unknown',source_available:false},{},300],
 ['failure-second',{status:'unknown',source_available:false},{previous:{poll_failures:1}},600],
 ['failure-capped',{status:'unknown',source_available:false},{previous:{poll_failures:5}},3600],
]){schedule(state,{now,...input});assert.equal(state.next_check_at-now,delay,name);}
console.log('PASS nine request-budget/expiry/backoff/renewal scheduling cases');
