'use strict';
'require view';
'require rpc';
'require ui';

var callShpunState = rpc.declare({
	object: 'shpun',
	method: 'state',
	expect: { '': {} }
});

/* --- RPC для WAN и Wi-Fi --- */
var callApplyWan = rpc.declare({
	object: 'shpun',
	method: 'apply_wan',
	params: [ 'args' ],
	expect: { '': {} }
});

var callApplyWifi = rpc.declare({
	object: 'shpun',
	method: 'apply_wifi',
	params: [ 'args' ],
	expect: { '': {} }
});

var callNetworkReload = rpc.declare({
	object: 'network',
	method: 'reload',
	expect: { '': {} }
});

var callWifiReload = rpc.declare({
	object: 'network.wireless',
	method: 'reload',
	expect: { '': {} }
});

return view.extend({
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

		function setText(el, txt) {
			while (el.firstChild)
				el.removeChild(el.firstChild);
			el.appendChild(document.createTextNode(txt));
		}

		function updateStepIndicators(step) {
			for (var i = 0; i < stepIndicators.length; i++) {
				var el = stepIndicators[i];
				var s = i + 1;

				if (s === step)
					el.classList.add('active');
				else
					el.classList.remove('active');
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

		function makeField(label, inputEl, hint, refSetter) {
			var nodes = [
				E('div', { 'class': 'shpun-label' }, [label]),
				inputEl
			];

			if (hint) {
				nodes.push(E('div', { 'class': 'shpun-hint' }, [hint]));
			}

			var wrap = E('div', { 'class': 'shpun-field' }, nodes);

			if (refSetter)
				refSetter(wrap);

			return wrap;
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

		var protoDhcpBtn   = makeProtoButton('dhcp',  'DHCP');
		var protoPppoeBtn  = makeProtoButton('pppoe', 'PPPoE');
		var protoStaticBtn = makeProtoButton('static','Static IP');
		var protoL2tpBtn   = makeProtoButton('l2tp',  'L2TP');

		var protoButtons = [protoDhcpBtn, protoPppoeBtn, protoStaticBtn, protoL2tpBtn];

		function updateProtoButtons() {
			for (var i = 0; i < protoButtons.length; i++) {
				var btn = protoButtons[i];
				var val = btn.getAttribute('data-proto');
				btn.className = 'shpun-proto-btn' + (val === wanProto ? ' shpun-proto-active' : '');

			}
		}

		var wanUser = E('input', {
			id: 'shpun-wan-username',
			'class': 'cbi-input-text',
			type: 'text',
			placeholder: 'user@isp'
		});

		var wanPass = E('input', {
			id: 'shpun-wan-password',
			'class': 'cbi-input-text',
			type: 'password',
			placeholder: 'пароль доступа'
		});

		var wanIp = E('input', {
			id: 'shpun-wan-ipaddr',
			'class': 'cbi-input-text',
			type: 'text',
			placeholder: '192.168.0.2'
		});

		var wanMask = E('input', {
			id: 'shpun-wan-netmask',
			'class': 'cbi-input-text',
			type: 'text',
			placeholder: '255.255.255.0'
		});

		var wanGw = E('input', {
			id: 'shpun-wan-gateway',
			'class': 'cbi-input-text',
			type: 'text',
			placeholder: '192.168.0.1'
		});

		var wanDns = E('input', {
			id: 'shpun-wan-dns',
			'class': 'cbi-input-text',
			type: 'text',
			placeholder: '8.8.8.8 1.1.1.1'
		});

		var wanServer = E('input', {
			id: 'shpun-wan-server',
			'class': 'cbi-input-text',
			type: 'text',
			placeholder: 'vpn.isp.example'
		});

		var wanUserWrap, wanPassWrap, wanIpWrap, wanMaskWrap, wanGwWrap, wanDnsWrap, wanServerWrap;

		var wanForm = E('div', { 'class': 'shpun-form-vertical' }, [
			makeField('Логин', wanUser,
				'Учётная запись для авторизации у провайдера (PPPoE или L2TP).',
				function (w) { wanUserWrap = w; }),
			makeField('Пароль', wanPass,
				'Пароль доступа к подключению.',
				function (w) { wanPassWrap = w; }),
			makeField('IP-адрес', wanIp,
				'Статический адрес WAN-интерфейса.',
				function (w) { wanIpWrap = w; }),
			makeField('Маска сети', wanMask,
				'Сетевая маска (например 255.255.255.0).',
				function (w) { wanMaskWrap = w; }),
			makeField('Шлюз', wanGw,
				'Адрес шлюза по умолчанию.',
				function (w) { wanGwWrap = w; }),
			makeField('DNS-серверы', wanDns,
				'Список DNS-серверов через пробел.',
				function (w) { wanDnsWrap = w; }),
			makeField('L2TP сервер', wanServer,
				'Имя или адрес L2TP-сервера провайдера.',
				function (w) { wanServerWrap = w; })
		]);

		var wanHelpBox = E('div', { 'class': 'shpun-help-box' }, []);

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

			var help = '';
			if (wanProto === 'dhcp') {
				help = 'DHCP — автоматическое получение параметров подключения от провайдера или вышестоящего маршрутизатора.';
			}
			else if (wanProto === 'pppoe') {
				help = 'PPPoE — схема подключения с авторизацией по логину и паролю.';
			}
			else if (wanProto === 'static') {
				help = 'Static IP — режим с фиксированными параметрами: IP-адрес, маска, шлюз и DNS.';
			}
			else if (wanProto === 'l2tp') {
				help = 'L2TP — туннельное подключение к L2TP-серверу провайдера (логин, пароль, адрес сервера).';
			}
			setText(wanHelpBox, help);
		}

		var wanSaveBtn = E('button', {
			'class': 'cbi-button cbi-button-apply',
			click: function (ev) {
				ev.preventDefault();

				wanSaveBtn.disabled = true;

				callApplyWan({
					args: [ {
						proto: wanProto,
						username: wanUser.value || '',
						password: wanPass.value || '',
						ipaddr:   wanIp.value   || '',
						netmask:  wanMask.value || '',
						gateway:  wanGw.value   || '',
						dns:      wanDns.value  || '',
						server:   wanServer.value || ''
					} ]
				}).then(function (res) {
					console.log('shpun.apply_wan result:', res);
					wanSaveBtn.disabled = false;

					if (res && res.ok == 1) {
						callNetworkReload().catch(function (e) {
							console.log('network.reload error:', e);
						});
						ui.addNotification(null, E('p', {}, ['Параметры WAN применены. Переход к настройке Wi-Fi.']));
						showStep(2);
					}
					else {
						ui.addNotification('error', E('p', {}, [
							'Ошибка применения параметров WAN: ',
							(res && res.error) ? res.error : 'неизвестная ошибка'
						]));
					}
				}).catch(function (err) {
					wanSaveBtn.disabled = false;
					console.log('shpun.apply_wan RPC error:', err);
					ui.addNotification('error', E('p', {}, [
						'RPC-ошибка apply_wan: ', String(err)
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
			E('h2', {}, ['Шаг 1: Подключение WAN']),
			E('p', { 'class': 'shpun-note' }, [
				'Выберите тип подключения, который использует ваш интернет-провайдер. ',
				'Если роутер подключён к модему или другому маршрутизатору, как правило используется режим DHCP. ',
				'При наличии выданных провайдером логина/пароля или фиксированных сетевых параметров используйте PPPoE, Static IP или L2TP.'
			]),
			E('div', { 'class': 'shpun-proto-group' }, [
				protoDhcpBtn,
				protoPppoeBtn,
				protoStaticBtn,
				protoL2tpBtn
			]),
			wanHelpBox,
			wanForm,
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
			placeholder: 'не менее 8 символов'
		});

		var wifiHelpBox = E('div', { 'class': 'shpun-help-box' }, [
			'Задайте имя беспроводной сети (SSID) и при необходимости пароль доступа. ',
			'Для защищённой сети используйте пароль длиной не менее 8 символов.'
		]);

		var wifiForm = E('div', { 'class': 'shpun-form-vertical' }, [
			makeField('SSID', wifiSsid,
				'Имя Wi-Fi сети, которое увидят устройства.',
				null),
			makeField('Пароль', wifiKey,
				'Оставьте поле пустым для открытой сети или укажите надёжный пароль.',
				null)
		]);

		var wifiSaveBtn = E('button', {
			'class': 'cbi-button cbi-button-apply',
			click: function (ev) {
				ev.preventDefault();

				wifiSaveBtn.disabled = true;

				callApplyWifi({
					args: [ {
						ssid: wifiSsid.value || '',
						key:  wifiKey.value  || ''
					} ]
				}).then(function (res) {
					console.log('shpun.apply_wifi result:', res);
					wifiSaveBtn.disabled = false;

					if (res && res.ok == 1) {
						callWifiReload().catch(function (e) {
							console.log('network.wireless.reload error:', e);
						});
						ui.addNotification(null, E('p', {}, ['Параметры Wi-Fi применены. Переход к настройке VPN.']));
						showStep(3);
					}
					else {
						ui.addNotification('error', E('p', {}, [
							'Ошибка применения параметров Wi-Fi: ',
							(res && res.error) ? res.error : 'неизвестная ошибка'
						]));
					}
				}).catch(function (err) {
					wifiSaveBtn.disabled = false;
					console.log('shpun.apply_wifi RPC error:', err);
					ui.addNotification('error', E('p', {}, [
						'RPC-ошибка apply_wifi: ', String(err)
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
			wifiHelpBox,
			wifiForm,
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
		var statusError = E('div', { 'class': 'shpun-vpn-status-error', style: 'display:none' }, []);

		function updateVpnStatus(st) {
			if (!st.has_sub) {
				setText(statusText, 'Код ещё не привязан к VPN-подписке.');
				setText(statusDetails,
					'Скопируйте код роутера и добавьте его в боте или в личном кабинете Shpun VPN. ' +
					'После привязки роутер автоматически получит конфигурацию и установит соединение.');
			}
			else if (!st.vpn_ready) {
				setText(statusText, 'Код привязан. Выполняется инициализация VPN-соединения.');
				setText(statusDetails,
					'Роутер загружает конфигурацию и устанавливает защищённый канал. Процесс может занять несколько минут.');
			}
			else {
				setText(statusText, 'VPN активен.');
				setText(statusDetails,
					'Трафик устройств, использующих этот роутер как основной шлюз, проходит через инфраструктуру Shpun VPN.');
			}

			if (st.vpn_error) {
				statusError.style.display = '';
				setText(statusError, 'Ошибка VPN: ' + st.vpn_error);
			}
			else {
				statusError.style.display = 'none';
				setText(statusError, '');
			}
		}

		var qrImg = E('img', {
			'class': 'shpun-qr',
			src: 'https://api.qrserver.com/v1/create-qr-code/?size=200x200&data=' +
				encodeURIComponent('https://t.me/shpunvpn_bot')
		});

		var qrLink = E('a', {
			href: 'https://t.me/shpunvpn_bot',
			target: '_blank'
		}, [ qrImg ]);

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
			E('h2', {}, ['Шаг 3: Активация VPN']),
			E('p', { 'class': 'shpun-note' }, [
				'Shpun Router подключается к инфраструктуре Shpun VPN через зашифрованный канал. ',
				'Для активации необходимо привязать этот роутер к вашей подписке с помощью кода, указанного ниже. ',
				'После привязки конфигурация и ключи будут получены автоматически.'
			]),
			E('div', { 'class': 'shpun-vpn-grid' }, [
				E('div', { 'class': 'shpun-vpn-left' }, [
					codeSpan,
					E('div', { 'class': 'shpun-vpn-status-block' }, [
						E('div', { 'class': 'shpun-vpn-status-title' }, ['Статус VPN']),
						statusText,
						statusDetails,
						statusError
					])
				]),
				E('div', { 'class': 'shpun-vpn-right' }, [
					qrLink,
					E('div', { 'class': 'shpun-qr-caption' }, [
						'Отсканируйте код камерой смартфона или нажмите на него для открытия бота @shpunvpn_bot.'
					])
				])
			]),
			E('div', { 'class': 'shpun-actions' }, [
				vpnBackBtn,
				finishBtn
			])
		]);

		function startPolling() {
			if (pollTimer)
				window.clearInterval(pollTimer);

			function doPoll() {
				callShpunState().then(function (st) {
					st = st || {};

					updateVpnStatus({
						has_sub: !!st.has_sub,
						vpn_ready: !!st.vpn_ready,
						subscription_url: st.subscription_url || '',
						vpn_error: st.vpn_error || ''
					});

					if (st.vpn_ready && pollTimer) {
						window.clearInterval(pollTimer);
						pollTimer = null;
					}
				}).catch(function (err) {
					console.log('shpun.state poll error:', err);
				});
			}

			doPoll();
			pollTimer = window.setInterval(doPoll, 5000);
		}

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

		updateProtoButtons();
		updateWanFieldsVisibility();

		updateVpnStatus({
			has_sub: !!state.has_sub,
			vpn_ready: !!state.vpn_ready,
			subscription_url: state.subscription_url || '',
			vpn_error: state.vpn_error || ''
		});

		startPolling();

		window.setTimeout(function () {
			showStep(1);
		}, 0);

		var style = E('style', {}, [[
			'.shpun-card { max-width: 960px; margin: 1.5em auto; padding: 24px 24px 20px 24px; border-radius: 10px;',
			'  background: rgba(0,0,0,0.35); box-shadow: 0 0 18px rgba(0,0,0,0.55); }',
			'.shpun-card h1 { margin-top: 0; margin-bottom: 0.4em; }',
			'.shpun-stepper { display:flex; justify-content:space-between; margin:1em 0 1.5em 0; gap:10px; }',
			'.shpun-step-indicator { flex:1; text-align:center; cursor:pointer; padding:8px 4px; border-radius:6px; border:1px solid rgba(255,255,255,0.15);',
			'  background:rgba(0,0,0,0.25); }',
			'.shpun-step-indicator.shpun-step-active { background:rgba(66,139,202,0.35); border-color:#428bca; }',
			'.shpun-step-circle { width:24px; height:24px; line-height:24px; margin:0 auto 4px auto; border-radius:50%; border:1px solid currentColor; }',
			'.shpun-step-label { font-size:90%; opacity:0.9; }',
			'.shpun-note { margin-bottom: 0.8em; opacity: 0.9; }',
			'.shpun-help-box { margin-top:0.8em; padding:8px 10px; border-radius:6px; border:1px solid rgba(255,255,255,0.2);',
			'  background:rgba(0,0,0,0.35); font-size:85%; opacity:0.95; }',
			'.shpun-form-vertical { display:flex; flex-direction:column; gap:12px; margin-top: 1em; }',
			'.shpun-field { display:flex; flex-direction:column; }',
			'.shpun-label { font-weight:600; margin-bottom:4px; font-size:90%; }',
			'.shpun-hint { margin-top:3px; font-size:80%; opacity:0.8; }',
			'.shpun-field .cbi-input-text { max-width: 320px; }',
			'.shpun-proto-group { display:flex; flex-wrap:wrap; gap:10px; margin-top: 0.8em; }',
			'.shpun-proto-btn { flex:0 0 auto; padding:6px 10px; border-radius:16px; border:1px solid rgba(255,255,255,0.25); background:rgba(0,0,0,0.3);',
			'  cursor:pointer; font-size:90%; }',
			'.shpun-proto-active { background:#428bca; border-color:#428bca; }',
			'.shpun-actions { display:flex; justify-content:flex-end; gap:10px; margin-top: 1.4em; }',
			'.shpun-code-box { padding:10px 14px; border-radius:8px; border:1px solid rgba(255,255,255,0.25); background:rgba(0,0,0,0.35); margin-bottom: 1em; }',
			'.shpun-code-label { font-size:80%; text-transform:uppercase; opacity:0.8; }',
			'.shpun-code-value { font-size:140%; font-weight:bold; margin-top:4px; letter-spacing:0.08em; }',
			'.shpun-vpn-grid { display:flex; flex-wrap:wrap; gap:18px 24px; margin-top: 1em; }',
			'.shpun-vpn-left { flex: 1 1 260px; }',
			'.shpun-vpn-right { flex: 0 0 220px; display:flex; flex-direction:column; align-items:center; }',
			'.shpun-qr { max-width:200px; border-radius:8px; background:#fff; padding:6px; }',
			'.shpun-qr-caption { margin-top:6px; font-size:80%; opacity:0.8; text-align:center; }',
			'.shpun-vpn-status-block { padding:10px 14px; border-radius:8px; border:1px solid rgba(255,255,255,0.25); background:rgba(0,0,0,0.35); }',
			'.shpun-vpn-status-title { font-size:90%; font-weight:600; margin-bottom:4px; }',
			'.shpun-vpn-status-main { margin-top:2px; }',
			'.shpun-vpn-status-details { margin-top:4px; font-size:85%; opacity:0.85; }',
			'.shpun-vpn-status-error { margin-top:6px; font-size:85%; color:#ff7373; }'
		].join('\n')]);

		var wrapper = E('div', { 'class': 'shpun-card' }, [
			E('h1', {}, ['Shpun Router — мастер настройки']),
			E('p', {}, [
				'Мастер по шагам настраивает подключение WAN, беспроводную сеть и интеграцию с Shpun VPN. ',
				'При необходимости настройки WAN и Wi-Fi можно пропустить и выполнить позже вручную.'
			]),
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
