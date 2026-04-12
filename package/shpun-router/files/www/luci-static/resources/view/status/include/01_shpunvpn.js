'use strict';
'require view';
'require rpc';
'require ui';
'require poll';

/* ============================================================
 *  RPC
 * ========================================================== */

var callShpunState = rpc.declare({
	object: 'shpun',
	method: 'state',
	expect: { '': {} }
});

var callShpunRoutingGet = rpc.declare({
	object: 'shpun',
	method: 'routing_get',
	expect: { '': {} }
});

var callShpunRoutingSet = rpc.declare({
	object: 'shpun',
	method: 'routing_set',
	expect: { '': {} }
});

var callShpunOtaCheck = rpc.declare({
	object: 'shpun',
	method: 'ota_check',
	expect: { '': {} }
});

var callShpunOtaInstall = rpc.declare({
	object: 'shpun',
	method: 'ota_install',
	expect: { '': {} }
});

var callShpunRefreshConnection = rpc.declare({
	object: 'shpun',
	method: 'refresh_connection',
	expect: { '': {} }
});

var callShpunResetVpn = rpc.declare({
	object: 'shpun',
	method: 'reset_vpn',
	expect: { '': {} }
});

/* ============================================================
 *  Styles
 * ========================================================== */

function injectStyles() {
	if (document.getElementById('shpun-widget-style'))
		return;

	var css = ''
		+ '.shpun-widget-card{'
		+ '  position:relative;'
		+ '  margin:0 0 16px;'
		+ '  padding:20px;'
		+ '  border-radius:24px;'
		+ '  overflow:hidden;'
		+ '  color:#eef2ff;'
		+ '  background:linear-gradient(135deg, rgba(6,18,36,.98) 0%, rgba(8,24,50,.98) 42%, rgba(20,19,58,.98) 100%);'
		+ '  border:1px solid rgba(110,130,185,.18);'
		+ '  box-shadow:0 18px 44px rgba(0,0,0,.28);'
		+ '}'

		+ '.shpun-widget-card:before{'
		+ '  content:"";'
		+ '  position:absolute;'
		+ '  inset:0;'
		+ '  pointer-events:none;'
		+ '  background:'
		+ '    radial-gradient(circle at 0% 0%, rgba(95,140,255,.15), transparent 30%),'
		+ '    radial-gradient(circle at 100% 0%, rgba(139,92,246,.14), transparent 28%),'
		+ '    radial-gradient(circle at 50% 100%, rgba(59,130,246,.08), transparent 35%);'
		+ '}'

		+ '.shpun-widget-inner{'
		+ '  position:relative;'
		+ '  z-index:1;'
		+ '  display:flex;'
		+ '  flex-direction:column;'
		+ '  gap:16px;'
		+ '}'

		+ '.shpun-widget-header{'
		+ '  display:flex;'
		+ '  justify-content:space-between;'
		+ '  align-items:flex-start;'
		+ '  gap:16px;'
		+ '}'

		+ '.shpun-title-wrap{'
		+ '  display:flex;'
		+ '  flex-direction:column;'
		+ '  gap:5px;'
		+ '  min-width:0;'
		+ '}'

		+ '.shpun-kicker{'
		+ '  display:flex;'
		+ '  align-items:center;'
		+ '  gap:8px;'
		+ '  font-size:12px;'
		+ '  font-weight:700;'
		+ '  color:#9fb5ff;'
		+ '}'

		+ '.shpun-kicker-dot{'
		+ '  width:8px;'
		+ '  height:8px;'
		+ '  border-radius:999px;'
		+ '  background:#6ea8ff;'
		+ '  box-shadow:0 0 10px rgba(110,168,255,.65);'
		+ '}'

		+ '.shpun-title{'
		+ '  font-size:22px;'
		+ '  line-height:1.08;'
		+ '  font-weight:800;'
		+ '  letter-spacing:-.025em;'
		+ '  color:#ffffff;'
		+ '}'

		+ '.shpun-subtitle{'
		+ '  font-size:13px;'
		+ '  line-height:1.45;'
		+ '  color:#c2ccde;'
		+ '  max-width:680px;'
		+ '}'

		+ '.shpun-badge{'
		+ '  display:inline-flex;'
		+ '  align-items:center;'
		+ '  padding:7px 12px;'
		+ '  border-radius:999px;'
		+ '  font-size:12px;'
		+ '  font-weight:800;'
		+ '  white-space:nowrap;'
		+ '  border:1px solid transparent;'
		+ '  align-self:flex-start;'
		+ '}'

		+ '.shpun-badge-dot{'
		+ '  width:8px;'
		+ '  height:8px;'
		+ '  margin-right:8px;'
		+ '  border-radius:999px;'
		+ '  flex:0 0 auto;'
		+ '}'

		+ '.shpun-badge--off{background:rgba(148,163,184,.11);color:#e5e7eb;border-color:rgba(148,163,184,.20);}'
		+ '.shpun-badge--off .shpun-badge-dot{background:#94a3b8;}'
		+ '.shpun-badge--warn{background:rgba(250,204,21,.12);color:#fde68a;border-color:rgba(250,204,21,.22);}'
		+ '.shpun-badge--warn .shpun-badge-dot{background:#facc15;}'
		+ '.shpun-badge--ok{background:rgba(34,197,94,.14);color:#bbf7d0;border-color:rgba(34,197,94,.24);}'
		+ '.shpun-badge--ok .shpun-badge-dot{background:#22c55e;}'
		+ '.shpun-badge--err{background:rgba(248,113,113,.14);color:#fecaca;border-color:rgba(248,113,113,.24);}'
		+ '.shpun-badge--err .shpun-badge-dot{background:#f87171;}'

		+ '.shpun-hint-box{'
		+ '  padding:13px 15px;'
		+ '  border-radius:16px;'
		+ '  border:1px solid rgba(120,140,180,.16);'
		+ '  background:rgba(10,17,32,.40);'
		+ '  color:#cad4e4;'
		+ '  font-size:13px;'
		+ '  line-height:1.55;'
		+ '}'

		+ '.shpun-card-main{'
		+ '  display:grid;'
		+ '  grid-template-columns:minmax(0,1fr) 220px;'
		+ '  gap:16px;'
		+ '  align-items:stretch;'
		+ '}'

		+ '.shpun-col-main{'
		+ '  min-width:0;'
		+ '  min-height:100%;'
		+ '  display:flex;'
		+ '  flex-direction:column;'
		+ '  gap:14px;'
		+ '}'

		+ '.shpun-fields-grid{'
		+ '  display:grid;'
		+ '  grid-template-columns:repeat(3, minmax(0,1fr));'
		+ '  gap:12px;'
		+ '}'

		+ '.shpun-field{'
		+ '  min-width:0;'
		+ '  padding:13px 14px;'
		+ '  border-radius:16px;'
		+ '  background:linear-gradient(180deg, rgba(255,255,255,.04), rgba(255,255,255,.02));'
		+ '  border:1px solid rgba(120,140,180,.14);'
		+ '  box-shadow:inset 0 1px 0 rgba(255,255,255,.025);'
		+ '}'

		+ '.shpun-field-label{'
		+ '  margin-bottom:5px;'
		+ '  font-size:11px;'
		+ '  font-weight:700;'
		+ '  letter-spacing:.03em;'
		+ '  color:#90a3c3;'
		+ '}'

		+ '.shpun-field-value{'
		+ '  font-size:14px;'
		+ '  font-weight:800;'
		+ '  line-height:1.4;'
		+ '  color:#ffffff;'
		+ '  word-break:break-word;'
		+ '}'

		+ '.shpun-routing-box{'
		+ '  padding:13px 14px;'
		+ '  border-radius:16px;'
		+ '  background:linear-gradient(180deg, rgba(255,255,255,.04), rgba(255,255,255,.02));'
		+ '  border:1px solid rgba(120,140,180,.14);'
		+ '  box-shadow:inset 0 1px 0 rgba(255,255,255,.025);'
		+ '}'

		+ '.shpun-routing-head{'
		+ '  display:flex;'
		+ '  justify-content:space-between;'
		+ '  align-items:flex-start;'
		+ '  gap:12px;'
		+ '  margin-bottom:10px;'
		+ '}'

		+ '.shpun-routing-title{'
		+ '  font-size:13px;'
		+ '  font-weight:800;'
		+ '  color:#ffffff;'
		+ '}'

		+ '.shpun-routing-sub{'
		+ '  font-size:11px;'
		+ '  line-height:1.45;'
		+ '  color:#9fb0c8;'
		+ '}'

		+ '.shpun-routing-meta{'
		+ '  font-size:11px;'
		+ '  line-height:1.45;'
		+ '  color:#b8c3d9;'
		+ '  text-align:right;'
		+ '}'

		+ '.shpun-routing-actions{'
		+ '  display:grid;'
		+ '  grid-template-columns:repeat(2, minmax(0,1fr));'
		+ '  gap:10px;'
		+ '}'

		+ '.shpun-code{'
		+ '  font-family:monospace;'
		+ '  font-size:18px;'
		+ '  font-weight:800;'
		+ '  letter-spacing:.06em;'
		+ '  color:#ffffff;'
		+ '}'

		+ '.shpun-code-copy{'
		+ '  display:inline-block;'
		+ '  cursor:pointer;'
		+ '  border-bottom:1px dashed rgba(165,180,252,.55);'
		+ '}'

		+ '.shpun-code-copy:hover{'
		+ '  color:#c4b5fd;'
		+ '  border-bottom-color:#a78bfa;'
		+ '}'

		+ '.shpun-fw-badge{'
		+ '  display:inline-block;'
		+ '  margin-left:8px;'
		+ '  padding:2px 8px;'
		+ '  border-radius:999px;'
		+ '  font-size:10px;'
		+ '  font-weight:800;'
		+ '  color:#bfdbfe;'
		+ '  background:rgba(96,165,250,.16);'
		+ '  border:1px solid rgba(96,165,250,.22);'
		+ '  box-shadow:0 0 0 0 rgba(96,165,250,.35);'
		+ '  animation:shpun-fw-pulse 1.8s ease-in-out infinite;'
		+ '}'

		+ '@keyframes shpun-fw-pulse{'
		+ '  0%{box-shadow:0 0 0 0 rgba(96,165,250,.35);}'
		+ '  70%{box-shadow:0 0 0 8px rgba(96,165,250,0);}'
		+ '  100%{box-shadow:0 0 0 0 rgba(96,165,250,0);}'
		+ '}'

		+ '.shpun-actions{'
		+ '  margin-top:auto;'
		+ '  display:grid;'
		+ '  grid-template-columns:repeat(4, minmax(0,1fr));'
		+ '  gap:10px;'
		+ '  align-items:stretch;'
		+ '}'

		+ '.shpun-col-side{'
		+ '  display:flex;'
		+ '  flex-direction:column;'
		+ '  min-height:100%;'
		+ '}'

		+ '.shpun-side-card{'
		+ '  width:100%;'
		+ '  height:100%;'
		+ '  padding:12px 12px 12px;'
		+ '  border-radius:18px;'
		+ '  background:linear-gradient(180deg, rgba(255,255,255,.04), rgba(255,255,255,.02));'
		+ '  border:1px solid rgba(120,140,180,.14);'
		+ '  display:flex;'
		+ '  flex-direction:column;'
		+ '  align-items:center;'
		+ '  justify-content:flex-start;'
		+ '  gap:8px;'
		+ '}'

		+ '.shpun-side-title{'
		+ '  font-size:13px;'
		+ '  font-weight:800;'
		+ '  color:#ffffff;'
		+ '  text-align:center;'
		+ '  line-height:1.3;'
		+ '}'

		+ '.shpun-side-url{'
		+ '  font-size:12px;'
		+ '  font-weight:700;'
		+ '  color:#c7d2fe;'
		+ '  text-align:center;'
		+ '  word-break:break-word;'
		+ '  line-height:1.35;'
		+ '}'

		+ '.shpun-qr-link{'
		+ '  display:inline-flex;'
		+ '  margin-top:2px;'
		+ '}'

		+ '.shpun-qr{'
		+ '  width:104px;'
		+ '  height:auto;'
		+ '  display:block;'
		+ '  padding:6px;'
		+ '  border-radius:14px;'
		+ '  background:#ffffff;'
		+ '  border:1px solid rgba(120,140,180,.18);'
		+ '  box-shadow:0 8px 20px rgba(0,0,0,.18);'
		+ '}'

		+ '.shpun-qr-caption{'
		+ '  font-size:11px;'
		+ '  line-height:1.45;'
		+ '  color:#9fb0c8;'
		+ '  text-align:center;'
		+ '  min-height:32px;'
		+ '  display:flex;'
		+ '  align-items:center;'
		+ '  justify-content:center;'
		+ '}'

		+ '.shpun-side-flex-spacer{'
		+ '  flex:1 1 auto;'
		+ '  width:100%;'
		+ '}'

		+ '.shpun-side-actions{'
		+ '  width:100%;'
		+ '  display:flex;'
		+ '  flex-direction:column;'
		+ '  gap:8px;'
		+ '  margin-top:auto;'
		+ '  padding-top:0;'
		+ '}'

		+ '.shpun-btn{'
		+ '  min-height:42px;'
		+ '  width:100%;'
		+ '  padding:8px 12px;'
		+ '  border-radius:999px;'
		+ '  border:1px solid rgba(120,140,180,.24);'
		+ '  background:rgba(14,23,38,.78);'
		+ '  color:#e6edf8;'
		+ '  font-size:12px;'
		+ '  font-weight:800;'
		+ '  line-height:1.25;'
		+ '  text-decoration:none;'
		+ '  display:inline-flex;'
		+ '  align-items:center;'
		+ '  justify-content:center;'
		+ '  gap:6px;'
		+ '  cursor:pointer;'
		+ '  transition:all .16s ease;'
		+ '  text-align:center;'
		+ '  white-space:normal;'
		+ '  word-break:break-word;'
		+ '  overflow-wrap:anywhere;'
		+ '}'

		+ '.shpun-actions .shpun-btn{'
		+ '  min-height:42px;'
		+ '}'

		+ '.shpun-side-actions .shpun-btn{'
		+ '  min-height:42px;'
		+ '  padding-top:8px;'
		+ '  padding-bottom:8px;'
		+ '}'

		+ '.shpun-btn:hover{'
		+ '  transform:translateY(-1px);'
		+ '  background:rgba(25,35,54,.96);'
		+ '  border-color:rgba(140,160,200,.34);'
		+ '}'

		+ '.shpun-btn--ghost{background:rgba(255,255,255,.03);}'
		+ '.shpun-btn--primary{background:linear-gradient(135deg, rgba(79,70,229,.90), rgba(99,102,241,.82));border-color:rgba(140,130,255,.28);color:#ffffff;box-shadow:0 8px 18px rgba(76,70,180,.18);}'
		+ '.shpun-btn--primary:hover{background:linear-gradient(135deg, rgba(88,80,238,.96), rgba(110,114,248,.88));}'
		+ '.shpun-btn--danger{background:rgba(101,24,34,.42);border-color:rgba(248,113,113,.30);color:#fecaca;}'
		+ '.shpun-btn--danger:hover{background:rgba(122,29,42,.50);}'
		+ '.shpun-btn.is-active{background:linear-gradient(135deg, rgba(79,70,229,.90), rgba(99,102,241,.82));border-color:rgba(140,130,255,.28);color:#ffffff;box-shadow:0 8px 18px rgba(76,70,180,.18);}'

		+ '@media (max-width: 980px){'
		+ '  .shpun-card-main{grid-template-columns:1fr;}'
		+ '  .shpun-fields-grid{grid-template-columns:repeat(2, minmax(0,1fr));}'
		+ '  .shpun-actions{grid-template-columns:repeat(2, minmax(0,1fr));}'
		+ '  .shpun-side-flex-spacer{display:none;}'
		+ '  .shpun-side-actions{margin-top:4px;}'
		+ '}'

		+ '@media (max-width: 640px){'
		+ '  .shpun-widget-card{padding:14px;border-radius:18px;}'
		+ '  .shpun-widget-inner{gap:14px;}'
		+ '  .shpun-widget-header{flex-direction:column;align-items:flex-start;}'
		+ '  .shpun-title{font-size:18px;}'
		+ '  .shpun-subtitle{font-size:12px;}'
		+ '  .shpun-fields-grid{grid-template-columns:1fr;}'
		+ '  .shpun-routing-actions{grid-template-columns:1fr;}'
		+ '  .shpun-actions{grid-template-columns:1fr;}'
		+ '  .shpun-btn{font-size:12px;}'
		+ '}';

	var style = document.createElement('style');
	style.id = 'shpun-widget-style';
	style.type = 'text/css';
	style.appendChild(document.createTextNode(css));
	document.head.appendChild(style);
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

		if (av < bv)
			return -1;
		if (av > bv)
			return 1;
	}

	return 0;
}

function buildStatusBadge(state) {
	var hasCode = !!(state.code && state.code.trim().length > 0);
	var hasSub  = !!state.has_sub;
	var ready   = !!state.vpn_ready;
	var err     = (state.vpn_error || '').trim();

	var cls, text;

	if (err) {
		cls = 'shpun-badge shpun-badge--err';
		text = 'Ошибка подключения';
	}
	else if (!hasCode) {
		cls = 'shpun-badge shpun-badge--off';
		text = 'Подготовка';
	}
	else if (hasCode && !hasSub) {
		cls = 'shpun-badge shpun-badge--warn';
		text = 'Ожидает привязки';
	}
	else if (hasCode && hasSub && !ready) {
		cls = 'shpun-badge shpun-badge--warn';
		text = 'Подключаемся';
	}
	else if (hasCode && hasSub && ready) {
		cls = 'shpun-badge shpun-badge--ok';
		text = 'VPN подключен';
	}
	else {
		cls = 'shpun-badge shpun-badge--off';
		text = 'Ожидание';
	}

	return E('span', { 'class': cls }, [
		E('span', { 'class': 'shpun-badge-dot' }),
		text
	]);
}

function hideLuCIHeader(rootNode) {
	if (!rootNode)
		return;

	var prev = rootNode.previousSibling;
	while (prev) {
		if (prev.style !== undefined)
			prev.style.display = 'none';
		prev = prev.previousSibling;
	}
}

function rerenderView(view, state) {
	state = state || {};
	view._state = state;

	var root = view.render(state);
	var container = view.container;

	if (container && container.parentNode) {
		container.parentNode.replaceChild(root, container);
		view.container = root;
		hideLuCIHeader(root);
	}
}

function getRoutingModeLabel(mode) {
	mode = String(mode || 'full').trim();

	if (mode === 'split_ru')
		return 'РФ напрямую, остальное через VPN';

	return 'Весь трафик через VPN';
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

		var code = (state.code || '').trim();
		var hasSub = !!state.has_sub;
		var vpnReady = !!state.vpn_ready;
		var err = (state.vpn_error || '').trim();

		var routing = state.routing || {};
		var routingMode = String(routing.mode || 'full').trim();
		var routingLabel = getRoutingModeLabel(routingMode);
		var routesVersion = String(routing.routes_version || '0').trim();
		var routesCount = routing.routes_count || 0;

		var fwCurrentRaw = (state.fw_current || '').trim();
		var fwCurrentDisplay = fwCurrentRaw || '—';
		var fwLatest = (state.fw_latest || '').trim();
		var hasNewFw = !!(fwLatest && fwCurrentRaw && compareVersions(fwCurrentRaw, fwLatest) < 0);

		var appLink = 'https://app.sdnonline.online';
		var botLink = 'https://t.me/shpunvpn_bot';
		var qrUrl = 'https://api.qrserver.com/v1/create-qr-code/?size=180x180&data=' + encodeURIComponent(appLink);

		var codeNode = E('span', {
			'class': code ? 'shpun-code shpun-code-copy' : 'shpun-code',
			'click': code ? ui.createHandlerFn(this, 'handleCopyCode', code) : null
		}, code || '— — — —');

		var fwValue;
		if (hasNewFw) {
			fwValue = E('span', {}, [
				fwCurrentDisplay,
				E('span', { 'class': 'shpun-fw-badge' }, 'доступна ' + fwLatest)
			]);
		}
		else {
			fwValue = fwCurrentDisplay;
		}

		var updateBtnLabel = hasNewFw
			? ('Установить ' + fwLatest)
			: 'Проверить обновление';

		var hintText =
			!code
				? 'Роутер готовится к подключению. После генерации кода откройте ShpunApp и оформите услугу для роутера.'
				: !hasSub
					? 'Откройте ShpunApp, закажите или активируйте услугу для роутера и выполните привязку по этому коду. После этого роутер автоматически получит конфигурацию.'
					: !vpnReady
						? (err
							? 'Привязка найдена, но подключение завершилось ошибкой: ' + err
							: 'Привязка найдена. Роутер получает актуальную конфигурацию и поднимает VPN. Обычно это занимает до минуты.')
						: 'Роутер подключен к Shpun SDN System. Для смены сервера, обновления подключения, управления услугой и привязкой используйте ShpunApp.';

		return E('div', { 'class': 'shpun-widget-card' }, [
			E('div', { 'class': 'shpun-widget-inner' }, [

				E('div', { 'class': 'shpun-widget-header' }, [
					E('div', { 'class': 'shpun-title-wrap' }, [
						E('div', { 'class': 'shpun-kicker' }, [
							E('span', { 'class': 'shpun-kicker-dot' }),
							'Shpun Router'
						]),
						E('div', { 'class': 'shpun-title' }, 'SDN System'),
						E('div', { 'class': 'shpun-subtitle' },
							code
								? 'Статус роутера, подключение и быстрые действия по конфигурации'
								: 'Подготовка роутера к подключению через ShpunApp'
						)
					]),
					buildStatusBadge(state)
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
									!code
										? 'Ожидает генерации кода'
										: !hasSub
											? 'Ожидает привязки'
											: vpnReady
												? 'Подключен'
												: (err ? 'Ошибка подключения' : 'Подключение…')
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
									E('div', { 'class': 'shpun-routing-title' }, 'Маршрутизация'),
									E('div', { 'class': 'shpun-routing-sub' },
										'Выберите, направлять ли весь трафик в туннель или пускать российские адреса напрямую.'
									)
								]),
								E('div', { 'class': 'shpun-routing-meta' }, [
									E('div', {}, 'Режим: ' + routingLabel),
									E('div', {}, 'Маршруты: v' + routesVersion + ' · ' + routesCount + ' CIDR')
								])
							]),

							E('div', { 'class': 'shpun-routing-actions' }, [
								E('button', {
									'class': 'shpun-btn ' + (routingMode === 'full'
										? 'shpun-btn--primary is-active'
										: 'shpun-btn--ghost'),
									'click': ui.createHandlerFn(this, 'handleSetRoutingMode', 'full')
								}, 'Весь трафик через VPN'),

								E('button', {
									'class': 'shpun-btn ' + (routingMode === 'split_ru'
										? 'shpun-btn--primary is-active'
										: 'shpun-btn--ghost'),
									'click': ui.createHandlerFn(this, 'handleSetRoutingMode', 'split_ru')
								}, 'РФ напрямую, остальное через VPN')
							])
						]),

						E('div', { 'class': 'shpun-actions' }, [
							E('button', {
								'class': 'shpun-btn shpun-btn--ghost',
								'click': ui.createHandlerFn(this, 'handleRefresh')
							}, 'Обновить статус'),

							E('button', {
								'class': 'shpun-btn shpun-btn--ghost',
								'click': ui.createHandlerFn(this, 'handleUpdateFirmware')
							}, updateBtnLabel),

							E('button', {
								'class': 'shpun-btn shpun-btn--primary',
								'click': ui.createHandlerFn(this, 'handleRefreshConnection')
							}, 'Обновить подключение'),

							E('button', {
								'class': 'shpun-btn shpun-btn--danger',
								'click': ui.createHandlerFn(this, 'handleResetVpn')
							}, 'Сбросить конфиг')
						])
					]),

					E('div', { 'class': 'shpun-col-side' }, [
						E('div', { 'class': 'shpun-side-card' }, [
							E('div', { 'class': 'shpun-side-title' }, 'Управление через ShpunApp'),
							E('div', { 'class': 'shpun-side-url' }, 'app.sdnonline.online'),

							E('a', {
								'class': 'shpun-qr-link',
								'href': appLink,
								'target': '_blank',
								'rel': 'noreferrer'
							}, [
								E('img', {
									'class': 'shpun-qr',
									'src': qrUrl,
									'alt': 'QR-код для открытия ShpunApp'
								})
							]),

							E('div', { 'class': 'shpun-qr-caption' },
								'Сканируйте QR-код, чтобы открыть ShpunApp на телефоне'
							),

							E('div', { 'class': 'shpun-side-flex-spacer' }),

							E('div', { 'class': 'shpun-side-actions' }, [
								E('a', {
									'class': 'shpun-btn shpun-btn--primary',
									'href': appLink,
									'target': '_blank',
									'rel': 'noreferrer'
								}, 'Открыть ShpunApp'),

								E('a', {
									'class': 'shpun-btn shpun-btn--ghost',
									'href': botLink,
									'target': '_blank',
									'rel': 'noreferrer'
								}, 'Бот — резервный вариант')
							])
						])
					])
				])
			])
		]);
	},

	handleCopyCode: function(ev, code) {
		if (ev) {
			ev.preventDefault();
			ev.stopPropagation();
		}
		if (!code)
			return;

		var text = String(code).trim();

		var notifyOk = function() {
			ui.addNotification(null, E('p', {}, 'Код роутера скопирован в буфер обмена.'), 'info');
		};

		var notifyErr = function(err) {
			ui.addNotification(null, E('p', {}, 'Не удалось скопировать код: ' + (err || 'ошибка доступа к буферу')), 'error');
		};

		try {
			if (navigator.clipboard && navigator.clipboard.writeText) {
				navigator.clipboard.writeText(text).then(notifyOk).catch(notifyErr);
			}
			else {
				var input = document.createElement('input');
				input.type = 'text';
				input.value = text;
				document.body.appendChild(input);
				input.select();

				try {
					document.execCommand('copy');
					notifyOk();
				}
				catch (e) {
					notifyErr(e);
				}

				document.body.removeChild(input);
			}
		}
		catch (e) {
			notifyErr(e);
		}
	},

	handleRefresh: function(ev) {
		if (ev)
			ev.preventDefault();

		var view = this;

		return Promise.all([
			callShpunState(),
			callShpunRoutingGet()
		]).then(function(data) {
			var st = data[0] || {};
			st.routing = data[1] || {};
			rerenderView(view, st);
		}).catch(function(err) {
			ui.addNotification(null, E('p', {}, [
				'Не удалось обновить статус Shpun Router: ',
				String(err)
			]), 'error');
		});
	},

	handleSetRoutingMode: function(ev, mode) {
		if (ev)
			ev.preventDefault();

		var view = this;
		var targetMode = String(mode || '').trim();

		if (targetMode !== 'full' && targetMode !== 'split_ru')
			return;

		ui.addNotification(
			null,
			E('p', {}, 'Применяем режим маршрутизации…'),
			'info'
		);

		return callShpunRoutingSet({ mode: targetMode }).then(function(res) {
			res = res || {};

			if (!res.ok) {
				ui.addNotification(
					null,
					E('p', {}, 'Не удалось применить режим маршрутизации: ' +
						(res.error ? String(res.error) : 'неизвестная ошибка')),
					'error'
				);
				return;
			}

			return Promise.all([
				callShpunState(),
				callShpunRoutingGet()
			]).then(function(data) {
				var st = data[0] || {};
				st.routing = data[1] || {};

				rerenderView(view, st);

				ui.addNotification(
					null,
					E('p', {}, 'Режим маршрутизации обновлён.'),
					'info'
				);
			});
		}).catch(function(err) {
			ui.addNotification(
				null,
				E('p', {}, 'Ошибка при смене режима маршрутизации: ' + String(err)),
				'error'
			);
		});
	},

	handleUpdateFirmware: function(ev) {
		if (ev)
			ev.preventDefault();

		var view = this;
		var st = view._state || {};

		var fwCurrentRaw = (st.fw_current || '').trim();
		var fwLatest = (st.fw_latest || '').trim();
		var hasNew = !!(fwLatest && fwCurrentRaw && compareVersions(fwCurrentRaw, fwLatest) < 0);
		var fwCurrentDisplay = fwCurrentRaw || '—';

		if (hasNew) {
			ui.showModal('Обновление прошивки', [
				E('p', {}, [
					'Доступна новая версия прошивки Shpun Router: ',
					E('strong', {}, fwCurrentDisplay),
					' → ',
					E('strong', {}, fwLatest),
					'.'
				]),
				E('p', {}, 'Установить обновление сейчас? Во время процесса VPN-соединение будет перезапущено.'),
				E('div', { 'style': 'margin-top:10px; text-align:right' }, [
					E('button', {
						'class': 'btn',
						'click': function() { ui.hideModal(); }
					}, 'Отмена'),
					E('button', {
						'class': 'btn cbi-button cbi-button-apply',
						'style': 'margin-left:8px',
						'click': function() {
							ui.hideModal();
							ui.addNotification(
								null,
								E('p', {}, 'Установка обновления прошивки запущена. Не отключайте питание роутера.'),
								'info'
							);

							callShpunOtaInstall().then(function() {
								window.setTimeout(function() {
									Promise.all([
										callShpunState(),
										callShpunRoutingGet()
									]).then(function(data) {
										var st2 = data[0] || {};
										st2.routing = data[1] || {};
										rerenderView(view, st2);
									});
								}, 20000);
							}).catch(function(err) {
								ui.addNotification(
									null,
									E('p', {}, 'Ошибка при запуске установки обновления: ' + String(err)),
									'error'
								);
							});
						}
					}, 'Установить ' + fwLatest)
				])
			]);

			return;
		}

		ui.addNotification(
			null,
			E('p', {}, 'Проверка обновлений запущена. Роутер связывается с сервером Shpun SDN System.'),
			'info'
		);

		return callShpunOtaCheck().then(function() {
			return new Promise(function(resolve) {
				window.setTimeout(resolve, 15000);
			});
		}).then(function() {
			return Promise.all([
				callShpunState(),
				callShpunRoutingGet()
			]);
		}).then(function(data) {
			var st2 = data[0] || {};
			st2.routing = data[1] || {};
			rerenderView(view, st2);

			var fwCurRaw = (st2.fw_current || '').trim();
			var fwLat = (st2.fw_latest || '').trim();
			var hasNewNow = !!(fwLat && fwCurRaw && compareVersions(fwCurRaw, fwLat) < 0);

			if (!hasNewNow) {
				ui.addNotification(
					null,
					E('p', {}, 'Новая версия прошивки не найдена. Установлена актуальная версия: ' + (fwCurRaw || '—') + '.'),
					'info'
				);
			}
		}).catch(function(err) {
			ui.addNotification(
				null,
				E('p', {}, 'Ошибка при проверке обновления прошивки: ' + String(err)),
				'error'
			);
		});
	},

	handleRefreshConnection: function(ev) {
		if (ev)
			ev.preventDefault();

		var view = this;
		var st = view._state || {};
		var code = (st.code || '').trim();

		if (!code) {
			ui.addNotification(
				null,
				E('p', {}, 'Сначала дождитесь генерации кода роутера.'),
				'warning'
			);
			return;
		}

		ui.showModal('Обновить подключение', [
			E('p', {}, 'Роутер заново получит актуальную конфигурацию услуги и пересоберёт подключение.'),
			E('p', {}, 'Используйте это после смены сервера, обновления услуги или изменений в ShpunApp.'),
			E('div', { 'style': 'margin-top:10px; text-align:right' }, [
				E('button', {
					'class': 'btn',
					'click': function() { ui.hideModal(); }
				}, 'Отмена'),
				E('button', {
					'class': 'btn cbi-button cbi-button-apply',
					'style': 'margin-left:8px',
					'click': function() {
						ui.hideModal();

						ui.addNotification(
							null,
							E('p', {}, 'Обновление подключения запущено. Роутер перечитывает конфигурацию и пересобирает туннель.'),
							'info'
						);

						return callShpunRefreshConnection().then(function(res) {
							res = res || {};

							if (!res.ok) {
								ui.addNotification(
									null,
									E('p', {}, 'Не удалось запустить обновление подключения: ' +
										(res.error ? String(res.error) : 'неизвестная ошибка')),
									'error'
								);
								return;
							}

							window.setTimeout(function() {
								Promise.all([
									callShpunState(),
									callShpunRoutingGet()
								]).then(function(data) {
									var st2 = data[0] || {};
									st2.routing = data[1] || {};
									rerenderView(view, st2);
								});
							}, 15000);
						}).catch(function(err) {
							ui.addNotification(
								null,
								E('p', {}, 'Ошибка при запуске обновления подключения: ' + String(err)),
								'error'
							);
						});
					}
				}, 'Обновить подключение')
			])
		]);
	},

	handleResetVpn: function(ev) {
		if (ev)
			ev.preventDefault();

		var view = this;

		ui.showModal('Сброс конфигурации', [
			E('p', {}, [
				'Вы действительно хотите полностью сбросить конфигурацию Shpun Router и вернуть устройство в состояние после установки пакета? ',
				'Будет сгенерирован новый код роутера, текущая привязка и конфигурация VPN будут потеряны.'
			]),
			E('div', { 'style': 'margin-top:10px; text-align:right' }, [
				E('button', {
					'class': 'btn',
					'click': function() { ui.hideModal(); }
				}, 'Отмена'),
				E('button', {
					'class': 'btn cbi-button cbi-button-negative',
					'style': 'margin-left:8px',
					'click': function() {
						ui.hideModal();

						return callShpunResetVpn().then(function(res) {
							res = res || {};

							if (res.ok) {
								ui.addNotification(
									null,
									E('p', {}, 'Конфигурация сброшена. Роутер переведён в режим первоначальной настройки и работает без VPN до новой привязки.'),
									'info'
								);

								window.setTimeout(function() {
									Promise.all([
										callShpunState(),
										callShpunRoutingGet()
									]).then(function(data) {
										var st2 = data[0] || {};
										st2.routing = data[1] || {};
										rerenderView(view, st2);
									});
								}, 5000);
							}
							else {
								ui.addNotification(
									null,
									E('p', {}, 'Не удалось сбросить конфигурацию: ' +
										(res.error ? String(res.error) : 'неизвестная ошибка')),
									'error'
								);
							}
						}).catch(function(err) {
							ui.addNotification(
								null,
								E('p', {}, 'Ошибка при вызове сброса конфигурации: ' + String(err)),
								'error'
							);
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
		hideLuCIHeader(node);

		var view = this;

		this._pollId = poll.add(function() {
			if (!view.container || !view.container.parentNode)
				return;

			return Promise.all([
				callShpunState(),
				callShpunRoutingGet()
			]).then(function(data) {
				var st = data[0] || {};
				st.routing = data[1] || {};
				rerenderView(view, st);
			});
		}, 10);
	},

	onunload: function() {
		if (this._pollId != null)
			poll.remove(this._pollId);
	}
});