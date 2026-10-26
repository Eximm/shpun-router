// Generate synthetic fixtures locally, then run test-xhttp-build.sh on an isolated
// OpenWrt staging directory. No real subscription or production state is needed.
const fs = require('node:fs'), path = require('node:path'), assert = require('node:assert/strict');
const cases = JSON.parse(fs.readFileSync(path.join(__dirname, 'fixtures/xhttp-cases.json'), 'utf8'));
const [action, directory] = process.argv.slice(2);
if (!directory || !['prepare', 'verify'].includes(action)) throw Error('Usage: node test-xhttp-fixtures.cjs prepare|verify DIRECTORY');
const root = path.join(__dirname, '../package/shpun-router/files');
if (action === 'prepare') {
  fs.mkdirSync(directory, {recursive:true});
  const copy = (from, name) => fs.writeFileSync(path.join(directory,name), fs.readFileSync(from,'utf8').replace(/\r\n/g,'\n'));
  for (const name of ['xhttp-outbound.uc','hysteria2-outbound.uc']) copy(path.join(root,'etc/shpun',name),name);
  copy(path.join(root,'etc/shpun/build-config.sh'),'build-current.sh');
  copy(path.join(root,'usr/share/rpcd/ucode/shpun.uc'),'rpc-current.uc');
  const rpc=fs.readFileSync(path.join(root,'usr/share/rpcd/ucode/shpun.uc'),'utf8');
  const helpers=['norm','cleanup_server_name','link_value','parse_link_info','public_server_info'].map(name=>{
    const m=rpc.match(new RegExp('function '+name+'\\([^\\n]*\\) \\{[\\s\\S]*?\\n\\}'));
    assert(m, 'Missing RPC helper '+name); return m[0];
  }).join('\n');
  fs.writeFileSync(path.join(directory,'rpc-test-current.uc'),helpers+`
let x=public_server_info(parse_link_info("vless://private@example.com:443?type=%78http&security=tls&path=%2Fsecret#Test",3,3));
if(x.transport!="xhttp" || x.security!="tls" || length(keys(x))!=8 || ("path" in x) || ("uri" in x)) die("Bad public metadata");
let r=public_server_info(parse_link_info("vless://private@example.com:443?type=tcp&security=reality",0,0));
if(r.transport!="tcp" || r.security!="reality") die("Reality regression");
let h=public_server_info(parse_link_info("hy2://private@example.com",0,0));
if(h.proto!="hy2" || h.port!="443") die("Hysteria regression");
print("PASS public transport metadata\\n");
`);
  copy(path.join(__dirname,'test-xhttp-build.sh'),'test.sh');
  fs.writeFileSync(path.join(directory,'owned'),'xhttp-fixture\n');
  cases.forEach((c,i)=>fs.writeFileSync(path.join(directory,`sub-${i}.json`),JSON.stringify({subscription:{links:[c.uri]}})));
  fs.writeFileSync(path.join(directory,'cases.tsv'),cases.map((c,i)=>`${i} ${+c.ok}\n`).join(''));
  console.log(`Prepared ${cases.length} synthetic cases`);
} else {
  let checked=0;
  for (const file of fs.readdirSync(directory).filter(f=>/^result-.+-\d+\.json$/.test(f))) {
    const i=Number(file.match(/-(\d+)\.json$/)[1]), c=cases[i];
    assert(c.ok);
    const config=JSON.parse(fs.readFileSync(path.join(directory,file),'utf8')), o=config.outbounds[0], u=new URL(c.uri);
    const q=u.searchParams;
    if(q.get('type')==='xhttp') {
      assert.equal(o.protocol,'vless'); assert.equal(o.streamSettings.network,'xhttp');
      assert.equal(o.streamSettings.security,q.get('security')||'none');
      assert.equal(o.streamSettings.sockopt.domainStrategy,'UseIPv4v6');
      if(!/^[0-9.]+$/.test(u.hostname) && !u.hostname.includes(':')) {
        assert.equal(config.dns.tag,'xhttp-bootstrap');
        assert.deepEqual(config.dns.servers[0].domains,['full:'+u.hostname]);
        assert.equal(config.dns.servers[0].address,'1.1.1.1');
        assert.deepEqual(config.routing.rules[0],{type:'field',inboundTag:['xhttp-bootstrap'],outboundTag:'direct'});
      }
      assert.equal(o.settings.vnext[0].address,u.hostname.replace(/^\[|\]$/g,''));
      assert.equal(o.settings.vnext[0].port,Number(u.port));
      const x=o.streamSettings.xhttpSettings;
      assert.equal(x.path,q.get('path')||'/'); assert.equal(x.host,q.get('host')||'');
      assert.equal(x.mode,q.get('mode')||'auto');
      if(q.has('extra')) assert.deepEqual(x.extra,JSON.parse(q.get('extra')));
      assert(!o.settings.vnext[0].users[0].flow);
      if(q.get('security')==='tls') assert.equal(o.streamSettings.tlsSettings.allowInsecure,false);
    } else assert.equal(o.protocol,c.name==='hy2'?'hysteria':'vless');
    checked++;
  }
  assert(checked>=cases.filter(c=>c.ok).length,'Missing successful generated configs');
  const routingFiles=fs.readdirSync(directory).filter(f=>/^routing-.+-xhttp\.json$/.test(f));
  assert(routingFiles.length>=3,'Missing routing-mode results');
  for(const file of routingFiles) {
    const x=JSON.parse(fs.readFileSync(path.join(directory,file),'utf8'));
    const t=JSON.parse(fs.readFileSync(path.join(directory,file.replace(/-xhttp\.json$/,'-tcp.json')),'utf8'));
    assert.deepEqual(x.routing,t.routing); assert.deepEqual(x.inbounds,t.inbounds);
  }
  console.log(`PASS ${checked} generated configurations: endpoints, modes, escaping, extra and transport coexistence`);
}
