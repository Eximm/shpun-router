
let cases = [
 { uri: 'hy2://test@example.com/?sni=example.com', host:'example.com', port:'443' },
 { uri: 'hysteria2://test@[2001:db8::1]:8443/', host:'2001:db8::1', port:'8443' },
 { uri: 'hy2://test@[2001:db8::1]/', host:'2001:db8::1', port:'443' },
 { uri: { hy2:'hy2://test@example.com' }, host:'example.com', port:'443' },
 { uri: { hysteria2:'hysteria2://test@example.com:443/' }, host:'example.com', port:'443' }
];
for(let c in cases) {
 let info=parse_link_info(c.uri,0,0);
 if(info.host != c.host || info.port != c.port) die('RPC endpoint mismatch');
}
if(server_group({host:'rush11.lenivo.site',name:'server'}) != 'gateway') die('RU grouping mismatch');
if(server_group({host:'fi.shpyn.online',name:'server'}) != 'direct') die('Hysteria direct grouping mismatch');
