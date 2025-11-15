'use strict';
'require view';
'require rpc';
'require ui';

var callShpunState = rpc.declare({
	object: 'shpun',
	method: 'state',
	expect: { '': {} }
});

var callApplyWan = rpc.declare({
	object: 'shpun',
	method: 'apply_wan',
	params: ['proto', 'username', 'password', 'ipaddr', 'netmask', 'gateway', 'dns', 'server'],
	expect: { '': {} }
});

var callApplyWifi = rpc.declare({
	object: 'shpun',
	method: 'apply_wifi',
	params: ['ssid', 'key'],
	expect: { '': {} }
});

return view.extend({
	// убираем стандартные кнопки LuCI
	handleSaveApply: null,
	handleSave: null,
	handleReset: null,

	load: function () {
		return Promise.all([
			callShpunState()
		]);
	},

	render: function (data) {
		var state = data[0] || {};

		var currentStep = 1;
		var pollTimer = null;
		var stepIndicators = [];

		/* ================== хелперы ================== */

		function setText(el, txt) {
			while (el.firstChild)
				el.removeChild(el.firstChild);
			el.appendChild(document.createTextNode(txt));
		}

		function updateStepIndicators(step) {
			for (var i = 0; i < stepIndicators.length; i++) {
				var s = i + 1;
				stepIndicators[i].className = 'shpun-step-indicator' + (s === step ? ' shpun-step-active' : '');
			}
		}

		function showStep(step) {
			currentStep = step;

			var s1 = document.getElementById('shpun-step-wan');
			var s2 = document.getElementById('shpun-step-wifi');
			var s3 = document.getElementById('shpun-step-vpn');

			if (s1) s1.style.display = (step === 1) ? '' : 'none';
			if (s2) s2.style.display = (step === 2) ? '' : 'none';
			if (s3) s3.style.display = (step === 3) ? '' : 'none';

			updateStepIndicators(step);
		}

		/* ================== Шаг 1: WAN ================== */

		var wanProto = 'dhcp';

		function makeProtoButton(value, label) {
			return E('button', {
				'class': 'shpun-proto-btn',
				'data-proto': value,
				click: function (ev) {
					ev.preventDefault();
					wanProto = value;
					updateProtoButtons();
					updateWanFieldsVisibility();
				}
			}, [label]);
		}

		var protoDhcpBtn  = makeProtoButton('dhcp',  'DHCP (авто)');
		var protoPppoeBtn = makeProtoButton('pppoe', 'PPPoE');
		var protoStaticBtn = makeProtoButton('static', 'Static IP');
		var protoL2tpBtn  = makeProtoButton('l2tp',  'L2TP');

		var protoButtons = [protoDhcpBtn, protoPppoeBtn, protoStaticBtn, protoL2tpBtn];

		function updateProtoButtons() {
			for (var i = 0; i < protoButtons.length; i++) {
				var btn = protoButtons[i];
				var val = btn.getAttribute('data-proto');
				btn.className = 'shpun-proto-btn' + (val === wanProto ? ' shpun-proto-active' : '');
			}
		}

		var wanUser   = E('input', { id: 'shpun-wan-username', 'class': 'cbi-input-text', type: 'text' });
		var wanPass   = E('input', { id: 'shpun-wan-password', 'class': 'cbi-input-text', type: 'password' });
		var wanIp     = E('input', { id: 'shpun-wan-ipaddr',   'class': 'cbi-input-text', type: 'text' });
		var wanMask   = E('input', { id: 'shpun-wan-netmask',  'class': 'cbi-input-text', type: 'text' });
		var wanGw     = E('input', { id: 'shpun-wan-gateway',  'class': 'cbi-input-text', type: 'text' });
		var wanDns    = E('input', { id: 'shpun-wan-dns',      'class': 'cbi-input-text', type: 'text' });
		var wanServer = E('input', { id: 'shpun-wan-server',   'class': 'cbi-input-text', type: 'text' });

		var wanUserWrap, wanPassWrap, wanIpWrap, wanMaskWrap, wanGwWrap, wanDnsWrap, wanServerWrap;

		function makeField(label, inputEl, refSetter) {
			var wrap = E('div', { 'class': 'shpun-field' }, [
				E('div', { 'class': 'shpun-label' }, [label]),
				inputEl
			]);
			refSetter(wrap);
			return wrap;
		}

		function updateWanFieldsVisibility() {
			var isPPPoE = (wanProto === 'pppoe');
			var isStatic = (wanProto === 'static');
			var isL2TP = (wanProto === 'l2tp');

			if (wanUserWrap) wanUserWrap.style.display = (isPPPoE || isL2TP) ? '' : 'none';
			if (wanPassWrap) wanPassWrap.style.display = (isPPPoE || isL2TP) ? '' : 'none';

			if (wanIpWrap)   wanIpWrap.style.display   = isStatic ? '' : 'none';
			if (wanMaskWrap) wanMaskWrap.style.display = isStatic ? '' : 'none';
			if (wanGwWrap)   wanGwWrap.style.display   = isStatic ? '' : 'none';
			if (wanDnsWrap)  wanDnsWrap.style.display  = isStatic ? '' : 'none';

			if (wanServerWrap) wanServerWrap.style.display = isL2TP ? '' : 'none';
		}

		var wanFormGrid = E('div', { 'class': 'shpun-form-grid' }, [
			// сюда потом подложим wrap'ы
		]);

		wanFormGrid.appendChild(
			makeField('Логин', wanUser, function (w) { wanUserWrap = w; })
		);
		wanFormGrid.appendChild(
			makeField('Пароль', wanPass, function (w) { wanPassWrap = w; })
		);
		wanFormGrid.appendChild(
			makeField('IP-адрес', wanIp, function (w) { wanIpWrap = w; })
		);
		wanFormGrid.appendChild(
			makeField('Маска сети', wanMask, function (w) { wanMaskWrap = w; })
		);
		wanFormGrid.appendChild(
			makeField('Шлюз', wanGw, function (w) { wanGwWrap = w; })
		);
		wanFormGrid.appendChild(
			makeField('DNS-сервер(а)', wanDns, function (w) { wanDnsWrap = w; })
		);
		wanFormGrid.appendChild(
			makeField('L2TP сервер', wanServer, function (w) { wanServerWrap = w; })
		);

		var wanSaveBtn = E('button', {
			'class': 'cbi-button cbi-button-apply',
			click: function (ev) {
				ev.preventDefault();

				wanSaveBtn.disabled = true;

				var params = {
					proto: wanProto,
					username: wanUser.value || '',
					password: wanPass.value || '',
					ipaddr:   wanIp.value   || '',
					netmask:  wanMask.value || '',
					gateway:  wanGw.value   || '',
					dns:      wanDns.value  || '',
					server:   wanServer.value || ''
				};

				callApplyWan(params).then(function (res) {
					wanSaveBtn.disabled = false;

					if (res && res.ok === 1) {
						ui.addNotification(null, E('p', {}, ['WAN настройки сохранены. Переходим к Wi-Fi.']));
						showStep(2);
					}
					else {
						ui.addNotification('error', E('p', {}, [
							'Ошибка применения WAN настроек: ',
							(res && res.error) ? res.error : 'unknown'
						]));
					}
				}).catch(function (err) {
					wanSaveBtn.disabled = false;
					ui.addNotification('error', E('p', {}, [
						'RPC ошибка apply_wan: ', String(err)
					]));
				});
			}
		}, ['Сохранить и далее → Wi-Fi']);

		var wanSkipBtn = E('button', {
			'class': 'cbi-button cbi-button-reset',
			click: function (ev) {
				ev.preventDefault();
				showStep(2);
			}
		}, ['Пропустить → Wi-Fi']);

		var wanStep = E('div', { id: 'shpun-step-wan' }, [
			E('h2', {}, ['Шаг 1: Подключение к интернету (WAN)']),
			E('p', { 'class': 'shpun-note' }, ['Выберите тип подключения к провайдеру и при необходимости укажите параметры.']),
			E('div', { 'class': 'shpun-proto-group' }, [
				protoDhcpBtn,
				protoPppoeBtn,
				protoStaticBtn,
				protoL2tpBtn
			]),
			wanFormGrid,
			E('div', { 'class': 'shpun-actions' }, [
				wanSkipBtn,
				wanSaveBtn
			])
		]);

		/* ================== Шаг 2: Wi-Fi ================== */

		var wifiSsid = E('input', {
			id: 'shpun-wifi-ssid',
			'class': 'cbi-input-text',
			type: 'text',
			placeholder: 'Shpun-Router'
		});

		var wifiKey = E('input', {
			id: 'shpun-wifi-key',
			'class': 'cbi-input-text',
			type: 'text',
			placeholder: 'пароль Wi-Fi (можно оставить пустым)'
		});

		var wifiSaveBtn = E('button', {
			'class': 'cbi-button cbi-button-apply',
			click: function (ev) {
				ev.preventDefault();

				wifiSaveBtn.disabled = true;

				var params = {
					ssid: wifiSsid.value || '',
					key: wifiKey.value || ''
				};

				callApplyWifi(params).then(function (res) {
					wifiSaveBtn.disabled = false;

					if (res && res.ok === 1) {
						ui.addNotification(null, E('p', {}, ['Wi-Fi настроен. Переходим к VPN.']));
						showStep(3);
					}
					else {
						ui.addNotification('error', E('p', {}, [
							'Ошибка применения Wi-Fi: ',
							(res && res.error) ? res.error : 'unknown'
						]));
					}
				}).catch(function (err) {
					wifiSaveBtn.disabled = false;
					ui.addNotification('error', E('p', {}, [
						'RPC ошибка apply_wifi: ', String(err)
					]));
				});
			}
		}, ['Сохранить и далее → VPN']);

		var wifiBackBtn = E('button', {
			'class': 'cbi-button cbi-button-reset',
			click: function (ev) {
				ev.preventDefault();
				showStep(1);
			}
		}, ['← Назад (WAN)']);

		var wifiSkipBtn = E('button', {
			'class': 'cbi-button cbi-button-reset',
			click: function (ev) {
				ev.preventDefault();
				showStep(3);
			}
		}, ['Пропустить → VPN']);

		var wifiStep = E('div', { id: 'shpun-step-wifi', style: 'display:none' }, [
			E('h2', {}, ['Шаг 2: Настройка Wi-Fi']),
			E('p', { 'class': 'shpun-note' }, ['Укажите имя сети (SSID) и пароль. Пустой пароль — открытая сеть.']),
			E('div', { 'class': 'shpun-form-grid' }, [
				makeField('SSID', wifiSsid, function () { }),
				makeField('Пароль', wifiKey, function () { })
			]),
			E('div', { 'class': 'shpun-actions' }, [
				wifiBackBtn,
				wifiSkipBtn,
				wifiSaveBtn
			])
		]);

		/* ================== Шаг 3: VPN ================== */

		var cleanCode = (state.code || '').replace(/[\r\n\s]+/g, '');

		var codeSpan = E('div', { 'class': 'shpun-code-box' }, [
			E('div', { 'class': 'shpun-code-label' }, ['Код роутера']),
			E('div', { 'class': 'shpun-code-value' }, [cleanCode || '—'])
		]);

		var statusText = E('div', { 'class': 'shpun-vpn-status-main' }, []);
		var statusDetails = E('div', { 'class': 'shpun-vpn-status-details' }, []);

		function updateVpnStatus(st) {
			if (!st.has_sub) {
				setText(statusText, 'Ожидаем привязку в биллинге…');
				setText(statusDetails, 'Введите код в боте или в интерфейсе услуги Shpun VPN. Агент опрашивает router_public.');
			}
			else if (!st.vpn_ready) {
				setText(statusText, 'Подписка найдена, VPN запускается…');
				setText(statusDetails, 'Агент скачивает движок и конфигурацию, затем стартует shpun-vpn.');
			}
			else {
				setText(statusText, 'VPN настроен и работает ✅');
				setText(statusDetails, st.subscription_url ? ('subscription_url: ' + st.subscription_url) : '');
			}
		}

		var qrImg = E('img', {
			'class': 'shpun-qr',
			src: 'https://api.qrserver.com/v1/create-qr-code/?size=200x200&data=' +
				encodeURIComponent('https://t.me/shpunvpn_bot')
		});

		var finishBtn = E('button', {
			'class': 'cbi-button cbi-button-apply',
			click: function (ev) {
				ev.preventDefault();
				window.location.href = L.url('admin/status/overview');
			}
		}, ['Завершить и перейти к статусу']);

		var vpnBackBtn = E('button', {
			'class': 'cbi-button cbi-button-reset',
			click: function (ev) {
				ev.preventDefault();
				showStep(2);
			}
		}, ['← Назад (Wi-Fi)']);

		var vpnStep = E('div', { id: 'shpun-step-vpn', style: 'display:none' }, [
			E('h2', {}, ['Шаг 3: Привязка VPN']),
			E('p', { 'class': 'shpun-note' }, [
				'Откройте бота ',
				E('a', { href: 'https://t.me/shpunvpn_bot', target: '_blank' }, ['@shpunvpn_bot']),
				' или веб-интерфейс услуги Shpun VPN и добавьте этот код к своей подписке.'
			]),
			E('div', { 'class': 'shpun-vpn-grid' }, [
				E('div', { 'class': 'shpun-vpn-left' }, [
					codeSpan,
					E('div', { 'class': 'shpun-vpn-status-block' }, [
						E('div', { 'class': 'shpun-vpn-status-title' }, ['Статус VPN']),
						statusText,
						statusDetails
					])
				]),
				E('div', { 'class': 'shpun-vpn-right' }, [
					qrImg,
					E('div', { 'class': 'shpun-qr-caption' }, ['QR-код на бота @shpunvpn_bot'])
				])
			]),
			E('div', { 'class': 'shpun-actions' }, [
				vpnBackBtn,
				finishBtn
			])
		]);

		/* ================== polling state ================== */

		function startPolling() {
			if (pollTimer)
				window.clearInterval(pollTimer);

			function doPoll() {
				callShpunState().then(function (st) {
					st = st || {};

					updateVpnStatus({
						has_sub: !!st.has_sub,
						vpn_ready: !!st.vpn_ready,
						subscription_url: st.subscription_url || ''
					});

					if (st.vpn_ready)
						window.clearInterval(pollTimer);
				}).catch(function (err) {
					console.log('shpun.state poll error:', err);
				});
			}

			doPoll();
			pollTimer = window.setInterval(doPoll, 5000);
		}

		/* ================== степпер ================== */

		function makeStepIndicator(num, title) {
			var el = E('div', {
				'class': 'shpun-step-indicator',
				click: function (ev) {
					ev.preventDefault();
					if (num <= currentStep)
						showStep(num);
				}
			}, [
				E('div', { 'class': 'shpun-step-circle' }, [String(num)]),
				E('div', { 'class': 'shpun-step-label' }, [title])
			]);

			stepIndicators.push(el);
			return el;
		}

		var stepper = E('div', { 'class': 'shpun-stepper' }, [
			makeStepIndicator(1, 'WAN'),
			makeStepIndicator(2, 'Wi-Fi'),
			makeStepIndicator(3, 'VPN')
		]);

		/* ================== init ================== */

		updateProtoButtons();
		updateWanFieldsVisibility();

		updateVpnStatus({
			has_sub: !!state.has_sub,
			vpn_ready: !!state.vpn_ready,
			subscription_url: state.subscription_url || ''
		});

		startPolling();

		window.setTimeout(function () {
			showStep(1);
		}, 0);

		/* ================== оформление ================== */

		var style = E('style', {}, [[
			'.shpun-card { max-width: 960px; margin: 1.5em auto; padding: 24px 24px 20px 24px; border-radius: 10px; ',
			'  background: rgba(0,0,0,0.35); box-shadow: 0 0 18px rgba(0,0,0,0.55); }',
			'.shpun-card h1 { margin-top: 0; margin-bottom: 0.4em; }',
			'.shpun-stepper { display:flex; justify-content:space-between; margin:1em 0 1.5em 0; gap:10px; }',
			'.shpun-step-indicator { flex:1; text-align:center; cursor:pointer; padding:8px 4px; border-radius:6px; border:1px solid rgba(255,255,255,0.15); ',
			'  background:rgba(0,0,0,0.25); }',
			'.shpun-step-indicator.shpun-step-active { background:rgba(66,139,202,0.35); border-color:#428bca; }',
			'.shpun-step-circle { width:24px; height:24px; line-height:24px; margin:0 auto 4px auto; border-radius:50%; border:1px solid currentColor; }',
			'.shpun-step-label { font-size:90%; opacity:0.9; }',
			'.shpun-note { margin-bottom: 0.8em; opacity: 0.9; }',
			'.shpun-form-grid { display:flex; flex-wrap:wrap; gap:16px 24px; margin-top: 1em; }',
			'.shpun-field { flex:1 1 260px; display:flex; flex-direction:column; }',
			'.shpun-label { font-weight:600; margin-bottom:4px; font-size:90%; }',
			'.shpun-field .cbi-input-text { max-width: 260px; }',
			'.shpun-proto-group { display:flex; flex-wrap:wrap; gap:10px; margin-top: 0.8em; }',
			'.shpun-proto-btn { flex:0 0 auto; padding:6px 10px; border-radius:16px; border:1px solid rgba(255,255,255,0.25); background:rgba(0,0,0,0.3); ',
			'  cursor:pointer; font-size:90%; }',
			'.shpun-proto-active { background:#428bca; border-color:#428bca; }',
			'.shpun-actions { display:flex; justify-content:flex-end; gap:10px; margin-top: 1.4em; }',
			'.shpun-code-box { padding:10px 14px; border-radius:8px; border:1px solid rgba(255,255,255,0.25); background:rgba(0,0,0,0.35); margin-bottom: 1em; }',
			'.shpun-code-label { font-size:80%; text-transform:uppercase; opacity:0.8; }',
			'.shpun-code-value { font-size:140%; font-weight:bold; margin-top:2px; letter-spacing:0.08em; }',
			'.shpun-vpn-grid { display:flex; flex-wrap:wrap; gap:18px 24px; margin-top: 1em; }',
			'.shpun-vpn-left { flex: 1 1 260px; }',
			'.shpun-vpn-right { flex: 0 0 220px; display:flex; flex-direction:column; align-items:center; }',
			'.shpun-qr { max-width:200px; border-radius:8px; background:#fff; padding:6px; }',
			'.shpun-qr-caption { margin-top:6px; font-size:80%; opacity:0.8; text-align:center; }',
			'.shpun-vpn-status-block { padding:10px 14px; border-radius:8px; border:1px solid rgba(255,255,255,0.25); background:rgba(0,0,0,0.35); }',
			'.shpun-vpn-status-title { font-size:90%; font-weight:600; margin-bottom:4px; }',
			'.shpun-vpn-status-main { margin-top:2px; }',
			'.shpun-vpn-status-details { margin-top:4px; font-size:85%; opacity:0.85; }'
		].join('\n')]);

		var wrapper = E('div', { 'class': 'shpun-card' }, [
			E('h1', {}, ['Shpun Router — мастер настройки']),
			E('p', {}, ['Пройдите три шага: интернет (WAN), Wi-Fi и VPN.']),
			stepper,
			E('hr'),
			wanStep,
			wifiStep,
			vpnStep
		]);

		updateStepIndicators(1);

		return E('div', { 'class': 'cbi-map' }, [
			style,
			wrapper
		]);
	}
});
