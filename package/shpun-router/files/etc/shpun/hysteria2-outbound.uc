// Read the URI from stdin, never from argv (credentials must not appear in ps).
import { readfile } from 'fs';

function decode(s) {
    if (match(replace(s, /%[0-9a-fA-F]{2}/g, ''), /%/))
        die('Invalid percent encoding');
    return replace(s, /%([0-9a-fA-F]{2})/g, (m, h) => chr(int(h, 16)));
}

let uri = trim(readfile('/dev/stdin'));
let parts = match(uri, /^(hysteria2|hy2):\/\/([^?#]+)(\?([^#]*))?(#.*)?$/);
if (!parts) die('Invalid Hysteria 2 URI');
let authority = replace(parts[2], /\/$/, '');
let at = rindex(authority, '@');
let auth = at >= 0 ? decode(substr(authority, 0, at)) : '';
let hostport = at >= 0 ? substr(authority, at + 1) : authority;
let hp = match(hostport, /^(\[([0-9a-fA-F:]+)\]|([^:\/[:space:]]+))(:([0-9]+))?$/);
if (!hp) die('Invalid Hysteria 2 endpoint');
let host = hp[2] || hp[3];
let port = hp[5] ? int(hp[5]) : 443;
if (port < 1 || port > 65535) die('Invalid Hysteria 2 port');
let q = {};
for (let item in split(parts[4] || '', '&')) {
    if (!item) continue;
    let eq = index(item, '=');
    let key = decode(eq >= 0 ? substr(item, 0, eq) : item);
    if (key in q) die('Duplicate Hysteria 2 parameter');
    q[key] = decode(eq >= 0 ? substr(item, eq + 1) : '');
}
// Fail closed for features that have not been covered by router acceptance tests.
for (let key in keys(q))
    if (!(key in { sni: true, insecure: true, obfs: true, 'obfs-password': true, fm: true }))
        die('Unsupported Hysteria 2 parameter');
if (q.insecure && q.insecure != '0' && q.insecure != '1')
    die('Invalid Hysteria 2 insecure flag');
if (q.insecure == '1')
    die('Insecure TLS is not supported by the router engine');
if (q.obfs && q.obfs != 'salamander') die('Unsupported Hysteria 2 obfuscation');
if (q.obfs && !q['obfs-password']) die('Missing obfuscation password');
if (!q.obfs && q['obfs-password']) die('Obfuscation type missing');
let stream = {
    network: 'hysteria', security: 'tls',
    tlsSettings: { serverName: q.sni || host, alpn: ['h3'] },
    hysteriaSettings: { version: 2, auth: auth }
};
if (q.obfs)
    stream.finalmask = { udp: [{ type: 'salamander', settings: { password: q['obfs-password'] } }] };
if (q.fm) {
    if (q.obfs) die('Conflicting obfuscation parameters');
    let fm = json(q.fm);
    if (type(fm) != 'object') die('Invalid FinalMask');
    for (let key in keys(fm))
        if (key != 'udp' && key != 'quicParams') die('Unsupported FinalMask section');
    stream.finalmask = fm;
}
print(sprintf('%J', {
    tag: 'proxy', protocol: 'hysteria',
    settings: { version: 2, address: host, port: port }, streamSettings: stream
}));
