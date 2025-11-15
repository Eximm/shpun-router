'use strict';
'require view';
'require rpc';
'require ui';

var callShpunState = rpc.declare({
	object: 'shpun',
	method: 'state',
	expect: { '': {} }
});

// WAN / Wi-Fi будем вызывать напрямую, как из консоли (v2 через rpc.call)
function rpcApplyWan(params) {
	return rpc.call('shpun', 'apply_wan', params || {});
}

function rpcApplyWifi(params) {
	return rpc.call('shpun', 'apply_wifi', params || {});
}

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

		var protoDhcpBtn   = makeProtoButton('dhcp',  'DHCP (авто)');
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

		var wanUser   = E('input', {
			id: 'shpun-wan-username',
			'class': 'cbi-input-text',
			type: 'text',
			placeholder: 'например, user@isp'
		});

		var wanPass   = E('input', {
			id: 'shpun-wan-password',
			'class': 'cbi-input-text',
			type: 'password',
			placeholder: 'пароль из договора'
		});

		var wanIp     = E('input', {
			id: 'shpun-wan-ipaddr',
			'class': 'cbi-input-text',
			type: 'text',
			placeholder: 'например, 192.168.0.2'
		});

		var wanMask   = E('input', {
			id: 'shpun-wan-netmask',
			'class': 'cbi-input-text',
			type: 'text',
			placeholder: 'например, 255.255.255.0'
		});

		var wanGw     = E('input', {
			id: 'shpun-wan-gateway',
			'class': 'cbi-input-text',
			type: 'text',
			placeholder: 'обычно 192.168.0.1'
		});

		var wanDns    = E('input', {
			id: 'shpun-wan-dns',
			'class': 'cbi-input-text',
			type: 'text',
			placeholder: 'например, 8.8.8.8 1.1.1.1'
		});

		var wanServer = E('input', {
			id: 'shpun-wan-server',
			'class': 'cbi-input-text',
			type: 'text',
			placeholder: 'например, vpn.isp.example'
		});

		var wanUserWrap, wanPassWrap, wanIpWrap, wanMaskWrap, wanGwWrap, wanDnsWrap, wanServerWrap;

		var wanForm = E('div', { 'class': 'shpun-form-vertical' }, [
			makeField('Логин', wanUser,
				'Логин из договора с провайдером (для PPPoE/L2TP).',
				function (w) { wanUserWrap = w; }),
			makeField('Пароль', wanPass,
				'Пароль от интернет-подключения.',
				function (w) { wanPassWrap = w; }),
			makeField('IP-адрес', wanIp,
				'Статический IP, который выдал провайдер.',
				function (w) { wanIpWrap = w; }),
			makeField('Маска сети', wanMask,
				'Например, 255.255.255.0.',
				function (w) { wanMaskWrap = w; }),
			makeField('Шлюз', wanGw,
				'Обычно IP роутера провайдера (часто 192.168.0.1).',
				function (w) { wanGwWrap = w; }),
			makeField('DNS-сервер(а)', wanDns,
				'Можно указать DNS провайдера или публичные (8.8.8.8 1.1.1.1).',
				function (w) { wanDnsWrap = w; }),
			makeField('L2TP сервер', wanServer,
				'Адрес L2TP сервера от провайдера.',
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
				help = 'DHCP — самый простой вариант. Используйте его, если к этому роутеру подключён кабель от другого роутера или модема, ' +
				       'либо если провайдер не выдавал вам отдельные IP-настройки.';
			}
			else if (wanProto === 'pppoe') {
				help = 'PPPoE — используется, если провайдер выдал логин и пароль для подключения к интернету.';
			}
			else if (wanProto === 'static') {
				help = 'Static IP — провайдер выдал вам конкретный IP-адрес, маску, шлюз и DNS. Заполните их по данным из договора.';
			}
			else if (wanProto === 'l2tp') {
				help = 'L2TP — для подключения к L2TP-серверу провайдера. Нужны адрес сервера, логин и пароль.';
			}
			setText(wanHelpBox, help);
		}

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

				rpcApplyWan(params).then(function (res) {
					console.log('shpun.apply_wan result:', res);
					wanSaveBtn.disabled = false;

					if (res && res.ok == 1) {
						callNetworkReload().catch(function (e) {
							console.log('network.reload error:', e);
						});
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
					console.log('shpun.apply_wan RPC error:', err);
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
			E('p', { 'class': 'shpun-note' }, [
				'Если этот роутер подключён напрямую к провайдеру — выберите тип подключения из списка ниже. ',
				'Если роутер используется как дополнительный и уже получает интернет от другого роутера по кабелю — просто оставьте DHCP.'
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
			placeholder: 'например, Shpun-Router'
		});

		var wifiKey = E('input', {
			id: 'shpun-wifi-key',
			'class': 'cbi-input-text',
			type: 'text',
			placeholder: 'минимум 8 символов'
		});

		var wifiHelpBox = E('div', { 'class': 'shpun-help-box' }, [
			'SSID — имя вашей Wi-Fi сети. Пароль можно оставить пустым (открытая сеть, не рекомендуется). ',
			'Рекомендуется использовать пароль от 8 символов с буквами и цифрами.'
		]);

		var wifiForm = E('div', { 'class': 'shpun-form-vertical' }, [
			makeField('SSID', wifiSsid,
				'Имя сети, которое увидят устройства (например, Shpun-Router).',
				null),
			makeField('Пароль', wifiKey,
				'Оставьте пустым для открытой сети, либо задайте надёжный пароль.',
				null)
		]);

		var wifiSaveBtn = E('button', {
			'class': 'cbi-button cbi-button-apply',
			click: function (ev) {
				ev.preventDefault();

				wifiSaveBtn.disabled = true;

				var params = {
					ssid: wifiSsid.value || '',
					key:  wifiKey.value  || ''
				};

				rpcApplyWifi(params).then(function (res) {
					console.log('shpun.apply_wifi result:', res);
					wifiSaveBtn.disabled = false;

					if (res && res.ok == 1) {
						callWifiReload().catch(function (e) {
							console.log('network.wireless.reload error:', e);
						});
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
					console.log('shpun.apply_wifi RPC error:', err);
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

		function updateVpnStatus(st) {
			if (!st.has_sub) {
				setText(statusText, 'Код ещё не привязан к подписке.');
				setText(statusDetails,
					'Добавьте этот код в боте или в интерфейсе услуги Shpun VPN. ' +
					'После привязки статус здесь обновится автоматически.');
			}
			else if (!st.vpn_ready) {
				setText(statusText, 'Код привязан. Готовим VPN…');
				setText(statusDetails,
					'Роутер загружает настройки и подключается к серверу. ' +
					'Обычно это занимает до одной минуты.');
			}
			else {
				setText(statusText, 'VPN подключён и работает ✅');
				setText(statusDetails,
					'Интернет с этого роутера теперь проходит через Shpun VPN.');
			}
		}

		var qrImg = E('img', {
			'class': 'shpun-qr',
			src: 'https://api.qrserver.com/v1/create-qr-code/?size=200x200&data=' +
				encodeURIComponent('https://t.me/shpunvpn_bot')
		});

		var qrLink = E('a', {
			href: 'https://t.me/shpunvpn_bot',
			arget: '_blank'
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
			E('h2', {}, ['Шаг 3: Привязка VPN']),
			E('p', { 'class': 'shpun-note' }, [
				'Скопируйте код роутера выше и откройте бота ',
				E('a', { href: 'https://t.me/shpunvpn_bot', target: '_blank' }, ['@shpunvpn_bot']),
				'. В боте привяжите этот роутер к вашей VPN-подписке. После привязки статус ниже обновится автоматически.'
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
					qrLink,
					E('div', { 'class': 'shpun-qr-caption' }, [
						'Наведите камеру или нажмите, чтобы открыть бота @shpunvpn_bot'
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
			subscription_url: state.subscription_url || ''
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