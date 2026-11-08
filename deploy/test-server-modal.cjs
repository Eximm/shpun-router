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
    {id:'name:helsinki fi', index:1, name:'Helsinki FI', selected:true},
    {id:'name:helsinki-2 fi', index:6, name:'Helsinki-2 FI', selected:false}
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
  assert.deepEqual(list.children.map(text), ['Helsinki FI Текущий', 'Helsinki-2 FI ']);
  assert.doesNotMatch(flatten(modal).filter(value=>typeof value==='string').join(' '), /Hysteria|XHTTP|Reality|Через РФ/i);
  list.children[1].click(); await settle();
  assert.deepEqual(calls.find(call => call[0] === 'server_set'), autoRunning ? undefined : ['server_set', 6, 'name:helsinki-2 fi']);
  open(); await settle();
  buttons().find(node => text(node).startsWith('Автовыбор')).click(); await settle();
  assert.deepEqual(calls.find(call => call[0] === 'server_auto_start'), adminDisabled || autoRunning ? undefined : ['server_auto_start', []]);
}
(async () => {
  await run(0,false); await run(1,false); await run(0,true);
  console.log('PASS flat server list, global auto and stable manual group');
})().catch(err => { console.error(err); process.exitCode=1; });
