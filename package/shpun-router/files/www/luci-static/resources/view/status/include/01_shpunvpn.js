'use strict';
'require view';
'require rpc';
'require ui';
'require poll';

/* ============================================================
 *  RPC
 * ========================================================== */

var callShpunState = rpc.declare({
	object: 'shpun', method: 'state', expect: { '': {} }
});
var callShpunRoutingGet = rpc.declare({
	object: 'shpun', method: 'routing_get', expect: { '': {} }
});
var callShpunRoutingSet = rpc.declare({
	object: 'shpun', method: 'routing_set', params: ['mode'], expect: { '': {} }
});
var callShpunOtaCheck = rpc.declare({
	object: 'shpun', method: 'ota_check', expect: { '': {} }
});
var callShpunOtaInstall = rpc.declare({
	object: 'shpun', method: 'ota_install', expect: { '': {} }
});
var callShpunRefreshConnection = rpc.declare({
	object: 'shpun', method: 'refresh_connection', expect: { '': {} }
});
var callShpunResetVpn = rpc.declare({
	object: 'shpun', method: 'reset_vpn', expect: { '': {} }
});
var callShpunCustomRoutesGet = rpc.declare({
	object: 'shpun', method: 'custom_routes_get', expect: { '': {} }
});
var callShpunCustomRoutesSet = rpc.declare({
	object: 'shpun', method: 'custom_routes_set', params: ['vpn', 'direct'], expect: { '': {} }
});
var callShpunServersGet = rpc.declare({
	object: 'shpun', method: 'servers_get', expect: { '': {} }
});
var callShpunServerSet = rpc.declare({
	object: 'shpun', method: 'server_set', params: ['index'], expect: { '': {} }
});

/* ============================================================
 *  Styles
 * ========================================================== */

function injectStyles() {
	if (document.getElementById('shpun-widget-style')) return;
	var css = ''
		+ '.shpun-widget-card{position:relative;margin:0 0 16px;padding:20px;border-radius:24px;overflow:hidden;color:#eef2ff;background:linear-gradient(135deg,rgba(6,18,36,.98) 0%,rgba(8,24,50,.98) 42%,rgba(20,19,58,.98) 100%);border:1px solid rgba(110,130,185,.18);box-shadow:0 18px 44px rgba(0,0,0,.28);}'
		+ '.shpun-widget-card:before{content:"";position:absolute;inset:0;pointer-events:none;background:radial-gradient(circle at 0% 0%,rgba(95,140,255,.15),transparent 30%),radial-gradient(circle at 100% 0%,rgba(139,92,246,.14),transparent 28%),radial-gradient(circle at 50% 100%,rgba(59,130,246,.08),transparent 35%);}'
		+ '.shpun-widget-inner{position:relative;z-index:1;display:flex;flex-direction:column;gap:16px;}'
		+ '.shpun-widget-header{display:flex;justify-content:space-between;align-items:flex-start;gap:16px;}'
		+ '.shpun-title-wrap{display:flex;flex-direction:column;gap:5px;min-width:0;}'
		+ '.shpun-kicker{display:flex;align-items:center;gap:8px;font-size:12px;font-weight:700;color:#9fb5ff;}'
		+ '.shpun-kicker-dot{width:8px;height:8px;border-radius:999px;background:#6ea8ff;box-shadow:0 0 10px rgba(110,168,255,.65);}'
		+ '.shpun-title{font-size:22px;line-height:1.08;font-weight:800;letter-spacing:-.025em;color:#fff;}'
		+ '.shpun-subtitle{font-size:13px;line-height:1.45;color:#c2ccde;max-width:680px;}'
		+ '.shpun-status-group{display:flex;flex-direction:column;align-items:flex-end;gap:8px;min-width:0;max-width:620px;}'
		+ '.shpun-status-row{display:flex;flex-wrap:wrap;justify-content:flex-end;align-items:center;gap:8px;min-width:0;}'
		+ '.shpun-badge{display:inline-flex;align-items:center;padding:7px 12px;border-radius:999px;font-size:12px;font-weight:800;white-space:nowrap;border:1px solid transparent;align-self:flex-start;}'
		+ '.shpun-badge-text{min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;}'
		+ '.shpun-badge-dot{width:8px;height:8px;margin-right:8px;border-radius:999px;flex:0 0 auto;}'
		+ '.shpun-badge--off{background:rgba(148,163,184,.11);color:#e5e7eb;border-color:rgba(148,163,184,.20);}'
		+ '.shpun-badge--off .shpun-badge-dot{background:#94a3b8;}'
		+ '.shpun-badge--warn{background:rgba(250,204,21,.12);color:#fde68a;border-color:rgba(250,204,21,.22);}'
		+ '.shpun-badge--warn .shpun-badge-dot{background:#facc15;}'
		+ '.shpun-badge--ok{background:rgba(34,197,94,.14);color:#bbf7d0;border-color:rgba(34,197,94,.24);}'
		+ '.shpun-badge--ok .shpun-badge-dot{background:#22c55e;}'
		+ '.shpun-badge--err{background:rgba(248,113,113,.14);color:#fecaca;border-color:rgba(248,113,113,.24);}'
		+ '.shpun-badge--err .shpun-badge-dot{background:#f87171;}'
		+ '.shpun-badge--server{max-width:220px;background:rgba(96,165,250,.12);color:#dbeafe;border-color:rgba(96,165,250,.22);}'
		+ '.shpun-badge--server .shpun-badge-dot{background:#60a5fa;}'
		+ '.shpun-badge--exit{max-width:260px;background:rgba(20,184,166,.12);color:#ccfbf1;border-color:rgba(45,212,191,.22);}'
		+ '.shpun-badge--exit .shpun-badge-dot{background:#2dd4bf;}'
		+ '.shpun-badge--check{background:rgba(168,85,247,.12);color:#ede9fe;border-color:rgba(196,181,253,.22);}'
		+ '.shpun-badge--check .shpun-badge-dot{background:#a78bfa;}'
		+ '.shpun-hint-box{padding:13px 15px;border-radius:16px;border:1px solid rgba(120,140,180,.16);background:rgba(10,17,32,.40);color:#cad4e4;font-size:13px;line-height:1.55;}'
		+ '.shpun-card-main{display:grid;grid-template-columns:minmax(0,1fr) 220px;gap:16px;align-items:stretch;}'
		+ '.shpun-col-main{min-width:0;min-height:100%;display:flex;flex-direction:column;gap:14px;}'
		+ '.shpun-fields-grid{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:12px;}'
		+ '.shpun-field{min-width:0;padding:13px 14px;border-radius:16px;background:linear-gradient(180deg,rgba(255,255,255,.04),rgba(255,255,255,.02));border:1px solid rgba(120,140,180,.14);box-shadow:inset 0 1px 0 rgba(255,255,255,.025);}'
		+ '.shpun-field-label{margin-bottom:5px;font-size:11px;font-weight:700;letter-spacing:.03em;color:#90a3c3;}'
		+ '.shpun-field-value{font-size:14px;font-weight:800;line-height:1.4;color:#fff;word-break:break-word;}'
		+ '.shpun-routing-box{padding:13px 14px;border-radius:16px;background:linear-gradient(180deg,rgba(255,255,255,.04),rgba(255,255,255,.02));border:1px solid rgba(120,140,180,.14);box-shadow:inset 0 1px 0 rgba(255,255,255,.025);}'
		+ '.shpun-routing-head{display:flex;justify-content:space-between;align-items:flex-start;gap:12px;margin-bottom:10px;}'
		+ '.shpun-routing-title{font-size:13px;font-weight:800;color:#fff;}'
		+ '.shpun-routing-sub{font-size:11px;line-height:1.45;color:#9fb0c8;}'
		+ '.shpun-routing-meta{font-size:11px;line-height:1.45;color:#b8c3d9;text-align:right;}'
		+ '.shpun-routing-note{margin:0 0 10px;padding:9px 11px;border-radius:10px;background:rgba(59,130,246,.10);border:1px solid rgba(96,165,250,.18);color:#bfdbfe;font-size:11px;line-height:1.45;}'
		+ '.shpun-routing-actions{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:10px;}'
		+ '.shpun-code{font-family:monospace;font-size:18px;font-weight:800;letter-spacing:.06em;color:#fff;}'
		+ '.shpun-code-copy{display:inline-block;cursor:pointer;border-bottom:1px dashed rgba(165,180,252,.55);}'
		+ '.shpun-code-copy:hover{color:#c4b5fd;border-bottom-color:#a78bfa;}'
		+ '.shpun-fw-badge{display:inline-block;margin-left:8px;padding:2px 8px;border-radius:999px;font-size:10px;font-weight:800;color:#bfdbfe;background:rgba(96,165,250,.16);border:1px solid rgba(96,165,250,.22);animation:shpun-fw-pulse 1.8s ease-in-out infinite;}'
		+ '@keyframes shpun-fw-pulse{0%{box-shadow:0 0 0 0 rgba(96,165,250,.35);}70%{box-shadow:0 0 0 8px rgba(96,165,250,0);}100%{box-shadow:0 0 0 0 rgba(96,165,250,0);}}'
		+ '.shpun-actions{margin-top:auto;display:grid;grid-template-columns:repeat(5,minmax(0,1fr));gap:10px;align-items:stretch;}'
		+ '.shpun-col-side{display:flex;flex-direction:column;min-height:100%;}'
		+ '.shpun-side-card{width:100%;height:100%;padding:12px;border-radius:18px;background:linear-gradient(180deg,rgba(255,255,255,.04),rgba(255,255,255,.02));border:1px solid rgba(120,140,180,.14);display:flex;flex-direction:column;align-items:center;justify-content:flex-start;gap:8px;}'
		+ '.shpun-side-title{font-size:13px;font-weight:800;color:#fff;text-align:center;line-height:1.3;}'
		+ '.shpun-side-url{font-size:12px;font-weight:700;color:#c7d2fe;text-align:center;word-break:break-word;line-height:1.35;}'
		+ '.shpun-qr-link{display:inline-flex;margin-top:2px;}'
		+ '.shpun-qr{width:104px;height:auto;display:block;padding:6px;border-radius:14px;background:#fff;border:1px solid rgba(120,140,180,.18);box-shadow:0 8px 20px rgba(0,0,0,.18);}'
		+ '.shpun-qr-caption{font-size:11px;line-height:1.45;color:#9fb0c8;text-align:center;min-height:32px;display:flex;align-items:center;justify-content:center;}'
		+ '.shpun-side-flex-spacer{flex:1 1 auto;width:100%;}'
		+ '.shpun-side-actions{width:100%;display:flex;flex-direction:column;gap:8px;margin-top:auto;}'
		+ '.shpun-btn{min-height:42px;width:100%;padding:8px 12px;border-radius:999px;border:1px solid rgba(120,140,180,.24);background:rgba(14,23,38,.78);color:#e6edf8;font-size:12px;font-weight:800;line-height:1.25;text-decoration:none;display:inline-flex;align-items:center;justify-content:center;gap:6px;cursor:pointer;transition:all .16s ease;text-align:center;white-space:normal;word-break:break-word;overflow-wrap:anywhere;}'
		+ '.shpun-btn:hover{transform:translateY(-1px);background:rgba(25,35,54,.96);border-color:rgba(140,160,200,.34);}'
		+ '.shpun-btn--ghost{background:rgba(255,255,255,.03);}'
		+ '.shpun-btn--primary{background:linear-gradient(135deg,rgba(79,70,229,.90),rgba(99,102,241,.82));border-color:rgba(140,130,255,.28);color:#fff;box-shadow:0 8px 18px rgba(76,70,180,.18);}'
		+ '.shpun-btn--primary:hover{background:linear-gradient(135deg,rgba(88,80,238,.96),rgba(110,114,248,.88));}'
		+ '.shpun-btn--danger{background:rgba(101,24,34,.42);border-color:rgba(248,113,113,.30);color:#fecaca;}'
		+ '.shpun-btn--danger:hover{background:rgba(122,29,42,.50);}'
		+ '.shpun-btn.is-active{background:linear-gradient(135deg,rgba(79,70,229,.90),rgba(99,102,241,.82));border-color:rgba(140,130,255,.28);color:#fff;box-shadow:0 8px 18px rgba(76,70,180,.18);}'
		/* modal custom routes — тёмная тема как у виджета */
		+ '.shpun-modal-wrap{background:linear-gradient(135deg,rgba(6,18,36,.99) 0%,rgba(8,24,50,.99) 50%,rgba(20,19,58,.99) 100%);border-radius:16px;padding:20px;color:#eef2ff;min-width:480px;}'
		+ '.shpun-modal-desc{font-size:12px;color:#9fb0c8;margin-bottom:14px;line-height:1.5;}'
		+ '.shpun-modal-help{margin:-4px 0 14px;padding:9px 11px;border-radius:10px;background:rgba(15,23,42,.50);border:1px solid rgba(120,140,180,.14);color:#b8c3d9;font-size:11px;line-height:1.45;}'
		+ '.shpun-modal-help code{font-family:monospace;color:#e0e7ff;background:rgba(99,102,241,.14);border:1px solid rgba(99,102,241,.18);border-radius:5px;padding:1px 4px;}'
		+ '.shpun-modal-cols{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:14px;margin-bottom:12px;}'
		+ '.shpun-modal-col-label{font-size:11px;font-weight:700;letter-spacing:.03em;margin-bottom:6px;}'
		+ '.shpun-modal-col-label--vpn{color:#a5b4fc;}'
		+ '.shpun-modal-col-label--direct{color:#6ee7b7;}'
		+ '.shpun-modal-list{min-height:60px;max-height:180px;overflow-y:auto;margin-bottom:8px;border:1px solid rgba(120,140,180,.18);border-radius:10px;padding:6px;display:flex;flex-direction:column;gap:4px;background:rgba(8,16,32,.50);}'
		+ '.shpun-modal-empty{font-size:11px;color:#4a5568;font-style:italic;padding:4px;}'
		+ '.shpun-modal-tag{display:flex;align-items:center;justify-content:space-between;padding:4px 8px;border-radius:7px;font-size:12px;font-family:monospace;font-weight:600;}'
		+ '.shpun-modal-tag--vpn{background:rgba(99,102,241,.18);color:#c7d2fe;border:1px solid rgba(99,102,241,.28);}'
		+ '.shpun-modal-tag--direct{background:rgba(16,185,129,.14);color:#a7f3d0;border:1px solid rgba(16,185,129,.24);}'
		+ '.shpun-modal-tag-del{background:none;border:none;cursor:pointer;font-size:14px;opacity:.4;padding:0 2px;line-height:1;color:inherit;}'
		+ '.shpun-modal-tag-del:hover{opacity:1;}'
		+ '.shpun-modal-input-row{display:flex;gap:6px;}'
		+ '.shpun-modal-input{flex:1 1 auto;padding:7px 10px;border:1px solid rgba(120,140,180,.22);border-radius:9px;background:rgba(8,16,32,.60);color:#e2e8f0;font-size:12px;font-family:monospace;outline:none;}'
		+ '.shpun-modal-input:focus{border-color:rgba(140,130,255,.45);background:rgba(12,22,44,.80);}'
		+ '.shpun-modal-input::placeholder{color:#4a5568;}'
		+ '.shpun-server-note{margin:10px 0 12px;padding:10px 12px;border-radius:10px;background:rgba(250,204,21,.10);border:1px solid rgba(250,204,21,.22);color:#fde68a;font-size:12px;line-height:1.45;}'
		+ '.shpun-server-list{max-height:310px;overflow-y:auto;margin-top:10px;border:1px solid rgba(120,140,180,.18);border-radius:12px;padding:6px;background:rgba(8,16,32,.50);display:flex;flex-direction:column;gap:5px;}'
		+ '.shpun-server-row{width:100%;display:grid;grid-template-columns:minmax(0,1fr) auto auto;align-items:center;gap:10px;padding:9px 11px;border:1px solid rgba(120,140,180,.14);border-radius:9px;background:rgba(14,23,38,.72);color:#e6edf8;text-align:left;cursor:pointer;transition:all .14s ease;}'
		+ '.shpun-server-row:hover{background:rgba(25,35,54,.94);border-color:rgba(140,160,200,.30);}'
		+ '.shpun-server-row.is-selected{background:rgba(79,70,229,.24);border-color:rgba(140,130,255,.42);box-shadow:inset 0 1px 0 rgba(255,255,255,.03);}'
		+ '.shpun-server-location{font-size:13px;font-weight:800;color:#f8fafc;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;}'
		+ '.shpun-server-proto{font-size:11px;font-weight:800;color:#c7d2fe;text-transform:uppercase;}'
		+ '.shpun-server-kind{font-size:11px;font-weight:800;padding:3px 8px;border-radius:999px;border:1px solid rgba(120,140,180,.18);white-space:nowrap;}'
		+ '.shpun-server-kind--main{color:#bbf7d0;background:rgba(22,163,74,.14);border-color:rgba(34,197,94,.24);}'
		+ '.shpun-server-kind--reserve{color:#fde68a;background:rgba(250,204,21,.10);border-color:rgba(250,204,21,.22);}'
		+ '.shpun-modal-add-btn{padding:7px 14px;border:1px solid rgba(120,140,180,.24);border-radius:9px;background:rgba(14,23,38,.80);color:#e6edf8;font-size:12px;font-weight:700;cursor:pointer;white-space:nowrap;transition:all .14s ease;}'
		+ '.shpun-modal-add-btn:hover{background:rgba(25,35,54,.96);border-color:rgba(140,160,200,.34);}'
		+ '.shpun-modal-footer{display:flex;justify-content:flex-end;gap:8px;margin-top:14px;border-top:1px solid rgba(120,140,180,.12);padding-top:14px;}'
		+ '.shpun-modal-btn{padding:8px 20px;border-radius:999px;font-size:12px;font-weight:800;cursor:pointer;border:1px solid rgba(120,140,180,.24);background:rgba(14,23,38,.78);color:#e6edf8;transition:all .14s ease;}'
		+ '.shpun-modal-btn:hover{background:rgba(25,35,54,.96);}'
		+ '.shpun-modal-btn--primary{background:linear-gradient(135deg,rgba(79,70,229,.90),rgba(99,102,241,.82));border-color:rgba(140,130,255,.28);color:#fff;}'
		+ '.shpun-modal-btn--primary:hover{background:linear-gradient(135deg,rgba(88,80,238,.96),rgba(110,114,248,.88));}'
		+ '@media(max-width:980px){.shpun-card-main{grid-template-columns:1fr;}.shpun-fields-grid{grid-template-columns:repeat(2,minmax(0,1fr));}.shpun-actions{grid-template-columns:repeat(3,minmax(0,1fr));}.shpun-side-flex-spacer{display:none;}}'
		+ '@media(max-width:640px){.shpun-widget-card{padding:14px;border-radius:18px;}.shpun-title{font-size:18px;}.shpun-fields-grid{grid-template-columns:1fr;}.shpun-routing-actions{grid-template-columns:1fr;}.shpun-actions{grid-template-columns:repeat(2,minmax(0,1fr));}.shpun-modal-cols{grid-template-columns:1fr;}.shpun-btn{font-size:12px;}}';

	var s = document.createElement('style');
	s.id = 'shpun-widget-style';
	s.type = 'text/css';
	s.appendChild(document.createTextNode(css));
	document.head.appendChild(s);
}

/* ============================================================
 *  Helpers
 * ========================================================== */

function normalizeVersionPart(v) {
	var n = parseInt(String(v || '0').replace(/[^0-9].*$/, ''), 10);
	return isNaN(n) ? 0 : n;
}

function compareVersions(a, b) {
	var pa = String(a || '').trim().split('.');
	var pb = String(b || '').trim().split('.');
	var len = Math.max(pa.length, pb.length, 3);
	for (var i = 0; i < len; i++) {
		var av = normalizeVersionPart(pa[i]);
		var bv = normalizeVersionPart(pb[i]);
		if (av < bv) return -1;
		if (av > bv) return 1;
	}
	return 0;
}

function buildStatusBadge(state) {
	var hasCode = !!(state.code && state.code.trim().length > 0);
	var hasSub  = !!state.has_sub;
	var ready   = !!state.vpn_ready;
	var err     = (state.vpn_error || '').trim();
	var cls, text;
	if (err)                              { cls = 'shpun-badge shpun-badge--err';  text = 'Ошибка подключения'; }
	else if (!hasCode)                    { cls = 'shpun-badge shpun-badge--off';  text = 'Подготовка'; }
	else if (hasCode && !hasSub)          { cls = 'shpun-badge shpun-badge--warn'; text = 'Ожидает привязки'; }
	else if (hasCode && hasSub && !ready) { cls = 'shpun-badge shpun-badge--warn'; text = 'Подключаемся'; }
	else if (hasCode && hasSub && ready)  { cls = 'shpun-badge shpun-badge--ok';   text = 'VPN подключен'; }
	else                                  { cls = 'shpun-badge shpun-badge--off';  text = 'Ожидание'; }
	return E('span', { 'class': cls }, [ E('span', { 'class': 'shpun-badge-dot' }), text ]);
}

function makeBadge(cls, text, title) {
	return E('span', { 'class': 'shpun-badge ' + cls, 'title': title || text }, [
		E('span', { 'class': 'shpun-badge-dot' }),
		E('span', { 'class': 'shpun-badge-text' }, text)
	]);
}

function buildServerBadges(server) {
	if (!server)
		return [];

	var proto = String(server.proto || '').toLowerCase();
	var protoLabel = proto === 'vless' ? 'VLESS' : (proto === 'ss' ? 'SS' : proto.toUpperCase());
	var location = formatServerLocation(server.name || server.host || 'Server', protoLabel);
	var exitPing = parseInt(server.exit_ping_ms, 10);
	var serverText = location + (protoLabel ? ' - ' + protoLabel : '');
	if (!isNaN(exitPing) && exitPing >= 0)
		serverText += ' · ' + exitPing + ' ms';
	var badges = [
		makeBadge('shpun-badge--server', serverText)
	];

	if (server.exit_ip)
		badges.push(makeBadge('shpun-badge--exit', 'Внешний IP ' + server.exit_ip, 'IP-адрес VPN, который видят сайты и сервисы в интернете.'));

	if (!isNaN(exitPing) && exitPing >= 0)
		badges.push(makeBadge('shpun-badge--check', 'Сервер ' + exitPing + ' ms', 'Время отклика от роутера до выбранного VPN-сервера. Измеряется по внешнему IP, с которым VPN выходит в интернет.'));

	return badges;
}

function getRoutingModeLabel(mode) {
	if (String(mode || 'full').trim() === 'smart_ru')
		return 'Популярные РФ сервисы напрямую';
	return String(mode || 'full').trim() === 'split_ru'
		? 'РФ сайты напрямую, звонки через VPN'
		: 'Весь трафик через VPN';
}

function getRoutingModeDescription(mode) {
	mode = String(mode || 'full').trim();
	if (mode === 'smart_ru')
		return 'Основной рекомендуемый режим: весь трафик идет через VPN, а популярные российские сервисы открываются напрямую.';
	if (mode === 'split_ru')
		return 'Тяжелый режим: российский веб-трафик идет напрямую, а UDP-звонки остаются через VPN для стабильной связи. Используйте только на мощных роутерах.';
	return 'Максимальная приватность: весь клиентский трафик идет через VPN. Российские сервисы тоже будут открываться через туннель.';
}

function validateIpCidr(entry) {
	entry = entry.trim();
	if (!entry) return false;
	var ip, prefix, slashIdx = entry.indexOf('/');
	if (slashIdx >= 0) {
		ip = entry.slice(0, slashIdx);
		prefix = parseInt(entry.slice(slashIdx + 1), 10);
		if (isNaN(prefix) || prefix < 0 || prefix > 32) return false;
	} else {
		ip = entry;
	}
	var parts = ip.split('.');
	if (parts.length !== 4) return false;
	for (var i = 0; i < 4; i++) {
		var octet = parseInt(parts[i], 10);
		if (isNaN(octet) || octet < 0 || octet > 255) return false;
		if (String(octet) !== parts[i]) return false;
	}
	return true;
}

function normalizeRouteEntry(entry) {
	entry = String(entry || '').trim();
	if (!entry) return '';

	if (entry.indexOf('://') >= 0) {
		entry = entry.replace(/^[a-z][a-z0-9+.-]*:\/\//i, '');
		entry = entry.split('/')[0].split('?')[0].split('#')[0];
	}

	return entry.replace(/\s+/g, '').toLowerCase();
}

function validateDomainEntry(entry) {
	entry = normalizeRouteEntry(entry);
	if (!entry || entry.length > 253) return false;
	if (entry.indexOf('/') >= 0 || entry.indexOf(':') >= 0) return false;
	if (entry.indexOf('..') >= 0) return false;

	if (entry.indexOf('*.') === 0)
		entry = entry.slice(2);

	if (entry.indexOf('*') >= 0) return false;
	if (entry[0] === '.' || entry[entry.length - 1] === '.') return false;
	if (entry.indexOf('.') < 0) return false;

	var labels = entry.split('.');
	for (var i = 0; i < labels.length; i++) {
		var label = labels[i];
		if (!label || label.length > 63) return false;
		if (label[0] === '-' || label[label.length - 1] === '-') return false;
		if (!/^[a-z0-9-]+$/.test(label)) return false;
	}

	return true;
}

function validateRouteEntry(entry) {
	entry = normalizeRouteEntry(entry);
	return validateIpCidr(entry) || validateDomainEntry(entry);
}

function formatServerLocation(name, protoLabel) {
	name = String(name || '').replace(/\+/g, ' ');
	try { name = decodeURIComponent(name); } catch(e) {}
	name = name.replace(/\s+/g, ' ').trim();

	if (protoLabel)
		name = name.replace(new RegExp('\\s*' + protoLabel + '\\s*$', 'i'), '');

	name = name.replace(/\s*(VLESS|Shadowsocks|SS)\s*$/i, '').trim();
	name = name.replace(/[-–—]\s*$/g, '').trim();

	return name || 'Server';
}

/* ============================================================
 *  Custom routes modal
 *  Живёт вне #view — LuCI его не трогает никогда
 * ========================================================== */

function openCustomRoutesModal() {
	/* Показываем спиннер пока грузим */
	ui.showModal('Дополнительные маршруты', [
		E('p', {}, 'Загружаем маршруты…')
	]);

	callShpunCustomRoutesGet().then(function(res) {
		res = res || {};
		var vpnList    = (res.vpn    || []).slice();
		var directList = (res.direct || []).slice();

		function renderList(wrap, list, cls) {
			while (wrap.firstChild) wrap.removeChild(wrap.firstChild);
			if (!list.length) {
				wrap.appendChild(E('div', { 'class': 'shpun-modal-empty' }, 'Пусто'));
				return;
			}
			list.forEach(function(entry, idx) {
				var del = E('button', { 'type': 'button', 'class': 'shpun-modal-tag-del', 'title': 'Удалить' }, '×');
				del.addEventListener('click', function(ev) {
					ev.preventDefault();
					list.splice(idx, 1);
					renderList(wrap, list, cls);
				});
				wrap.appendChild(E('div', { 'class': 'shpun-modal-tag shpun-modal-tag--' + cls }, [
					E('span', {}, entry),
					del
				]));
			});
		}

		function buildCol(cls, label, list) {
			var wrap = E('div', { 'class': 'shpun-modal-list' });
			renderList(wrap, list, cls);

			var input = E('input', {
				'class': 'shpun-modal-input',
				'type': 'text',
				'placeholder': 'site.ru, *.site.ru или 10.0.0.0/8',
				'autocomplete': 'off',
				'spellcheck': 'false'
			});

			var addBtn = E('button', { 'type': 'button', 'class': 'shpun-modal-add-btn' }, 'Добавить');

			addBtn.addEventListener('click', function(ev) {
				ev.preventDefault();
				var val = normalizeRouteEntry(input.value);
				if (!val) return;
				if (!validateRouteEntry(val)) {
					ui.addNotification(null, E('p', {}, 'Неверный формат: ' + val + '. Можно добавить IPv4, CIDR, домен или *.домен.'), 'error');
					return;
				}
				if (vpnList.indexOf(val) >= 0 || directList.indexOf(val) >= 0) {
					ui.addNotification(null, E('p', {}, 'Маршрут ' + val + ' уже добавлен.'), 'warning');
					return;
				}
				list.push(val);
				input.value = '';
				renderList(wrap, list, cls);
			});

			input.addEventListener('keydown', function(ev) {
				if (ev.key === 'Enter') { ev.preventDefault(); addBtn.click(); }
			});

			return E('div', {}, [
				E('div', { 'class': 'shpun-modal-col-label shpun-modal-col-label--' + cls }, label),
				wrap,
				E('div', { 'class': 'shpun-modal-input-row' }, [ input, addBtn ])
			]);
		}

		ui.showModal('Дополнительные маршруты', [
			E('div', { 'class': 'shpun-modal-wrap' }, [
				E('div', { 'class': 'shpun-modal-desc' },
					'Можно добавить IPv4, CIDR или домен целиком: site.ru, *.site.ru. Работает поверх выбранного режима маршрутизации.'),
				E('div', { 'class': 'shpun-modal-help' }, [
					'Форматы: ',
					E('code', {}, 'site.ru'),
					' домен целиком, ',
					E('code', {}, '*.site.ru'),
					' домен и поддомены, ',
					E('code', {}, '1.2.3.4'),
					' IP, ',
					E('code', {}, '10.0.0.0/8'),
					' сеть. Для UDP-звонков и игр надежнее указывать IP или CIDR.'
				]),
				E('div', { 'class': 'shpun-modal-cols' }, [
					buildCol('vpn',    'Принудительно через VPN', vpnList),
					buildCol('direct', 'Принудительно напрямую',  directList)
				]),
				E('div', { 'class': 'shpun-modal-footer' }, [
					E('button', {
						'type': 'button',
						'class': 'shpun-modal-btn',
						'click': function() { ui.hideModal(); }
					}, 'Отмена'),
					E('button', {
						'type': 'button',
						'class': 'shpun-modal-btn shpun-modal-btn--primary',
						'click': function() {
							callShpunCustomRoutesSet(vpnList.slice(), directList.slice()).then(function(res) {
								res = res || {};
								ui.hideModal();
								if (res.ok) {
									ui.addNotification(null, E('p', {}, 'Маршруты сохранены: ' + res.vpn_count + ' через VPN, ' + res.direct_count + ' напрямую.'), 'info');
									if (!res.applied && !res.unchanged)
										ui.addNotification(null, E('p', {}, 'Правила будут применены автоматически, когда VPN-туннель и его маршрутизация будут активны.'), 'warning');
									if (res.pending_rebuild)
										ui.addNotification(null, E('p', {}, 'Доменные маршруты сохранены без разрыва соединения и будут полностью применены при следующем безопасном переподключении VPN.'), 'warning');
								} else
									ui.addNotification(null, E('p', {}, 'Ошибка: ' + (res.error || 'неизвестная ошибка')), 'error');
							}).catch(function(err) {
								ui.hideModal();
								ui.addNotification(null, E('p', {}, 'Ошибка сохранения: ' + String(err)), 'error');
							});
						}
					}, 'Сохранить')
				])
			])
		]);
	}).catch(function(err) {
		ui.showModal('Дополнительные маршруты', [
			E('div', { 'class': 'shpun-modal-wrap' }, [
				E('p', { 'style': 'color:#fecaca;' }, 'Не удалось загрузить маршруты: ' + String(err)),
				E('div', { 'class': 'shpun-modal-footer' }, [
					E('button', { 'type': 'button', 'class': 'shpun-modal-btn', 'click': function() { ui.hideModal(); } }, 'Закрыть')
				])
			])
		]);
	});
}

function openServersModal() {
	ui.showModal('Серверы VPN', [
		E('div', { 'class': 'shpun-modal-wrap' }, [
			E('div', { 'class': 'shpun-modal-desc' }, 'Загружаем список серверов...')
		])
	]);

	callShpunServersGet().then(function(res) {
		res = res || {};
		var servers = res.servers || [];
		var selected = res.selected || 0;

		if (!res.ok) {
			ui.showModal('Серверы VPN', [
				E('div', { 'class': 'shpun-modal-wrap' }, [
					E('p', { 'style': 'color:#fecaca;' }, 'Не удалось загрузить список серверов: ' + (res.error || 'ошибка')),
					E('div', { 'class': 'shpun-modal-footer' }, [
						E('button', { 'type': 'button', 'class': 'shpun-modal-btn', 'click': function() { ui.hideModal(); } }, 'Закрыть')
					])
				])
			]);
			return;
		}

		if (!servers.length) {
			ui.showModal('Серверы VPN', [
				E('div', { 'class': 'shpun-modal-wrap' }, [
					E('div', { 'class': 'shpun-modal-desc' }, 'Список серверов пока недоступен. Дождитесь получения подписки.'),
					E('div', { 'class': 'shpun-modal-footer' }, [
						E('button', { 'type': 'button', 'class': 'shpun-modal-btn', 'click': function() { ui.hideModal(); } }, 'Закрыть')
					])
				])
			]);
			return;
		}

		var chosen = selected;
		var list = E('div', { 'class': 'shpun-server-list' });
		var rows = [];

		function markSelected() {
			rows.forEach(function(row) {
				row.node.className = 'shpun-server-row' + (row.index === chosen ? ' is-selected' : '');
			});
		}

		servers.forEach(function(s) {
			var proto = String(s.proto || 'vpn').toLowerCase();
			var protoLabel = proto === 'vless' ? 'VLESS' : (proto === 'ss' ? 'Shadowsocks' : proto.toUpperCase());
			var isMain = proto === 'vless';
			var location = formatServerLocation(s.name || ('Server ' + s.index), protoLabel);
			var row = E('button', {
				'type': 'button',
				'class': 'shpun-server-row' + (s.index === selected ? ' is-selected' : ''),
				'click': function(ev) {
					ev.preventDefault();
					chosen = s.index;
					markSelected();
				}
			}, [
				E('span', { 'class': 'shpun-server-location', 'title': location }, location),
				E('span', { 'class': 'shpun-server-proto' }, protoLabel),
				E('span', { 'class': 'shpun-server-kind ' + (isMain ? 'shpun-server-kind--main' : 'shpun-server-kind--reserve') }, isMain ? 'Рекомендуем' : 'Резерв')
			]);
			rows.push({ index: s.index, node: row });
			list.appendChild(row);
		});

		ui.showModal('Серверы VPN', [
			E('div', { 'class': 'shpun-modal-wrap' }, [
				E('div', { 'class': 'shpun-modal-desc' }, 'Выберите сервер. VPN будет перезапущен с новым профилем.'),
				E('div', { 'class': 'shpun-server-note' }, 'Используйте VLESS как основной вариант. Shadowsocks оставлен как резервный режим и может быть менее стабильным.'),
				list,
				E('div', { 'class': 'shpun-modal-footer' }, [
					E('button', { 'type': 'button', 'class': 'shpun-modal-btn', 'click': function() { ui.hideModal(); } }, 'Отмена'),
					E('button', {
						'type': 'button',
						'class': 'shpun-modal-btn shpun-modal-btn--primary',
						'click': function() {
							ui.hideModal();
							ui.addNotification(null, E('p', {}, 'Переключаем сервер...'), 'info');
							callShpunServerSet(chosen).then(function(r) {
								r = r || {};
								if (r.ok)
									ui.addNotification(null, E('p', {}, 'Сервер выбран. VPN перезапускается.'), 'info');
								else
									ui.addNotification(null, E('p', {}, 'Не удалось выбрать сервер: ' + (r.error || 'ошибка')), 'error');
							}).catch(function(err) {
								ui.addNotification(null, E('p', {}, 'Ошибка: ' + String(err)), 'error');
							});
						}
					}, 'Применить')
				])
			])
		]);
	}).catch(function(err) {
		ui.showModal('Серверы VPN', [
			E('div', { 'class': 'shpun-modal-wrap' }, [
				E('p', { 'style': 'color:#fecaca;' }, 'Не удалось загрузить список серверов: ' + String(err)),
				E('div', { 'class': 'shpun-modal-footer' }, [
					E('button', { 'type': 'button', 'class': 'shpun-modal-btn', 'click': function() { ui.hideModal(); } }, 'Закрыть')
				])
			])
		]);
	});
}

/* ============================================================
 *  View
 * ========================================================== */

return view.extend({

	load: function() {
		injectStyles();
		return Promise.all([
			callShpunState(),
			callShpunRoutingGet()
		]).then(function(res) {
			var st = res[0] || {};
			st.routing = res[1] || {};
			return st;
		});
	},

	render: function(state) {
		state = state || {};
		this._state = state;
		var view = this;

		var code     = (state.code || '').trim();
		var hasSub   = !!state.has_sub;
		var vpnReady = !!state.vpn_ready;
		var err      = (state.vpn_error || '').trim();

		var routing       = state.routing || {};
		var routingMode   = String(routing.mode || 'full').trim();
		var routingLabel  = getRoutingModeLabel(routingMode);
		var routingDesc   = getRoutingModeDescription(routingMode);
		var routesVersion = String(routing.routes_version || '0').trim();
		var routesCount   = routing.routes_count || 0;

		var fwCurrentRaw     = (state.fw_current || '').trim();
		var fwCurrentDisplay = fwCurrentRaw || '—';
		var fwLatest         = (state.fw_latest || '').trim();
		var hasNewFw = !!(fwLatest && fwCurrentRaw && compareVersions(fwCurrentRaw, fwLatest) < 0);

		var appLink = 'https://app.sdnonline.online';
		var botLink = 'https://t.me/shpunvpn_bot';
		var qrUrl   = 'https://api.qrserver.com/v1/create-qr-code/?size=180x180&data=' + encodeURIComponent(appLink);

		var codeNode = E('span', {
			'class': code ? 'shpun-code shpun-code-copy' : 'shpun-code',
			'click': code ? ui.createHandlerFn(this, 'handleCopyCode', code) : null
		}, code || '— — — —');

		var fwValue = hasNewFw
			? E('span', {}, [ fwCurrentDisplay, E('span', { 'class': 'shpun-fw-badge' }, 'доступна ' + fwLatest) ])
			: fwCurrentDisplay;

		var hintText =
			!code     ? 'Роутер готовится к привязке. После генерации кода откройте ShpunApp и оформите услугу для роутера.'
			: !hasSub ? 'Откройте ShpunApp, закажите или активируйте услугу и привяжите роутер по этому коду.'
			: !vpnReady ? (err ? 'Ошибка: ' + err : 'Привязка найдена. Роутер поднимает VPN…')
			: 'Роутер подключен. Серверы, маршруты и обновления доступны прямо в этом виджете.';

		var statusTopBadges = [ buildStatusBadge(state) ];
		var statusMetricBadges = [];
		var serverBadges = buildServerBadges(state.current_server);
		if (serverBadges.length > 0)
			statusTopBadges.push(serverBadges[0]);
		for (var i = 1; i < serverBadges.length; i++)
			statusMetricBadges.push(serverBadges[i]);
		if (vpnReady)
			statusMetricBadges.push(makeBadge(
				state.udp_ready ? 'shpun-badge--ok' : 'shpun-badge--warn',
				state.udp_ready ? 'UDP через VPN: включен' : 'UDP через VPN: недоступен',
				state.udp_ready ? 'UDP-трафик направляется через VPN.' : 'Роутер работает без UDP-туннеля; звонки и игры могут работать нестабильно.'
			));
		var statusRows = [
			E('div', { 'class': 'shpun-status-row shpun-status-row--top' }, statusTopBadges)
		];
		if (statusMetricBadges.length)
			statusRows.push(E('div', { 'class': 'shpun-status-row shpun-status-row--metrics' }, statusMetricBadges));

		return E('div', { 'class': 'shpun-widget-card' }, [
			E('div', { 'class': 'shpun-widget-inner' }, [

				E('div', { 'class': 'shpun-widget-header' }, [
					E('div', { 'class': 'shpun-title-wrap' }, [
						E('div', { 'class': 'shpun-kicker' }, [ E('span', { 'class': 'shpun-kicker-dot' }), 'Shpun Router' ]),
						E('div', { 'class': 'shpun-title' }, 'SDN System'),
						E('div', { 'class': 'shpun-subtitle' }, code
							? 'Статус, серверы, маршруты и обновления'
							: 'Подготовка роутера к привязке через ShpunApp')
					]),
					E('div', { 'class': 'shpun-status-group' }, statusRows)
				]),

				E('div', { 'class': 'shpun-hint-box' }, hintText),

				E('div', { 'class': 'shpun-card-main' }, [
					E('div', { 'class': 'shpun-col-main' }, [

						E('div', { 'class': 'shpun-fields-grid' }, [
							E('div', { 'class': 'shpun-field' }, [
								E('div', { 'class': 'shpun-field-label' }, 'Код роутера'),
								E('div', { 'class': 'shpun-field-value' }, [ codeNode ])
							]),
							E('div', { 'class': 'shpun-field' }, [
								E('div', { 'class': 'shpun-field-label' }, 'Статус услуги'),
								E('div', { 'class': 'shpun-field-value' }, [
									!code ? 'Ожидает генерации кода'
									: !hasSub ? 'Ожидает привязки'
									: vpnReady ? 'Подключен'
									: err ? 'Ошибка подключения' : 'Подключение…'
								])
							]),
							E('div', { 'class': 'shpun-field' }, [
								E('div', { 'class': 'shpun-field-label' }, 'Прошивка'),
								E('div', { 'class': 'shpun-field-value' }, [ fwValue ])
							])
						]),

						E('div', { 'class': 'shpun-routing-box' }, [
							E('div', { 'class': 'shpun-routing-head' }, [
								E('div', {}, [
									E('div', { 'class': 'shpun-routing-title' }, 'Маршрутизация')
								]),
								E('div', { 'class': 'shpun-routing-meta' }, [
									E('div', {}, 'Режим: ' + routingLabel),
									E('div', {}, 'Маршруты: v' + routesVersion + ' · ' + routesCount + ' CIDR')
								])
							]),
							E('div', { 'class': 'shpun-routing-note' }, [
								E('strong', {}, 'Текущий режим: '),
								routingDesc
							]),
							E('div', { 'class': 'shpun-routing-actions' }, [
								E('button', {
									'class': 'shpun-btn ' + (routingMode === 'full' ? 'shpun-btn--primary is-active' : 'shpun-btn--ghost'),
									'click': function(ev) { return view.handleSetRoutingMode(ev, 'full'); }
								}, 'Весь трафик через VPN'),
								E('button', {
									'class': 'shpun-btn ' + (routingMode === 'smart_ru' ? 'shpun-btn--primary is-active' : 'shpun-btn--ghost'),
									'click': function(ev) { return view.handleSetRoutingMode(ev, 'smart_ru'); }
								}, 'Популярные РФ сервисы напрямую'),
								E('button', {
									'class': 'shpun-btn ' + (routingMode === 'split_ru' ? 'shpun-btn--primary is-active' : 'shpun-btn--ghost'),
									'click': function(ev) { return view.handleSetRoutingMode(ev, 'split_ru'); }
								}, 'РФ сайты напрямую')
							])
						]),

						E('div', { 'class': 'shpun-actions' }, [
							E('button', { 'class': 'shpun-btn shpun-btn--ghost',   'click': ui.createHandlerFn(this, 'handleRefresh') }, 'Обновить статус'),
							E('button', { 'class': 'shpun-btn shpun-btn--ghost',   'click': ui.createHandlerFn(this, 'handleServers') }, 'Серверы'),
							E('button', { 'class': 'shpun-btn shpun-btn--ghost',   'click': ui.createHandlerFn(this, 'handleCustomRoutes') }, 'Доп. маршруты'),
							E('button', { 'class': 'shpun-btn shpun-btn--ghost',   'click': ui.createHandlerFn(this, 'handleUpdateFirmware') }, hasNewFw ? ('Установить ' + fwLatest) : 'Проверить обновление'),
							E('button', { 'class': 'shpun-btn shpun-btn--danger',  'click': ui.createHandlerFn(this, 'handleResetVpn') }, 'Сбросить конфиг')
						])
					]),

					E('div', { 'class': 'shpun-col-side' }, [
						E('div', { 'class': 'shpun-side-card' }, [
							E('div', { 'class': 'shpun-side-title' }, 'Привязка через ShpunApp'),
							E('div', { 'class': 'shpun-side-url' }, 'app.sdnonline.online'),
							E('a', { 'class': 'shpun-qr-link', 'href': appLink, 'target': '_blank', 'rel': 'noreferrer' }, [
								E('img', { 'class': 'shpun-qr', 'src': qrUrl, 'alt': 'QR' })
							]),
							E('div', { 'class': 'shpun-qr-caption' }, 'Откройте ShpunApp для привязки и управления роутером'),
							E('div', { 'class': 'shpun-side-flex-spacer' }),
							E('div', { 'class': 'shpun-side-actions' }, [
								E('a', { 'class': 'shpun-btn shpun-btn--primary', 'href': appLink, 'target': '_blank', 'rel': 'noreferrer' }, 'Привязать в ShpunApp'),
								E('a', { 'class': 'shpun-btn shpun-btn--ghost',   'href': botLink, 'target': '_blank', 'rel': 'noreferrer' }, 'Бот поддержки')
							])
						])
					])
				])
			])
		]);
	},

	handleCopyCode: function(ev, code) {
		if (ev) { ev.preventDefault(); ev.stopPropagation(); }
		if (!code) return;
		var text = String(code).trim();
		var ok  = function() { ui.addNotification(null, E('p', {}, 'Код роутера скопирован.'), 'info'); };
		var err = function(e) { ui.addNotification(null, E('p', {}, 'Не удалось скопировать: ' + e), 'error'); };
		try {
			if (navigator.clipboard && navigator.clipboard.writeText) navigator.clipboard.writeText(text).then(ok).catch(err);
			else {
				var i = document.createElement('input'); i.type = 'text'; i.value = text;
				document.body.appendChild(i); i.select();
				try { document.execCommand('copy'); ok(); } catch(e) { err(e); }
				document.body.removeChild(i);
			}
		} catch(e) { err(e); }
	},

	handleRefresh: function(ev) {
		if (ev) ev.preventDefault();
		var view = this;
		return Promise.all([ callShpunState(), callShpunRoutingGet() ]).then(function(data) {
			var st = data[0] || {};
			st.routing = data[1] || {};
			view._state = st;
		}).catch(function(err) {
			ui.addNotification(null, E('p', {}, 'Не удалось обновить статус: ' + String(err)), 'error');
		});
	},

	handleCustomRoutes: function(ev) {
		if (ev) ev.preventDefault();
		openCustomRoutesModal();
	},

	handleServers: function(ev) {
		if (ev) ev.preventDefault();
		openServersModal();
	},

	handleSetRoutingMode: function(ev, mode) {
		if (ev) { ev.preventDefault(); ev.stopPropagation(); }
		var targetMode = String(mode || '').trim();
		if (targetMode !== 'full' && targetMode !== 'smart_ru' && targetMode !== 'split_ru') return;

		var view = this;

		// При переключении на split_ru проверяем — скачаны ли маршруты
		if (targetMode === 'split_ru') {
			var routing = (view._state && view._state.routing) || {};
			var hasRoutes = !!(routing.has_routes) || (routing.routes_count > 0);

			if (!hasRoutes) {
				// Маршруты не скачаны — предупреждаем пользователя
				ui.showModal('Переключение режима маршрутизации', [
					E('p', {}, [
						E('strong', {}, 'Внимание: '),
						'Список российских адресов ещё не загружен.'
					]),
					E('p', {}, 'После переключения роутер автоматически скачает маршруты (~8000 адресов) и применит их. На медленных роутерах (MIPS) это может занять несколько минут — в это время нагрузка на процессор будет высокой.'),
					E('p', {}, 'Интернет продолжит работать через туннель, пока маршруты применяются.'),
					E('div', { 'style': 'margin-top:10px;text-align:right' }, [
						E('button', {
							'class': 'btn',
							'click': function() { ui.hideModal(); }
						}, 'Отмена'),
						E('button', {
							'class': 'btn cbi-button cbi-button-apply',
							'style': 'margin-left:8px',
							'click': function() {
								ui.hideModal();
								view._applyRoutingMode(targetMode);
							}
						}, 'Всё равно переключить')
					])
				]);
				return;
			}
		}

		view._applyRoutingMode(targetMode);
	},

	_applyRoutingMode: function(targetMode) {
		ui.addNotification(null, E('p', {}, 'Применяем режим маршрутизации…'), 'info');

		var view = this;
		var setResult = null;

		return Promise.resolve()
			.then(function() { return callShpunRoutingSet(targetMode); })
			.then(function(res) {
				setResult = res || {};
				var out = String(setResult.output || setResult.error || '');
				if (out.indexOf('weak_router') >= 0) {
					ui.addNotification(null, E('p', {}, 'Роутер слишком слабый для полного режима РФ-маршрутизации. Применение большого списка маршрутов отключено для защиты устройства.'), 'warning');
					return Promise.reject('weak_router');
				}
				if (out.indexOf('smart_ru_not_ready') >= 0) {
					ui.addNotification(null, E('p', {}, 'Не удалось скачать список российских сервисов. Проверьте подключение и попробуйте снова.'), 'warning');
					return Promise.reject('smart_ru_not_ready');
				}
				return setResult;
			})
			.catch(function(err) {
				if (err === 'weak_router') return Promise.reject(err);
				if (err === 'smart_ru_not_ready') return Promise.reject(err);
				return null;
			})
			.then(function() { return new Promise(function(r) { window.setTimeout(r, 1500); }); })
			.then(function() {
				return Promise.all([ callShpunState(), callShpunRoutingGet() ]).then(function(data) {
					var actual = String(((data[1] || {}).mode) || '').trim();
					if (actual === targetMode)
						ui.addNotification(null, E('p', {}, 'Режим маршрутизации обновлён.'), 'info');
					else
						ui.addNotification(null, E('p', {}, 'Не удалось применить режим.'), 'error');
				});
			})
			.catch(function(err) {
				if (err !== 'weak_router' && err !== 'smart_ru_not_ready')
					ui.addNotification(null, E('p', {}, 'Не удалось применить режим.'), 'error');
			});
	},

	handleUpdateFirmware: function(ev) {
		if (ev) ev.preventDefault();
		var view = this;
		var st = view._state || {};
		var fwCurrentRaw = (st.fw_current || '').trim();
		var fwLatest     = (st.fw_latest  || '').trim();
		var hasNew = !!(fwLatest && fwCurrentRaw && compareVersions(fwCurrentRaw, fwLatest) < 0);

		if (hasNew) {
			ui.showModal('Обновление прошивки', [
				E('p', {}, [ 'Доступна новая версия: ', E('strong', {}, fwCurrentRaw || '—'), ' → ', E('strong', {}, fwLatest), '.' ]),
				E('p', {}, 'Установить? VPN-соединение будет перезапущено.'),
				E('div', { 'style': 'margin-top:10px;text-align:right' }, [
					E('button', { 'class': 'btn', 'click': function() { ui.hideModal(); } }, 'Отмена'),
					E('button', {
						'class': 'btn cbi-button cbi-button-apply', 'style': 'margin-left:8px',
						'click': function() {
							ui.hideModal();
							ui.addNotification(null, E('p', {}, 'Установка обновления запущена.'), 'info');
							callShpunOtaInstall().catch(function(err) {
								ui.addNotification(null, E('p', {}, 'Ошибка: ' + String(err)), 'error');
							});
						}
					}, 'Установить ' + fwLatest)
				])
			]);
			return;
		}

		ui.addNotification(null, E('p', {}, 'Проверка обновлений запущена.'), 'info');
		callShpunOtaCheck().catch(function(err) {
			ui.addNotification(null, E('p', {}, 'Ошибка проверки: ' + String(err)), 'error');
		});
	},

	handleRefreshConnection: function(ev) {
		if (ev) ev.preventDefault();
		var st = this._state || {};
		var code = (st.code || '').trim();
		if (!code) { ui.addNotification(null, E('p', {}, 'Сначала дождитесь генерации кода.'), 'warning'); return; }

		ui.showModal('Обновить подключение', [
			E('p', {}, 'Роутер заново получит конфигурацию и пересоберёт подключение.'),
			E('div', { 'style': 'margin-top:10px;text-align:right' }, [
				E('button', { 'class': 'btn', 'click': function() { ui.hideModal(); } }, 'Отмена'),
				E('button', {
					'class': 'btn cbi-button cbi-button-apply', 'style': 'margin-left:8px',
					'click': function() {
						ui.hideModal();
						ui.addNotification(null, E('p', {}, 'Обновление подключения запущено.'), 'info');
						callShpunRefreshConnection().then(function(res) {
							res = res || {};
							if (!res.ok) ui.addNotification(null, E('p', {}, 'Не удалось запустить: ' + (res.error || 'ошибка')), 'error');
						}).catch(function(err) {
							ui.addNotification(null, E('p', {}, 'Ошибка: ' + String(err)), 'error');
						});
					}
				}, 'Обновить подключение')
			])
		]);
	},

	handleResetVpn: function(ev) {
		if (ev) ev.preventDefault();
		ui.showModal('Сброс конфигурации', [
			E('p', {}, 'Полный сброс. Новый код, привязка и конфигурация VPN будут потеряны.'),
			E('div', { 'style': 'margin-top:10px;text-align:right' }, [
				E('button', { 'class': 'btn', 'click': function() { ui.hideModal(); } }, 'Отмена'),
				E('button', {
					'class': 'btn cbi-button cbi-button-negative', 'style': 'margin-left:8px',
					'click': function() {
						ui.hideModal();
						callShpunResetVpn().then(function(res) {
							res = res || {};
							if (res.ok) ui.addNotification(null, E('p', {}, 'Конфигурация сброшена.'), 'info');
							else ui.addNotification(null, E('p', {}, 'Не удалось сбросить: ' + (res.error || 'ошибка')), 'error');
						}).catch(function(err) {
							ui.addNotification(null, E('p', {}, 'Ошибка: ' + String(err)), 'error');
						});
					}
				}, 'Сбросить конфиг')
			])
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null,

	onmount: function(node) {
		this.container = node;
	},

	onunload: function() {}
});
