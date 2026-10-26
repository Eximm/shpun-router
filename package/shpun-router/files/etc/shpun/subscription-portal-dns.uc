import {readfile,writefile,unlink} from 'fs';
import {cursor} from 'uci';
let c=cursor(),path=ARGV[0],action=ARGV[1],keys=['server','noresolv','resolvfile'];
if(!match(path||'',/^\/tmp\/shpun-subscription-portal\/dns\.json$/))exit(1);
let wanted={server:null,noresolv:'0',resolvfile:'/tmp/resolv.conf.d/resolv.conf.auto'};
if(action=='apply') {
 let old={};for(let k in keys)old[k]=c.get('dhcp','@dnsmasq[0]',k);
 if(!readfile(path))writefile(path,sprintf('%J',{old,wanted}));
 for(let k in keys){c.delete('dhcp','@dnsmasq[0]',k);if(wanted[k]!=null)c.set('dhcp','@dnsmasq[0]',k,wanted[k]);}c.save('dhcp');
} else if(action=='restore') {
 let s;try{s=json(readfile(path));}catch(e){exit(0);}
 for(let k in keys){if(sprintf('%J',c.get('dhcp','@dnsmasq[0]',k))!=sprintf('%J',s.wanted[k]))continue;
  c.delete('dhcp','@dnsmasq[0]',k);if(s.old[k]!=null)c.set('dhcp','@dnsmasq[0]',k,s.old[k]);}
 c.save('dhcp');unlink(path);
} else exit(1);