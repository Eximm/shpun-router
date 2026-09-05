'use strict';
'require view';
'require rpc';
'require ui';
'require poll';

/* OpenWrt 25.12 may ship status widgets which use String.format() without
 * loading the legacy cbi.js helper. Keep the stock widgets working, but do
 * not load cbi.js as a LuCI module (it is not a module factory). */
if (typeof String.prototype.format !== 'function') {
	String.prototype.format = function() {
		var htmlEsc = [/&/g, '&#38;', /"/g, '&#34;', /'/g, '&#39;', /</g, '&#60;', />/g, '&#62;'];
		var quotEsc = [/"/g, '&#34;', /'/g, '&#39;'];

		function esc(value, replacements) {
			if (value == null || typeof value === 'object' || typeof value === 'function')
				return '';
			value = String(value);
			for (var i = 0; i < replacements.length; i += 2)
				value = value.replace(replacements[i], replacements[i + 1]);
			return value;
		}

		var str = this;
		var out = '';
		var index = 0;
		var match;
		var re = /^(([^%]*)%('.|0|\x20)?(-)?(\d+)?(\.\d+)?(%|b|c|d|u|f|o|s|x|X|q|h|j|t|m))/;

		while ((match = re.exec(str)) !== null) {
			var whole = match[1];
			var left = match[2];
			var pad = match[3] ? (match[3].charAt(0) === "'" ? match[3].charAt(1) : match[3]) : ' ';
			var justify = match[4];
			var minLength = match[5] ? Number(match[5]) : 0;
			var precision = match[6] ? Number(match[6].substring(1)) : -1;
			var type = match[7];
			var value;

			if (type === '%') {
				value = '%';
			} else if (index < arguments.length) {
				var param = arguments[index++];
				switch (type) {
				case 'b': value = Math.floor(+param || 0).toString(2); break;
				case 'c': value = String.fromCharCode(+param || 0); break;
				case 'd': value = Math.floor(+param || 0).toFixed(0); break;
				case 'u': var n = +param || 0; value = Math.floor(n < 0 ? 0x100000000 + n : n).toFixed(0); break;
				case 'f': value = precision > -1 ? (+param || 0).toFixed(precision) : (+param || 0); break;
				case 'o': value = Math.floor(+param || 0).toString(8); break;
				case 's': value = param; break;
				case 'x': value = Math.floor(+param || 0).toString(16).toLowerCase(); break;
				case 'X': value = Math.floor(+param || 0).toString(16).toUpperCase(); break;
				case 'h': value = esc(param, htmlEsc); break;
				case 'q': value = esc(param, quotEsc); break;
				case 'j': try { value = JSON.stringify(param); } catch (e) { value = ''; } break;
				case 'm':
					var base = minLength || 1000;
					var digits = match[6] ? ~~(10 * +('0' + match[6])) : 2;
					var units = [' ', ' K', ' M', ' G', ' T', ' P', ' E'];
					var unit = 0;
					var scaled = +param || 0;
					while (unit < units.length && scaled > base) { scaled /= base; unit++; }
					value = unit ? scaled.toFixed(digits) + units[unit] + (base === 1024 ? 'i' : '') : scaled + ' ';
					minLength = 0;
					break;
				default: value = param;
				}
			}

			value = String(value == null ? '' : value);
			while (value.length < minLength)
				value = justify === '-' ? value + pad : pad + value;
			out += left + value;
			str = str.substring(whole.length);
		}

		return out + str;
	};

	String.format = function() {
		return String.prototype.format.apply(arguments[0], Array.prototype.slice.call(arguments, 1));
	};
}

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
var callShpunServerAutoStart = rpc.declare({
	object: 'shpun', method: 'server_auto_start', params: ['candidates'], expect: { '': {} }
});
var callShpunServerAutoStatus = rpc.declare({
	object: 'shpun', method: 'server_auto_status', expect: { '': {} }
});
var callShpunServerAutoSet = rpc.declare({
	object: 'shpun', method: 'server_auto_set', params: ['enabled'], expect: { '': {} }
});
var callShpunServerAutoExcludeRuSet = rpc.declare({
	object: 'shpun', method: 'server_auto_exclude_ru_set', params: ['enabled'], expect: { '': {} }
});

function waitForRoutingMode(targetMode, timeoutMs) {
	var started = Date.now();

	function retry() {
		return new Promise(function(resolve) {
			window.setTimeout(resolve, 2000);
		}).then(check);
	}

	function check() {
		return callShpunRoutingGet().then(function(routing) {
			var actual = String(((routing || {}).mode) || '').trim();
			if (actual === targetMode) return routing;
			if (Date.now() - started >= timeoutMs)
				return Promise.reject(new Error('routing mode apply timeout'));
			return retry();
		}, function(err) {
			if (Date.now() - started >= timeoutMs) return Promise.reject(err);
			return retry();
		});
	}

	return check();
}

/* ============================================================
 *  Styles
 * ========================================================== */

function injectStyles() {
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
		+ '.shpun-actions{margin-top:auto;display:grid;grid-template-columns:repeat(6,minmax(0,1fr));gap:10px;align-items:stretch;}'
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
		+ '.shpun-modal-wrap{width:min(680px,calc(100vw - 48px));max-width:100%;box-sizing:border-box;background:linear-gradient(135deg,rgba(6,18,36,.99) 0%,rgba(8,24,50,.99) 50%,rgba(20,19,58,.99) 100%);border-radius:16px;padding:20px;color:#eef2ff;}'
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
		+ '.shpun-server-switch{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:7px;margin-top:10px;padding:4px;border:1px solid rgba(120,140,180,.16);border-radius:11px;background:rgba(8,16,32,.48);}'
		+ '.shpun-server-switch-btn{padding:7px 10px;border:1px solid transparent;border-radius:8px;background:transparent;color:#94a3b8;font-size:12px;font-weight:850;cursor:pointer;transition:all .14s ease;}'
		+ '.shpun-server-switch-btn:hover{color:#e2e8f0;background:rgba(30,41,59,.56);}'
		+ '.shpun-server-switch-btn.is-active{color:#eef2ff;background:rgba(79,70,229,.30);border-color:rgba(129,140,248,.36);box-shadow:inset 0 1px 0 rgba(255,255,255,.04);}'
		+ '.shpun-server-switch-btn.is-auto{color:#d1fae5;background:rgba(5,150,105,.18);border-color:rgba(52,211,153,.28);}'
		+ '.shpun-server-switch-btn:disabled{opacity:.38;cursor:default;}'
		+ '.shpun-server-list{max-height:310px;overflow-y:auto;margin-top:10px;border:1px solid rgba(120,140,180,.18);border-radius:12px;padding:6px;background:rgba(8,16,32,.50);display:flex;flex-direction:column;gap:5px;}'
		+ '.shpun-server-row{width:100%;display:grid;grid-template-columns:minmax(0,1fr) auto;align-items:center;gap:10px;padding:9px 11px;border:1px solid rgba(120,140,180,.14);border-radius:9px;background:rgba(14,23,38,.72);color:#e6edf8;text-align:left;cursor:pointer;transition:all .14s ease;}'
		+ '.shpun-server-row:hover{background:rgba(25,35,54,.94);border-color:rgba(140,160,200,.30);}'
		+ '.shpun-server-row.is-selected{background:rgba(79,70,229,.24);border-color:rgba(140,130,255,.42);box-shadow:inset 0 1px 0 rgba(255,255,255,.03);}'
		+ '.shpun-server-location{font-size:13px;font-weight:800;color:#f8fafc;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;}'
		+ '.shpun-server-meta{display:inline-flex;align-items:center;justify-content:flex-end;gap:7px;min-width:0;white-space:nowrap;}'
		+ '.shpun-server-proto{font-size:11px;font-weight:800;color:#c7d2fe;text-transform:uppercase;}'
		+ '.shpun-server-latency{display:inline-flex;align-items:center;justify-content:center;box-sizing:border-box;min-width:58px;font-size:11px;font-weight:900;text-align:center;padding:3px 8px;border-radius:999px;border:1px solid rgba(120,140,180,.18);white-space:nowrap;}'
		+ '.shpun-server-row .shpun-server-latency--good{color:#86efac!important;background:rgba(22,163,74,.22)!important;border-color:rgba(74,222,128,.42)!important;box-shadow:inset 0 0 0 1px rgba(34,197,94,.05);}'
		+ '.shpun-server-row .shpun-server-latency--medium{color:#fde047!important;background:rgba(202,138,4,.22)!important;border-color:rgba(250,204,21,.42)!important;box-shadow:inset 0 0 0 1px rgba(250,204,21,.05);}'
		+ '.shpun-server-row .shpun-server-latency--slow{color:#fca5a5!important;background:rgba(220,38,38,.22)!important;border-color:rgba(248,113,113,.44)!important;box-shadow:inset 0 0 0 1px rgba(248,113,113,.05);}'
		+ '.shpun-server-latency--unknown{color:#94a3b8;background:rgba(148,163,184,.08);border-color:rgba(148,163,184,.16);}'
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
		+ '.shpun-modal-btn--danger{background:rgba(101,24,34,.58);border-color:rgba(248,113,113,.34);color:#fecaca;}'
		+ '.shpun-modal-btn--danger:hover{background:rgba(122,29,42,.68);}'
		+ '@media(max-width:980px){.shpun-card-main{grid-template-columns:1fr;}.shpun-fields-grid{grid-template-columns:repeat(2,minmax(0,1fr));}.shpun-actions{grid-template-columns:repeat(3,minmax(0,1fr));}.shpun-side-flex-spacer{display:none;}}'
		+ '@media(max-width:640px){.shpun-widget-card{padding:14px;border-radius:18px;}.shpun-title{font-size:18px;}.shpun-fields-grid{grid-template-columns:1fr;}.shpun-routing-actions{grid-template-columns:1fr;}.shpun-actions{grid-template-columns:repeat(2,minmax(0,1fr));}.shpun-modal-cols{grid-template-columns:1fr;}.shpun-server-row{gap:6px;}.shpun-server-meta{gap:5px;}.shpun-server-proto{display:none;}.shpun-btn{font-size:12px;}}';

	var s = document.getElementById('shpun-widget-style');
	if (!s) {
		s = document.createElement('style');
		s.id = 'shpun-widget-style';
		s.type = 'text/css';
		document.head.appendChild(s);
	}
	s.textContent = css;
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
	if (state && state.ok === 0)
		return E('span', { 'class': 'shpun-badge shpun-badge--err' }, [ E('span', { 'class': 'shpun-badge-dot' }), 'Ошибка виджета' ]);

	var hasCode = !!(state.code && state.code.trim().length > 0);
	var hasSub  = !!state.has_sub;
	var ready   = !!state.vpn_ready;
	var err     = (state.vpn_error || '').trim();
	var cls, text;
	if (err)                              { cls = 'shpun-badge shpun-badge--err';  text = 'Ошибка подключения'; }
	else if (!hasCode && hasSub && ready) { cls = 'shpun-badge shpun-badge--ok';   text = 'VPN подключен'; }
	else if (!hasCode && hasSub)          { cls = 'shpun-badge shpun-badge--warn'; text = 'Подключаемся'; }
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

function isValidDisplayIp(ip) {
	ip = String(ip || '').trim();
	if (!ip || ip.length > 80)
		return false;

	if (ip.indexOf(':') >= 0)
		return /^[0-9a-fA-F:]{3,45}$/.test(ip);

	if (!/^\d{1,3}(\.\d{1,3}){3}$/.test(ip))
		return false;

	var parts = ip.split('.');
	for (var i = 0; i < parts.length; i++) {
		var n = parseInt(parts[i], 10);
		if (isNaN(n) || n < 0 || n > 255)
			return false;
	}

	return true;
}

function buildServerBadges(server) {
	if (!server)
		return [];

	var proto = String(server.proto || '').toLowerCase();
	var protoLabel = proto === 'vless' ? 'VLESS' : (proto.toUpperCase() || 'VPN');
	var location = formatServerLocation(server.name || server.host || 'Server', protoLabel);
	var exitPing = parseInt(server.exit_ping_ms, 10);
	var badges = [
		makeBadge('shpun-badge--server', location + (protoLabel ? ' - ' + protoLabel : ''))
	];

	if (isValidDisplayIp(server.exit_ip))
		badges.push(makeBadge('shpun-badge--exit', 'Внешний IP ' + server.exit_ip, 'Финальный IP-адрес выхода из VPN-туннеля, который видят сайты и сервисы.'));

	if (!isNaN(exitPing) && exitPing >= 0)
		badges.push(makeBadge('shpun-badge--check', 'Пинг ' + exitPing + ' ms', 'Время отклика от роутера до финального IP выхода из VPN-туннеля.'));

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

	name = name.replace(/\s*VLESS\s*$/i, '').trim();
	name = name.replace(/[-–—]\s*$/g, '').trim();

	return name || 'Server';
}

function getServerConnectionGroup(server, location) {
	var label = String(location || '').toLowerCase();
	var host = String((server || {}).host || '').toLowerCase();

	if (label.indexOf('напрямую') >= 0)
		return 'direct';
	if (label.indexOf('через рф') >= 0)
		return 'gateway';

	return /^rush[0-9]*\.lenivo\.site$/.test(host) ? 'gateway' : 'direct';
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
		var autoEffective = (res.auto_effective_enabled === 1);
		var autoAdminDisabled = (res.auto_admin_disabled === 1);
		var excludeRuVal = (res.auto_exclude_ru == null ? 1 : res.auto_exclude_ru);
		var autoState = { effective: autoEffective, adminDisabled: autoAdminDisabled, excludeRu: !!excludeRuVal };

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
		var groupCounts = { gateway: 0, direct: 0 };
		var activeGroup = 'gateway';
		var gatewayButton;
		var directButton;
		var autoButton;

		function markSelected() {
			rows.forEach(function(row) {
				var active = row.index === chosen;
				row.node.className = 'shpun-server-row' + (active ? ' is-selected' : '');
				row.badge.className = 'shpun-server-kind ' + (active ? 'shpun-server-kind--main' : 'shpun-server-kind--reserve');
				row.badge.textContent = active ? 'Выбран' : 'Доступен';
			});
		}

		function renderGroup() {
			while (list.firstChild) list.removeChild(list.firstChild);
			rows.forEach(function(row) {
				if (row.group === activeGroup)
					list.appendChild(row.node);
			});
			gatewayButton.className = 'shpun-server-switch-btn' + (activeGroup === 'gateway' ? ' is-active' : '');
			directButton.className = 'shpun-server-switch-btn' + (activeGroup === 'direct' ? ' is-active' : '');
			autoButton.textContent = 'Найти лучший сервер';
			autoButton.disabled = (activeGroup === 'gateway' && autoState.excludeRu) ? true : null;
			list.scrollTop = 0;
		}

		servers.forEach(function(s) {
			var proto = String(s.proto || 'vpn').toLowerCase();
			var protoLabel = proto === 'vless' ? 'VLESS' : (proto.toUpperCase() || 'VPN');
			var isSelected = s.index === selected;
			var location = formatServerLocation(s.name || ('Server ' + s.index), protoLabel);
			var group = getServerConnectionGroup(s, location);
			groupCounts[group]++;
			if (isSelected)
				activeGroup = group;
			var latency = Number(s.latency_ms);
			var hasLatency = s.latency_ms != null && isFinite(latency) && latency >= 0;
			var latencyClass = !hasLatency ? 'unknown' : (latency <= 80 ? 'good' : (latency <= 160 ? 'medium' : 'slow'));
			var latencyText = hasLatency ? (Math.round(latency) + ' мс') : '—';
			var badge = E('span', { 'class': 'shpun-server-kind ' + (isSelected ? 'shpun-server-kind--main' : 'shpun-server-kind--reserve') }, isSelected ? 'Текущий' : 'Доступен');
			var latencyNode = E('span', {
				'class': 'shpun-server-latency shpun-server-latency--' + latencyClass,
				'title': hasLatency ? 'Время отклика сервера' : 'Сервер не ответил на ping'
			}, latencyText);
			var meta = E('span', { 'class': 'shpun-server-meta' }, [
				latencyNode,
				E('span', { 'class': 'shpun-server-proto' }, protoLabel),
				badge
			]);
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
				meta
			]);
			rows.push({ index: s.index, node: row, badge: badge, group: group, latency: hasLatency ? latency : null });
		});

		gatewayButton = E('button', {
			'type': 'button',
			'class': 'shpun-server-switch-btn',
			'disabled': groupCounts.gateway === 0 ? true : null,
			'click': function(ev) { ev.preventDefault(); activeGroup = 'gateway'; renderGroup(); }
		}, 'Через РФ · ' + groupCounts.gateway);
		directButton = E('button', {
			'type': 'button',
			'class': 'shpun-server-switch-btn',
			'disabled': groupCounts.direct === 0 ? true : null,
			'click': function(ev) { ev.preventDefault(); activeGroup = 'direct'; renderGroup(); }
		}, 'Напрямую · ' + groupCounts.direct);
		autoButton = E('button', {
			'type': 'button',
			'class': 'shpun-server-switch-btn is-auto',
			'click': function(ev) {
				ev.preventDefault();
				var candidates = rows.filter(function(row) { return row.group === activeGroup; });
				candidates.sort(function(a, b) {
					if (a.latency == null && b.latency == null) return a.index - b.index;
					if (a.latency == null) return 1;
					if (b.latency == null) return -1;
					return a.latency - b.latency || a.index - b.index;
				});
				var indexes = candidates.map(function(row) { return row.index; });
				if (!indexes.length) return;

				autoButton.disabled = true;
				callShpunServerAutoStart(indexes).then(function(result) {
					result = result || {};
					if (!result.ok) {
						autoButton.disabled = false;
						ui.addNotification(null, E('p', {}, 'Не удалось запустить автовыбор: ' + (result.error || 'ошибка')), 'error');
						return;
					}

					ui.hideModal();
					ui.addNotification(null, E('p', {}, 'Автовыбор запущен. Роутер проверяет серверы по отклику и качеству туннеля.'), 'info');
					var startedAt = Date.now();
					var poll = function() {
						callShpunServerAutoStatus().then(function(statusResult) {
							statusResult = statusResult || {};
							var status = String(statusResult.status || '');
							if (statusResult.running || status === 'starting') {
								if (Date.now() - startedAt < 360000)
									window.setTimeout(poll, 2500);
								else
									ui.addNotification(null, E('p', {}, 'Проверка серверов занимает слишком много времени. Роутер продолжит её в фоне.'), 'warning');
								return;
							}
							if (status.indexOf('ok:') === 0) {
								ui.addNotification(null, E('p', {}, 'Рабочий сервер выбран автоматически.'), 'info');
								window.setTimeout(function() { window.location.reload(); }, 1200);
							} else if (status.indexOf('failed:') === 0) {
								ui.addNotification(null, E('p', {}, 'Рабочий сервер в этом разделе не найден. Исходный сервер восстановлен.'), 'error');
							} else if (status.indexOf('error:') === 0) {
								ui.addNotification(null, E('p', {}, 'Автовыбор не запустился. Повторите попытку через несколько секунд.'), 'error');
							} else {
								window.setTimeout(poll, 1000);
							}
						}).catch(function() { window.setTimeout(poll, 2500); });
					};
					window.setTimeout(poll, 1500);
				}).catch(function(err) {
					autoButton.disabled = false;
					ui.addNotification(null, E('p', {}, 'Ошибка автовыбора: ' + String(err)), 'error');
				});
			}
		}, 'Найти лучший сервер');
		var autoToggleBtn = E('button', { 'type': 'button', 'class': 'shpun-server-switch-btn' }, 'Авто');

		function renderAutoToggle() {
			if (autoState.adminDisabled) {
				autoToggleBtn.className = 'shpun-server-switch-btn';
				autoToggleBtn.textContent = 'Авто ВЫКЛ (админ.)';
				autoToggleBtn.title = 'Автоматический failover административно отключён (AUTO_FAILOVER_ENABLE=0 в /etc/shpun/agent.conf).';
				return;
			}
			var on = autoState.effective;
			autoToggleBtn.className = 'shpun-server-switch-btn' + (on ? ' is-auto' : '');
			autoToggleBtn.textContent = on ? 'Авто ВКЛ' : 'Авто ВЫКЛ';
			autoToggleBtn.title = on
				? 'Автоматическая смена сервера при подтверждённой потере VPN включена. Ручной выбор сервера выключает авто.'
				: 'Автоматическая смена сервера выключена. Включить — этой кнопкой.';
		}

		autoToggleBtn.addEventListener('click', function(ev) {
			ev.preventDefault();
			var next = autoState.effective ? 0 : 1;
			autoToggleBtn.disabled = true;
			callShpunServerAutoSet(next).then(function(r) {
				r = r || {};
				autoToggleBtn.disabled = false;
				if (!r.ok) {
					ui.addNotification(null, E('p', {}, 'Не удалось переключить авто: ' + (r.error || 'ошибка')), 'error');
					return;
				}
				autoState.effective = !!r.effective_enabled;
				autoState.adminDisabled = !!r.admin_disabled;
				if (r.admin_disabled && next === 1)
					ui.addNotification(null, E('p', {}, 'Автоматический failover административно отключён.'), 'warning');
				renderAutoToggle();
			}).catch(function(err) {
				autoToggleBtn.disabled = false;
				ui.addNotification(null, E('p', {}, 'Ошибка: ' + String(err)), 'error');
			});
		});

		var excludeCheckbox = E('input', { 'type': 'checkbox', 'id': 'shpun-exclude-ru-cb' });
		excludeCheckbox.checked = autoState.excludeRu;
		excludeCheckbox.addEventListener('change', function() {
			var val = excludeCheckbox.checked ? 1 : 0;
			callShpunServerAutoExcludeRuSet(val).then(function(r) {
				r = r || {};
				if (!r.ok) {
					ui.addNotification(null, E('p', {}, 'Не удалось изменить исключение РФ: ' + (r.error || 'ошибка')), 'error');
					excludeCheckbox.checked = autoState.excludeRu;
					return;
				}
				autoState.excludeRu = !!r.enabled;
				excludeCheckbox.checked = autoState.excludeRu;
				if (activeGroup === 'gateway')
					autoButton.disabled = autoState.excludeRu ? true : null;
				ui.addNotification(null, E('p', {}, autoState.excludeRu ? 'Серверы РФ исключены из автовыбора.' : 'Серверы РФ включены в автовыбор.'), 'info');
			}).catch(function(err) {
				excludeCheckbox.checked = autoState.excludeRu;
				ui.addNotification(null, E('p', {}, 'Ошибка: ' + String(err)), 'error');
			});
		});
		var excludeLabel = E('label', { 'for': 'shpun-exclude-ru-cb', 'style': 'display:inline-flex;align-items:center;gap:6px;cursor:pointer;font-size:12px;font-weight:800;color:#c7d2fe;' }, [excludeCheckbox, ' Исключать серверы РФ']);
		var autoRow = E('div', { 'class': 'shpun-server-switch', 'style': 'grid-template-columns: minmax(0,1fr) auto; align-items:center; margin-bottom:6px;' }, [autoToggleBtn, excludeLabel]);
		renderAutoToggle();

		var serverSwitch = E('div', { 'class': 'shpun-server-switch' }, [ gatewayButton, directButton, autoButton ]);
		renderGroup();

		ui.showModal('Серверы VPN', [
			E('div', { 'class': 'shpun-modal-wrap' }, [
				E('div', { 'class': 'shpun-modal-desc' }, 'Выберите VPN-сервер. Время отклика измерено при открытии списка; после применения роутер переподключит туннель.'),
				autoRow,
				serverSwitch,
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
								if (r.ok) {
									autoState.effective = false;
									renderAutoToggle();
									ui.addNotification(null, E('p', {}, 'Сервер выбран. VPN перезапускается. Авто-выбор выключен.'), 'info');
								} else
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
		var stateErr = (state.ok === 0 && state.error) ? String(state.error) : '';

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

		var appLink = 'https://app.shpun.net';
		var botLink = 'https://t.me/shpunvpn_bot';
		var qrData = encodeURIComponent(appLink);
		var qrUrl = 'https://api.qrserver.com/v1/create-qr-code/?size=180x180&data=' + qrData;
		var qrUrlFallback = 'https://qrapi.dev/api/generate?data=' + qrData;

		var codeNode = E('span', {
			'class': code ? 'shpun-code shpun-code-copy' : 'shpun-code',
			'click': code ? ui.createHandlerFn(this, 'handleCopyCode', code) : null
		}, code || '— — — —');

		var fwValue = hasNewFw
			? E('span', {}, [ fwCurrentDisplay, E('span', { 'class': 'shpun-fw-badge' }, 'доступна ' + fwLatest) ])
			: fwCurrentDisplay;

		var hintText =
			stateErr  ? ('Ошибка чтения состояния виджета: ' + stateErr)
			: !code && !hasSub ? 'Роутер готовится к привязке. После генерации кода откройте ShpunApp и оформите услугу для роутера.'
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
		if (state.tunnel_quality_degraded === 1)
			statusMetricBadges.push(makeBadge(
				'shpun-badge--warn',
				'Качество туннеля снижено',
				'Базовая связь через VPN работает, но качество ухудшилось. Смена сервера не производится; роутер восстанавливает правила без перезапуска.'
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
									stateErr ? 'Ошибка виджета'
									: !code && !hasSub ? 'Ожидает генерации кода'
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
							E('button', { 'class': 'shpun-btn shpun-btn--primary', 'click': ui.createHandlerFn(this, 'handleRefreshConnection') }, 'Переподключить'),
							E('button', { 'class': 'shpun-btn shpun-btn--ghost',   'click': ui.createHandlerFn(this, 'handleServers') }, 'Серверы'),
							E('button', { 'class': 'shpun-btn shpun-btn--ghost',   'click': ui.createHandlerFn(this, 'handleCustomRoutes') }, 'Доп. маршруты'),
							E('button', { 'class': 'shpun-btn shpun-btn--ghost',   'click': ui.createHandlerFn(this, 'handleUpdateFirmware') }, hasNewFw ? ('Установить ' + fwLatest) : 'Проверить обновление'),
							E('button', { 'class': 'shpun-btn shpun-btn--danger',  'click': ui.createHandlerFn(this, 'handleResetVpn') }, 'Сбросить конфиг')
						])
					]),

					E('div', { 'class': 'shpun-col-side' }, [
						E('div', { 'class': 'shpun-side-card' }, [
							E('div', { 'class': 'shpun-side-title' }, 'Привязка через ShpunApp'),
							E('div', { 'class': 'shpun-side-url' }, 'app.shpun.net'),
							E('a', { 'class': 'shpun-qr-link', 'href': appLink, 'target': '_blank', 'rel': 'noreferrer' }, [
								E('img', {
									'class': 'shpun-qr',
									'src': qrUrl,
									'data-fallback-src': qrUrlFallback,
									'referrerpolicy': 'no-referrer',
									'alt': 'QR',
									'error': function(ev) {
										var img = ev.currentTarget || this;
										var fallback = img.getAttribute('data-fallback-src');
										if (fallback && img.getAttribute('data-fallback-used') !== '1') {
											img.setAttribute('data-fallback-used', '1');
											img.src = fallback;
										}
										else {
											img.style.display = 'none';
										}
									}
								})
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
					E('div', { 'class': 'shpun-modal-wrap' }, [
						E('div', { 'class': 'shpun-modal-desc' }, 'Список российских адресов ещё не загружен. Роутер скачает и применит его автоматически. На слабом устройстве это может занять несколько минут.'),
						E('div', { 'class': 'shpun-modal-help' }, 'Пока маршруты применяются, интернет продолжит работать через VPN.'),
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
									ui.hideModal();
									view._applyRoutingMode(targetMode);
								}
							}, 'Переключить режим')
						])
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
			.then(function() { return waitForRoutingMode(targetMode, 120000); })
			.then(function(routing) {
				return callShpunState().then(function(state) {
					view._state = state || {};
					view._state.routing = routing || {};
					ui.addNotification(null, E('p', {}, 'Режим маршрутизации обновлён.'), 'info');
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
				E('div', { 'class': 'shpun-modal-wrap' }, [
					E('div', { 'class': 'shpun-modal-desc' }, [ 'Доступна новая версия: ', E('strong', {}, fwCurrentRaw || '—'), ' → ', E('strong', {}, fwLatest), '.' ]),
					E('div', { 'class': 'shpun-modal-help' }, 'Во время установки VPN ненадолго переподключится. Настройки и привязка сохранятся.'),
					E('div', { 'class': 'shpun-modal-footer' }, [
						E('button', { 'type': 'button', 'class': 'shpun-modal-btn', 'click': function() { ui.hideModal(); } }, 'Отмена'),
						E('button', {
							'type': 'button',
							'class': 'shpun-modal-btn shpun-modal-btn--primary',
							'click': function() {
								ui.hideModal();
								ui.addNotification(null, E('p', {}, 'Установка обновления запущена.'), 'info');
								callShpunOtaInstall().catch(function(err) {
									ui.addNotification(null, E('p', {}, 'Ошибка: ' + String(err)), 'error');
								});
							}
						}, 'Установить ' + fwLatest)
					])
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
			E('div', { 'class': 'shpun-modal-wrap' }, [
				E('div', { 'class': 'shpun-modal-desc' }, 'Роутер загрузит свежий список серверов, пересоберёт конфигурацию и переподключит VPN.'),
				E('div', { 'class': 'shpun-modal-help' }, 'Привязка и настройки маршрутизации сохранятся. Обычно операция занимает 10-20 секунд.'),
				E('div', { 'class': 'shpun-modal-footer' }, [
					E('button', { 'type': 'button', 'class': 'shpun-modal-btn', 'click': function() { ui.hideModal(); } }, 'Отмена'),
					E('button', {
						'type': 'button',
						'class': 'shpun-modal-btn shpun-modal-btn--primary',
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
			])
		]);
	},

	handleResetVpn: function(ev) {
		if (ev) ev.preventDefault();
		ui.showModal('Сброс конфигурации', [
			E('div', { 'class': 'shpun-modal-wrap' }, [
				E('div', { 'class': 'shpun-modal-desc' }, 'Роутер удалит привязку, VPN-конфигурацию и создаст новый код подключения.'),
				E('div', { 'class': 'shpun-server-note' }, 'Это действие нельзя отменить. Для повторного подключения потребуется заново привязать роутер в ShpunApp.'),
				E('div', { 'class': 'shpun-modal-footer' }, [
					E('button', { 'type': 'button', 'class': 'shpun-modal-btn', 'click': function() { ui.hideModal(); } }, 'Отмена'),
					E('button', {
						'type': 'button',
						'class': 'shpun-modal-btn shpun-modal-btn--danger',
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
					}, 'Сбросить конфигурацию')
				])
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
