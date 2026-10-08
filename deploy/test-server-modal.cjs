// Run with Node.js; exercises the actual LuCI modal using a minimal DOM/RPC fixture.
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const source = fs.readFileSync(path.join(__dirname, '../package/shpun-router/files/www/luci-static/resources/view/status/include/01_shpunvpn.js'), 'utf8');
new Function(source); // LuCI modules are function bodies with a top-level return.
class Element {
  constructor(tag, attrs, children) {
    this.tag = tag; this.attrs = attrs || {}; this.children = []; this.handlers = {};
    this.className = this.attrs.class || ''; this.textContent = '';
    if (this.attrs.click) this.handlers.click = this.attrs.click;
    for (const child of Array.isArray(children) ? children : [children]) {
      if (child instanceof Element) this.children.push(child);
      else if (child != null) this.textContent += String(child);
    }
  }
  get firstChild() { return this.children[0]; }
  removeChild(child) { this.children.splice(this.children.indexOf(child), 1); }
  appendChild(child) { this.children.push(child); }
  addEventListener(type, fn) { this.handlers[type] = fn; }
  setAttribute(key, value) { this.attrs[key] = value; }
  click() { this.handlers.click({ preventDefault() {} }); }
}
const flatten = nodes => nodes.flatMap(n => n instanceof Element ? [n, ...flatten(n.children)] : []);
const settle = () => new Promise(resolve => setImmediate(resolve));
async function run(selected, excludeRu, emptyHysteria, adminDisabled = 0) {
  let modal = [], calls = [], notes = [];
  const servers = [
    {index:0, proto:'vless', host:'rush1.lenivo.site', name:'FI / Через РФ', latency_ms:30},
    {index:1, proto:'vless', host:'msk2.shpyn.online', name:'MSK / Напрямую', latency_ms:null},
    {index:2, proto:'hysteria2', host:'fi.example.net', name:'FI', latency_ms:80},
    {index:3, proto:'hy2', host:'nl.example.net', name:'NL', latency_ms:40}
  ].filter(s => !emptyHysteria || s.index < 2);
  const rpc = {declare: spec => (...args) => {
    calls.push([spec.method, ...args]);
    if (spec.method === 'servers_get') return Promise.resolve({ok:1, servers, selected, auto_effective_enabled:0, auto_admin_disabled:adminDisabled, auto_exclude_ru:excludeRu});
    if (spec.method === 'server_auto_set') return Promise.resolve({ok:1,effective_enabled:args[0],admin_disabled:0});
    return Promise.resolve({ok:1});
  }};
  const ui = {showModal: (title, nodes) => {modal = nodes;}, hideModal(){}, addNotification: (...args) => notes.push(args)};
  const code = source.slice(0, source.indexOf('return view.extend({')) + '\nreturn {openServersModal,getServerDisplayGroup};';
  const api = new Function('rpc','ui','E','window', code)(rpc,ui,(...args)=>new Element(...args),{setTimeout(){}});
  assert.equal(api.getServerDisplayGroup({proto:'hy2',host:'rush1.lenivo.site'}, 'Через РФ'), 'hysteria2');
  api.openServersModal(); await settle();
  const all = () => flatten(modal);
  const button = text => all().find(n => n.tag === 'button' && n.textContent.startsWith(text));
  assert.ok(button('Reality · РФ-шлюз · 1'));
  assert.ok(button('Reality · напрямую · 1'));
  assert.ok(button('Hysteria 2 · ' + (emptyHysteria ? 0 : 2)));
  assert.ok(!all().some(n => n.textContent === 'Доступен'));
  const list = () => all().find(n => n.className === 'shpun-server-list');
  if (!emptyHysteria) {
    button('Hysteria 2 ·').click();
    assert.equal(list().children.length, 2);
    assert.ok(list().children[0].children[0].textContent.includes('NL'));
    button('Найти рабочий').click(); await settle();
    assert.deepEqual(calls.find(c => c[0] === 'server_auto_start'), ['server_auto_start', [3,2]]);
    assert.ok(!calls.some(c => c[0] === 'server_auto_set'));
    list().children[0].click(); button('Применить').click(); await settle();
    assert.deepEqual(calls.find(c => c[0] === 'server_set'), ['server_set',3]);
    assert.ok(notes.some(n => flatten(n).some(e => e.textContent.includes('Авто-выбор выключен'))));
  } else assert.equal(button('Hysteria 2 ·').attrs.disabled, true);
  button('Reality · РФ-шлюз').click();
  assert.equal(!!button('Найти рабочий').disabled, !!excludeRu);
  assert.ok(all().some(n => n.attrs.title && n.attrs.title.includes('не до конечного')));
  button('Reality · напрямую').click();
  assert.ok(all().some(n => n.textContent === 'Нет ping'));
  const toggle = button('Автосмена сервера');
  assert.equal(toggle.attrs.role, 'switch');
  assert.equal(toggle.attrs['aria-checked'], 'false');
  if (adminDisabled) {
    assert.equal(toggle.disabled, true);
    assert.ok(toggle.children.some(n => n.textContent === 'Недоступна'));
    toggle.click(); await settle();
    assert.ok(!calls.some(c => c[0] === 'server_auto_set'));
    console.log('PASS modal admin-disabled switch cannot enable Auto');
    return;
  }
  assert.ok(toggle.children.some(n => n.textContent === 'Выкл'));
  toggle.click(); await settle();
  assert.equal(toggle.attrs['aria-checked'], 'true');
  assert.ok(toggle.children.some(n => n.textContent === 'Вкл'));
  toggle.click(); await settle();
  assert.equal(toggle.attrs['aria-checked'], 'false');
  assert.deepEqual(calls.filter(c => c[0] === 'server_auto_set'), [['server_auto_set',1],['server_auto_set',0]]);
  console.log(`PASS modal selected=${selected} excludeRu=${excludeRu} emptyHysteria=${emptyHysteria}`);
}
(async () => {
  await run(0,1,false); await run(2,0,false); await run(1,1,true);
  await run(2,1,false,1);
})().catch(err => {console.error(err);process.exitCode=1;});
