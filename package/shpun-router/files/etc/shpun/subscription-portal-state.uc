import { readfile } from 'fs';
// Pure decision: a transport/header failure never creates captivity.
function decide(i) {
 let n=i.notice||{},p=i.previous||{},now=i.now;
 let held=p.binding==i.binding && !!p.generation;
 let fresh=n.source_available==true && n.checked_at<=now && now-n.checked_at<=600;
 let expired=fresh && n.status=='expired' && n.expires_at>0 && n.expires_at<=now;
 let active=fresh && n.status=='active' && (n.expires_at==0 || n.expires_at>now);
 if(!held && !expired)return {phase:'idle',binding:i.binding};
 let generation=held?p.generation:i.generation;
 if(active && i.profile==generation)return {phase:'idle',binding:i.binding};
 let phase=expired ? ((held && p.acknowledged)||i.ack==generation?'direct':'captive') : 'verifying';
 return {phase,binding:i.binding,generation,acknowledged:(held&&p.acknowledged)||i.ack==generation,expires_at:expired?n.expires_at:p.expires_at||0};
}
let input=json(readfile('/dev/stdin'));
if(type(input)!='object'||type(input.now)!='int'||!match(input.binding||'',/^[a-f0-9]{64}$/)||!match(input.generation||'',/^[a-f0-9]{32}$/))exit(1);
print(sprintf('%J\n',decide(input)));