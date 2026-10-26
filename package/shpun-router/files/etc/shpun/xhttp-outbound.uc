// URI on stdin only: never expose subscription credentials in argv or logs.
import { readfile } from 'fs';

function decode(s) {
    if (match(replace(s, /%[0-9a-fA-F]{2}/g, ''), /%/)) die('Invalid URI encoding');
    return replace(s, /%([0-9a-fA-F]{2})/g, (m, h) => chr(int(h, 16)));
}
function reject_insecure(value) {
    if (type(value) == 'object') {
        for (let k in keys(value)) {
            if ((k == 'allowInsecure' || k == 'insecure') && value[k] != false && value[k] != 0)
                die('Insecure TLS is not supported');
            reject_insecure(value[k]);
        }
    }
    else if (type(value) == 'array') {
        for (let v in value) reject_insecure(v);
    }
}
let uri = trim(readfile('/dev/stdin'));
if (length(uri) > 65536) die('URI too large');
let p = match(uri, /^vless:\/\/([^@?#]+)@([^?#]+)(\?([^#]*))?(#.*)?$/);
if (!p) die('Invalid VLESS URI');
let hp = match(p[2], /^(\[([0-9a-fA-F:]+)\]|([^:\/[:space:]]+)):([0-9]+)$/);
if (!hp) die('Invalid endpoint');
let port = int(hp[4]);
if (port < 1 || port > 65535) die('Invalid port');
let host = hp[2] || hp[3], id = decode(p[1]), q = {};
if (!id || match(id, /[[:cntrl:]]/)) die('Invalid user ID');
for (let item in split(p[4] || '', '&')) {
    if (!item) continue;
    let eq = index(item, '='), key = decode(eq < 0 ? item : substr(item, 0, eq));
    if (key in q) die('Duplicate URI parameter');
    q[key] = decode(eq < 0 ? '' : substr(item, eq + 1));
}
for (let key in keys(q)) {
    if (!(key in { type: 1, security: 1, encryption: 1, flow: 1, sni: 1, fp: 1,
        alpn: 1, host: 1, path: 1, mode: 1, extra: 1, pbk: 1, sid: 1, spx: 1,
        packetEncoding: 1, allowInsecure: 1, insecure: 1 })) die('Unsupported XHTTP parameter');
}
if (q.type != 'xhttp') die('Not XHTTP');
if (q.flow) die('XHTTP does not support Vision flow');
if (q.encryption && q.encryption != 'none') die('Unsupported VLESS encryption');
if ((q.insecure && q.insecure != '0') || (q.allowInsecure && q.allowInsecure != '0' && q.allowInsecure != 'false'))
    die('Insecure TLS is not supported');
let security = q.security || 'none', mode = q.mode || 'auto';
if (!(mode in { auto: 1, 'packet-up': 1, 'stream-up': 1, 'stream-one': 1 })) die('Invalid XHTTP mode');
let path = q.path || '/';
if (substr(path, 0, 1) != '/' || match(path, /[[:cntrl:]]/)) die('Invalid XHTTP path');
if (match(q.host || '', /[[:cntrl:]]/)) die('Invalid HTTP host');
let xhttp = { host: q.host || '', path: path, mode: mode };
if ('extra' in q) {
    let extra = json(q.extra);
    if (type(extra) != 'object') die('XHTTP extra must be an object');
    reject_insecure(extra);
    xhttp.extra = extra;
}
let stream = { network: 'xhttp', security: security, xhttpSettings: xhttp };
// Resolve the transport endpoint through the tagged bootstrap DNS, not LAN DNS.
stream.sockopt = { domainStrategy: 'UseIPv4v6' };
if (security == 'tls') {
    stream.tlsSettings = { serverName: q.sni || host, fingerprint: q.fp || 'firefox', allowInsecure: false };
    if (q.alpn) stream.tlsSettings.alpn = split(q.alpn, ',');
}
else if (security == 'reality') {
    if (!q.pbk || !q.sni) die('REALITY requires public key and SNI');
    stream.realitySettings = { show: false, serverName: q.sni, fingerprint: q.fp || 'firefox',
        publicKey: q.pbk, shortId: q.sid || '', spiderX: q.spx || '/' };
}
else if (security != 'none') die('Unsupported transport security');
let user = { id: id, encryption: 'none' };
if (q.packetEncoding) {
    if (q.packetEncoding != 'xudp' && q.packetEncoding != 'packet') die('Invalid packet encoding');
    user.packetEncoding = q.packetEncoding;
}
if (getenv('XHTTP_OUTPUT') == 'bootstrap') {
    let domains = [];
    if (!match(host, /:/) && !match(host, /^[0-9.]+$/)) push(domains, 'full:' + host);
    let down = xhttp.extra?.downloadSettings?.address;
    if (type(down) == 'string' && !match(down, /:/) && !match(down, /^[0-9.]+$/))
        push(domains, 'full:' + down);
    if (length(domains)) print(sprintf('%J', {tag:'xhttp-bootstrap', disableFallbackIfMatch:true,
        servers:[{address:'1.1.1.1', domains:domains, skipFallback:true}]}));
    exit(0);
}
print(sprintf('%J', { tag: 'proxy', protocol: 'vless', settings: {
    vnext: [{ address: host, port: port, users: [user] }]
}, streamSettings: stream }));
