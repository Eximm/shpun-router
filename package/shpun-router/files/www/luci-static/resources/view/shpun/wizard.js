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
	params: [ 'proto', 'username', 'password', 'ipaddr', 'netmask', 'gateway', 'dns', 'server' ],
	expect: { '': {} }
});

var callApplyWifi = rpc.declare({
	object: 'shpun',
	method: 'apply_wifi',
	params: [ 'ssid', 'key' ],
	expect: { '': {} }
});

return view.extend({
	load: function() {
		// Грузим начальное состояние для шага VPN
		return Promise.all([
			callShpunState()
		]);
	},

	render: function(data) {
		var state = data[0] || {};

		var currentStep = 1;
		var pollTimer = null;

		function showStep(step) {
			currentStep = step;

			var s1 = document.getElementById('shpun-step-wan');
			var s2 = document.getElementById('shpun-step-wifi');
			var s3 = document.getElementById('shpun-step-vpn');

			if (s1) s1.style.display = (step === 1) ? '' : 'none';
			if (s2) s2.style.display = (step === 2) ? '' : 'none';
			if (s3) s3.style.display = (step === 3) ? '' : 'none';
		}

		function setText(el, txt) {
			while (el.firstChild)
				el.removeChild(el.firstChild);
			el.appendChild(document.createTextNode(txt));
		}

		/* --- Шаг 1: WAN --- */

		var wanProto = E('select', { 'id': 'shpun-wan-proto' }, [
			E('option', { 'value': 'dhcp'  }, [ 'DHCP (авто)' ]),
			E('option', { 'value': 'pppoe' }, [ 'PPPoE' ]),
			E('option', { 'value': 'static'}, [ 'Static (статический IP)' ]),
			E('option', { 'value': 'l2tp'  }, [ 'L2TP' ])
		]);

		var wanUser   = E('input', { 'id': 'shpun-wan-username', 'class': 'cbi-input-text', 'type': 'text' });
		var wanPass   = E('input', { 'id': 'shpun-wan-password', 'class': 'cbi-input-text', 'type': 'password' });
		var wanIp     = E('input', { 'id': 'shpun-wan-ipaddr',   'class': 'cbi-input-text', 'type': 'text' });
		var wanMask   = E('input', { 'id': 'shpun-wan-netmask',  'class': 'cbi-input-text', 'type': 'text' });
		var wanGw     = E('input', { 'id': 'shpun-wan-gateway',  'class': 'cbi-input-text', 'type': 'text' });
		var wanDns    = E('input', { 'id': 'shpun-wan-dns',      'class': 'cbi-input-text', 'type': 'text' });
		var wanServer = E('input', { 'id': 'shpun-wan-server',   'class': 'cbi-input-text', 'type': 'text' });

		function updateWanFieldsVisibility() {
			var proto = wanProto.value;

			var isPPPoE = (proto === 'pppoe');
			var isStatic = (proto === 'static');
			var isL2TP = (proto === 'l2tp');

			// username / password
			wanUser.parentElement.parentElement.style.display = (isPPPoE || isL2TP) ? '' : 'none';
			wanPass.parentElement.parentElement.style.display = (isPPPoE || isL2TP) ? '' : 'none';

			// IP / netmask / gateway / DNS
			wanIp.parentElement.parentElement.style.display   = isStatic ? '' : 'none';
			wanMask.parentElement.parentElement.style.display = isStatic ? '' : 'none';
			wanGw.parentElement.parentElement.style.display   = isStatic ? '' : 'none';
			wanDns.parentElement.parentElement.style.display  = isStatic ? '' : 'none';

			// L2TP server
			wanServer.parentElement.parentElement.style.display = isL2TP ? '' : 'none';
		}

		wanProto.addEventListener('change', updateWanFieldsVisibility);

		var wanSaveBtn = E('button', {
			'class': 'cbi-button cbi-button-apply',
			'click': L.bind(function(ev) {
				ev.preventDefault();

				wanSaveBtn.disabled = true;

				var proto = wanProto.value;

				var params = {
					proto: proto,
					username: wanUser.value || '',
					password: wanPass.value || '',
					ipaddr:   wanIp.value   || '',
					netmask:  wanMask.value || '',
					gateway:  wanGw.value   || '',
					dns:      wanDns.value  || '',
					server:   wanServer.value || ''
				};

				callApplyWan(params).then(function(res) {
					wanSaveBtn.disabled = false;

					if (res && res.ok === 1) {
						alert('WAN настройки сохранены. Переходим к Wi-Fi.');
						showStep(2);
					}
					else {
						alert('Ошибка применения WAN настроек: ' + (res && res.error ? res.error : 'unknown'));
					}
				}).catch(function(err) {
					wanSaveBtn.disabled = false;
					alert('RPC ошибка apply_wan: ' + err);
				});
			}, this)
		}, [ _('Сохранить и далее → Wi-Fi') ]);

		var wanStep = E('div', { 'id': 'shpun-step-wan' }, [
			E('h2', {}, [ 'Шаг 1: Подключение к интернету (WAN)' ]),
			E('p', {}, [ 'Выберите тип подключения к провайдеру и при необходимости укажите параметры.' ]),
			E('div', { 'class': 'cbi-section' }, [
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, [ 'Тип подключения' ]),
					E('div',   { 'class': 'cbi-value-field' }, [ wanProto ])
				]),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, [ 'Логин' ]),
					E('div',   { 'class': 'cbi-value-field' }, [ wanUser ])
				]),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, [ 'Пароль' ]),
					E('div',   { 'class': 'cbi-value-field' }, [ wanPass ])
				]),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, [ 'IP-адрес' ]),
					E('div',   { 'class': 'cbi-value-field' }, [ wanIp ])
				]),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, [ 'Маска сети' ]),
					E('div',   { 'class': 'cbi-value-field' }, [ wanMask ])
				]),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, [ 'Шлюз' ]),
					E('div',   { 'class': 'cbi-value-field' }, [ wanGw ])
				]),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, [ 'DNS-сервер(а)' ]),
					E('div',   { 'class': 'cbi-value-field' }, [ wanDns ])
				]),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, [ 'L2TP сервер' ]),
					E('div',   { 'class': 'cbi-value-field' }, [ wanServer ])
				])
			]),
			E('div', { 'class': 'cbi-page-actions' }, [
				wanSaveBtn
			])
		]);

		/* --- Шаг 2: Wi-Fi --- */

		var wifiSsid = E('input', { 'id': 'shpun-wifi-ssid', 'class': 'cbi-input-text', 'type': 'text', 'placeholder': 'Shpun-Router' });
		var wifiKey  = E('input', { 'id': 'shpun-wifi-key',  'class': 'cbi-input-text', 'type': 'text', 'placeholder': 'пароль Wi-Fi (можно оставить пустым)' });

		var wifiSaveBtn = E('button', {
			'class': 'cbi-button cbi-button-apply',
			'click': L.bind(function(ev) {
				ev.preventDefault();

				wifiSaveBtn.disabled = true;

				var ssid = wifiSsid.value || '';
				var key  = wifiKey.value  || '';

				var params = {
					ssid: ssid,
					key: key
				};

				callApplyWifi(params).then(function(res) {
					wifiSaveBtn.disabled = false;

					if (res && res.ok === 1) {
						alert('Wi-Fi настроен. Переходим к VPN.');
						showStep(3);
					}
					else {
						alert('Ошибка применения Wi-Fi: ' + (res && res.error ? res.error : 'unknown'));
					}
				}).catch(function(err) {
					wifiSaveBtn.disabled = false;
					alert('RPC ошибка apply_wifi: ' + err);
				});
			}, this)
		}, [ _('Сохранить и далее → VPN') ]);

		var wifiBackBtn = E('button', {
			'class': 'cbi-button cbi-button-reset',
			'click': function(ev) {
				ev.preventDefault();
				showStep(1);
			}
		}, [ '← Назад (WAN)' ]);

		var wifiStep = E('div', { 'id': 'shpun-step-wifi', 'style': 'display:none' }, [
			E('h2', {}, [ 'Шаг 2: Настройка Wi-Fi' ]),
			E('p', {}, [ 'Укажите имя сети (SSID) и пароль. Пустой пароль — открытая сеть.' ]),
			E('div', { 'class': 'cbi-section' }, [
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, [ 'SSID' ]),
					E('div',   { 'class': 'cbi-value-field' }, [ wifiSsid ])
				]),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, [ 'Пароль' ]),
					E('div',   { 'class': 'cbi-value-field' }, [ wifiKey ])
				])
			]),
			E('div', { 'class': 'cbi-page-actions' }, [
				wifiBackBtn,
				wifiSaveBtn
			])
		]);

		/* --- Шаг 3: VPN / код роутера --- */

		var cleanCode = (state.code || '').replace(/[\r\n\s]+/g, '');

		var codeSpan = E('span', { 'style': 'font-weight:bold; font-size:120%;' }, [ cleanCode || '—' ]);
		var statusText = E('div', { 'style': 'margin-top:0.5em;' }, []);
		var statusDetails = E('div', { 'style': 'margin-top:0.5em; font-size:90%; color:#888;' }, []);

		function updateVpnStatus(st) {
			// st = { has_sub, vpn_ready, subscription_url }
			if (!st.has_sub) {
				setText(statusText, 'Ожидаем привязку в биллинге (введите код в боте / услуге Shpun VPN)…');
				setText(statusDetails, 'router_public пока не вернул subscription_url. Агент продолжает опрос.');
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
			'style': 'margin-top:1em; max-width:200px;',
			// QR всегда просто на бота, без кода в параметрах
			'src': 'https://api.qrserver.com/v1/create-qr-code/?size=200x200&data=' +
				encodeURIComponent('https://t.me/shpunvpn_bot')
		});

		var finishBtn = E('button', {
			'class': 'cbi-button cbi-button-apply',
			'click': function(ev) {
				ev.preventDefault();
				window.location.href = L.url('admin/status/overview');
			}
		}, [ 'Завершить и перейти к статусу' ]);

		var vpnBackBtn = E('button', {
			'class': 'cbi-button cbi-button-reset',
			'click': function(ev) {
				ev.preventDefault();
				showStep(2);
			}
		}, [ '← Назад (Wi-Fi)' ]);

		var vpnStep = E('div', { 'id': 'shpun-step-vpn', 'style': 'display:none' }, [
			E('h2', {}, [ 'Шаг 3: Привязка VPN (код роутера)' ]),
			E('p', {}, [
				'Этот роутер идентифицируется кодом: ',
				codeSpan
			]),
			E('p', {}, [
				'Откройте бота ',
				E('a', { 'href': 'https://t.me/shpunvpn_bot', 'target': '_blank' }, [ '@shpunvpn_bot' ]),
				' или веб-интерфейс услуги Shpun VPN, добавьте этот код к своей подписке.'
			]),
			E('div', {}, [ qrImg ]),
			E('div', { 'style': 'margin-top:1em;' }, [
				E('strong', {}, [ 'Статус VPN:' ]),
				statusText,
				statusDetails
			]),
			E('div', { 'class': 'cbi-page-actions' }, [
				vpnBackBtn,
				finishBtn
			])
		]);

		function startPolling() {
			if (pollTimer)
				window.clearInterval(pollTimer);

			function doPoll() {
				callShpunState().then(function(st) {
					st = st || {};
					updateVpnStatus({
						has_sub: !!st.has_sub,
						vpn_ready: !!st.vpn_ready,
						subscription_url: st.subscription_url || ''
					});

					// если уже всё готово — перестаём поллить
					if (st.vpn_ready)
						window.clearInterval(pollTimer);
				}).catch(function(err) {
					console.log('shpun.state poll error:', err);
				});
			}

			doPoll();
			pollTimer = window.setInterval(doPoll, 5000);
		}

		// Инициализируем видимость полей WAN
		window.setTimeout(updateWanFieldsVisibility, 0);

		// Инициализируем статус VPN
		updateVpnStatus({
			has_sub: !!state.has_sub,
			vpn_ready: !!state.vpn_ready,
			subscription_url: state.subscription_url || ''
		});
		startPolling();

		// По умолчанию показываем шаг 1
		window.setTimeout(function() {
			showStep(1);
		}, 0);

		return E('div', { 'class': 'cbi-map' }, [
			E('h1', {}, [ 'Shpun Router — мастер настройки' ]),
			E('p', {}, [ 'Пройдите три шага: интернет (WAN), Wi-Fi и VPN.' ]),
			wanStep,
			wifiStep,
			vpnStep
		]);
	}
});

