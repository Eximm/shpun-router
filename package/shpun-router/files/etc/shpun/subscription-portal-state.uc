import { readfile } from 'fs';
// Pure decision: a transport/header failure never creates captivity.
function decide(i) {
 let n=i.notice||{},p=i.previous||{},now=i.now;
 let held=p.binding==i.binding && !!p.generation;
 let fresh=n.source_available==true && n.checked_at<=now && now-n.checked_at<=(n.status=='expired'?2400:600);
 let expired=fresh && n.status=='expired' && n.expires_at>0 && n.expires_at<=now;
 let active=fresh && n.status=='active' && (n.expires_at==0 || n.expires_at>now);
 if(!held && !expired)return {phase:'idle',binding:i.binding};
 let generation=held?p.generation:i.generation;
 if(active && i.profile==generation)return {phase:'idle',binding:i.binding};
 let acknowledged=(held&&p.acknowledged)||i.ack==generation;
 let acknowledged_at=i.ack_at||p.acknowledged_at||0;
 // Legacy local pilots without a timestamp get one grace window, never an endless one.
 if(acknowledged && !acknowledged_at)acknowledged_at=now;
 acknowledged=acknowledged && acknowledged_at<=now && now-acknowledged_at<21600;
 let phase=expired ? (acknowledged?'direct':'captive') : 'verifying';
 return {phase,binding:i.binding,generation,acknowledged,acknowledged_at,expires_at:expired?n.expires_at:p.expires_at||0};
}
let input=json(readfile('/dev/stdin'));
if(type(input)!='object'||type(input.now)!='int'||!match(input.binding||'',/^[a-f0-9]{64}$/)||!match(input.generation||'',/^[a-f0-9]{32}$/))exit(1);
print(sprintf('%J\n',decide(input)));