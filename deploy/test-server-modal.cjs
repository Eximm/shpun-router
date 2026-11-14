// Exercises the actual LuCI server modal with a minimal DOM and RPC fixture.
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const source = fs.readFileSync(path.join(__dirname, '../package/shpun-router/files/www/luci-static/resources/view/status/include/01_shpunvpn.js'), 'utf8');
new Function(source);
class Element {
  constructor(tag, attrs, children) {
    this.tag = tag;
    this.attrs = attrs || {};
    this.children = (Array.isArray(children) ? children : [children]).filter(child => child != null);
  }
  click() {
    if (!this.attrs.disabled) this.attrs.click({ preventDefault() {} });
  }
}
const flatten = nodes => nodes.flatMap(node => node instanceof Element ? [node, ...flatten(node.children)] : [node]);
const text = node => flatten([node]).filter(value => typeof value === 'string').join(' ');
const settle = () => new Promise(resolve => setImmediate(resolve));

async function run(adminDisabled, autoRunning) {
  let modal = [], calls = [];
  const servers = [
    {id:'name:moscow ru', index:21, name:'Moscow RU', selected:false, ru_exit:true, latency_ms:9, ping_target:'server', transport:'Hysteria 2'},
    {id:'name:helsinki fi', index:1, name:'Helsinki FI', selected:true, latency_ms:12, tunnel_ms:450, verified:true, ping_target:'gateway', transport:'Reality через РФ'},
    {id:'name:warsaw pl', index:5, name:'Warsaw PL', selected:false, latency_ms:30, tunnel_ms:200, verified:true, ping_target:'server', transport:'Hysteria 2'},
    {id:'name:riga lv', index:2, name:'Riga LV', selected:false, latency_ms:null, tunnel_failed:true, ping_target:'server', transport:'Hysteria 2'},
    {id:'name:helsinki-2 fi', index:6, name:'🇫🇮 Helsinki-2 FI', selected:false, latency_ms:18, tunnel_ms:380, verified:true, recommended:true, ping_target:'server', transport:'Hysteria 2'}
  ];
  const rpc = {declare: spec => (...args) => {
    calls.push([spec.method, ...args]);
    if (spec.method === 'servers_get') {
      return Promise.resolve({ok:1, servers, auto_effective_enabled:1,
        auto_admin_disabled:adminDisabled, auto_running:autoRunning});
    }
    return Promise.resolve({ok:1});
  }};
  const ui = {showModal: (_, nodes) => { modal = nodes; }, hideModal(){}, addNotification(){}};
  const code = source.slice(0, source.indexOf('return view.extend({')) + '\nreturn openServersModal;';
  const open = new Function('rpc','ui','E','window',code)(rpc,ui,(...args)=>new Element(...args),{setTimeout(){}});
  const buttons = () => flatten(modal).filter(node => node instanceof Element && node.tag === 'button');
  open(); await settle();
  const auto = buttons().find(node => text(node).startsWith('Автовыбор'));
  assert.equal(!!auto.attrs.disabled, !!(adminDisabled || autoRunning));
  const list = flatten(modal).find(node => node instanceof Element && node.attrs.class === 'shpun-server-list');
  // By the ping shown: direct servers, then relays (gateway ping), unreachable,
  // Russian exits last; each row names the connection the router uses.
  assert.deepEqual(list.children.map(text), [
    'Helsinki-2 FI Рекомендуем Hysteria 2 пинг 18 мс',
    'Warsaw PL Hysteria 2 пинг 30 мс',
    'Helsinki FI Текущий Reality через РФ шлюз 12 мс',
    'Riga LV Hysteria 2 Недоступен',
    'Moscow RU Hysteria 2 пинг 9 мс · не проверено'
  ]);
  list.children[0].click(); await settle();
  assert.deepEqual(calls.find(call => call[0] === 'server_set'), autoRunning ? undefined : ['server_set', 6, 'name:helsinki-2 fi']);
  // One-click switch to the recommended server and an explicit refresh of VPN times.
  open(); await settle();
  const recommend = buttons().find(node => text(node).startsWith('Подключить Helsinki-2 FI'));
  assert.equal(text(recommend), 'Подключить Helsinki-2 FI');
  assert.match(flatten(modal).filter(v=>typeof v==='string').join(' '), /Замеров через VPN ещё не было/);
  calls = [];
  recommend.click(); await settle();
  assert.deepEqual(calls.find(call => call[0] === 'server_set'), autoRunning ? undefined : ['server_set', 6, 'name:helsinki-2 fi']);
  open(); await settle();
  buttons().find(node => text(node) === 'Обновить замеры').click(); await settle();
  assert.deepEqual(calls.find(call => call[0] === 'servers_measure'), autoRunning ? undefined : ['servers_measure']);
  open(); await settle();
  buttons().find(node => text(node).startsWith('Автовыбор')).click(); await settle();
  assert.deepEqual(calls.find(call => call[0] === 'server_auto_start'), adminDisabled || autoRunning ? undefined : ['server_auto_start', []]);
}
(async () => {
  await run(0,false); await run(1,false); await run(0,true);
  console.log('PASS flat server list, global auto, stable manual group, recommend and measure buttons');
})().catch(err => { console.error(err); process.exitCode=1; });
