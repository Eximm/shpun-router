'use strict';
const fs=require('fs'),path=require('path'),assert=require('assert');
const b=path.join(__dirname,'../package/shpun-router/files');
const src=fs.readFileSync(path.join(b,'etc/shpun/subscription-portal-state.uc'),'utf8');
const code=src.slice(src.indexOf('function decide'),src.indexOf('\nlet input='));
const decide=new Function(code+';return decide;')();
const binding='a'.repeat(64),generation='b'.repeat(32),now=1793042000;
const expired={status:'expired',expires_at:now-10,checked_at:now,source_available:true};
const active={...expired,status:'active',expires_at:now+3600};
const state={phase:'captive',binding,generation,acknowledged:false,expires_at:now-10};
const base={binding,generation,now};
const cases=[
 ['healthy',{notice:active},'idle'],['offline',{notice:{}},'idle'],
 ['expired',{notice:expired},'captive'],['stale-expiry',{notice:{...expired,checked_at:now-2401}},'idle'],
 ['expired-between-thirty-minute-polls',{notice:{...expired,checked_at:now-1799}},'captive'],
 ['expired-poll-margin',{notice:{...expired,checked_at:now-2400}},'captive'],
 ['future-clock',{notice:{...expired,checked_at:now+1}},'idle'],
 ['acknowledged',{notice:expired,previous:state,ack:generation},'direct'],
 ['ack-sticks',{notice:expired,previous:{...state,acknowledged:true}},'direct'],
 ['unknown-does-not-recapture',{notice:{},previous:state},'verifying'],
 ['paid-waits-for-profile',{notice:active,previous:state},'verifying'],
 ['paid-and-authorized',{notice:active,previous:state,profile:generation},'idle'],
 ['wrong-profile-generation',{notice:active,previous:state,profile:'x'},'verifying'],
 ['expiry-is-not-revived-by-profile',{notice:expired,previous:state,profile:generation},'captive'],
 ['old-binding',{notice:active,previous:{...state,binding:'c'.repeat(64)}},'idle'],
 ['unlimited-renewal',{notice:{...active,expires_at:0},previous:state,profile:generation},'idle'],
 ['stale-paid-keeps-direct',{notice:{...active,checked_at:now-601},previous:state,profile:generation},'verifying'],
 ['six-hours-minus-one',{notice:expired,previous:{...state,acknowledged:true,acknowledged_at:now-21599}},'direct'],
 ['six-hours-boundary',{notice:expired,previous:{...state,acknowledged:true,acknowledged_at:now-21600},ack:generation,ack_at:now-21600},'captive'],
 ['six-hours-expired',{notice:expired,previous:{...state,acknowledged:false,acknowledged_at:now-21601},ack:generation,ack_at:now-21601},'captive'],
 ['next-payment-click',{notice:expired,previous:{...state,acknowledged:false,acknowledged_at:now-21601},ack:generation,ack_at:now},'direct'],
 ['paid-before-six-hours',{notice:active,previous:{...state,acknowledged:true,acknowledged_at:now-100},profile:generation},'idle'],
 ['new-expiry-new-session',{notice:expired,previous:{phase:'idle',binding},profile:'old'},'captive'],
];
if(process.argv[2]==='prepare'){
 fs.mkdirSync(process.argv[3],{recursive:true});
 cases.forEach(([name,i],k)=>fs.writeFileSync(path.join(process.argv[3],`${k}.json`),JSON.stringify({...base,...i})));
 process.exit();
}
cases.forEach(([name,i,wanted],k)=>{
 const got=process.argv[2]==='verify'?JSON.parse(fs.readFileSync(path.join(process.argv[3],`${k}.result.json`),'utf8')):decide({...base,...i});
 assert.equal(got.phase,wanted,name);
 assert.ok(!JSON.stringify(got).match(/subscription_url|uuid|userinfo/),name);
});
const widget=fs.readFileSync(path.join(b,'www/luci-static/resources/view/status/include/01_shpunvpn.js'),'utf8');
assert.ok(!widget.includes('Страница подписки'));
const html=fs.readFileSync(path.join(b,'usr/share/shpun/portal/page.html'),'utf8');
assert.ok(html.includes('Продлить в ShpunApp'));
assert.ok(!/https?:\/\//.test(html),'page must not load external resources');
assert.ok(!html.includes('sub.netget.online'));
assert.ok(html.includes('name="token"'));
console.log(`PASS ${cases.length} captive lifecycle cases and private styled-page contract`);