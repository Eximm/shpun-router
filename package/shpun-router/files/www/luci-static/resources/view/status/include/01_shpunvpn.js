'use strict';
'require view';
'require rpc';
'require ui';
'require poll';

/* ============================================================
 *  RPC-обёртки (ubus методы shpun)
 * ========================================================== */

var callShpunState = rpc.declare({
	object: 'shpun',
	method: 'state',
	expect: { '': {} }
});

var callShpunUpdate = rpc.declare({
	object: 'shpun',
	method: 'update_router',
	expect: { '': {} }
});

/* ============================================================
 *  Стили виджета (однократная инъекция <style> в <head>)
 * ========================================================== */

function injectStyles() {
	if (document.getElementById('shpun-widget-style'))
		return;

	var css = ''
		/* Карточка-обёртка */
		+ '.shpun-widget-card {'
		+ '  border-radius: 10px;'
		+ '  padding: 12px 14px;'
		+ '  background: #1f2933;'
		+ '  color: #f9fafb;'
		+ '  box-shadow: 0 2px 5px rgba(0,0,0,0.35);'
		+ '  margin-bottom: 16px;'
		+ '  display: flex;'
		+ '  flex-direction: column;'
		+ '  gap: 10px;'
		+ '}'
		/* Шапка */
		+ '.shpun-widget-header {'
		+ '  display: flex;'
		+ '  justify-content: space-between;'
		+ '  align-items: center;'
		+ '}'
		+ '.shpun-title {'
		+ '  font-weight: 600;'
		+ '  font-size: 15px;'
		+ '}'
		+ '.shpun-subtitle {'
		+ '  font-size: 11px;'
		+ '  color: #d1d5db;'
		+ '}'
		/* Бейдж статуса */
		+ '.shpun-badge {'
		+ '  display: inline-flex;'
		+ '  align-items: center;'
		+ '  border-radius: 999px;'
		+ '  padding: 2px 8px;'
		+ '  font-size: 11px;'
		+ '  font-weight: 500;'
		+ '}'
		+ '.shpun-badge-dot {'
		+ '  width: 8px;'
		+ '  height: 8px;'
		+ '  border-radius: 999px;'
		+ '  margin-right: 6px;'
		+ '}'
		+ '.shpun-badge--off {'
		+ '  background: rgba(148,163,184,0.15);'
		+ '  color: #e5e7eb;'
		+ '}'
		+ '.shpun-badge--off .shpun-badge-dot {'
		+ '  background: #6b7280;'
		+ '}'
		+ '.shpun-badge--warn {'
		+ '  background: rgba(250,204,21,0.15);'
		+ '  color: #facc15;'
		+ '}'
		+ '.shpun-badge--warn .shpun-badge-dot {'
		+ '  background: #facc15;'
		+ '}'
		+ '.shpun-badge--ok {'
		+ '  background: rgba(34,197,94,0.20);'
		+ '  color: #bbf7d0;'
		+ '}'
		+ '.shpun-badge--ok .shpun-badge-dot {'
		+ '  background: #22c55e;'
		+ '}'
		+ '.shpun-badge--err {'
		+ '  background: rgba(248,113,113,0.20);'
		+ '  color: #fecaca;'
		+ '}'
		+ '.shpun-badge--err .shpun-badge-dot {'
		+ '  background: #f87171;'
		+ '}'
		/* Основная зона: две колонки */
		+ '.shpun-card-main {'
		+ '  display: flex;'
		+ '  flex-wrap: wrap;'
		+ '  gap: 16px;'
		+ '  align-items: flex-start;'
		+ '}'
		+ '.shpun-col-main {'
		+ '  flex: 2 1 220px;'
		+ '  display: flex;'
		+ '  flex-direction: column;'
		+ '  gap: 10px;'
		+ '}'
		+ '.shpun-col-side {'
		+ '  flex: 1 1 160px;'
		+ '  display: flex;'
		+ '  flex-direction: column;'
		+ '  align-items: center;'
		+ '  gap: 6px;'
		+ '}'
		/* Поля слева — в столбик */
		+ '.shpun-field {'
		+ '  min-width: 130px;'
		+ '  margin-bottom: 4px;'
		+ '}'
		+ '.shpun-field-label {'
		+ '  font-size: 11px;'
		+ '  color: #9ca3af;'
		+ '  text-transform: uppercase;'
		+ '  letter-spacing: .04em;'
		+ '  margin-bottom: 2px;'
		+ '}'
		+ '.shpun-field-value {'
		+ '  font-size: 13px;'
		+ '  font-weight: 500;'
		+ '  line-height: 1.35;'
		+ '}'
		+ '.shpun-code {'
		+ '  font-family: monospace;'
		+ '  font-size: 16px;'
		+ '  font-weight: 700;'
		+ '  letter-spacing: 0.12em;'
		+ '}'
		+ '.shpun-code-copy {'
		+ '  cursor: pointer;'
		+ '  border-bottom: 1px dashed rgba(148,163,184,0.7);'
		+ '}'
		+ '.shpun-code-copy:hover {'
		+ '  color: #bae6fd;'
		+ '  border-bottom-color: #38bdf8;'
		+ '}'
		/* Кнопки внизу */
		+ '.shpun-actions {'
		+ '  display: flex;'
		+ '  flex-wrap: wrap;'
		+ '  gap: 6px;'
		+ '  margin-top: 4px;'
		+ '  align-items: center;'
		+ '  justify-content: space-between;'
		+ '}'
		+ '.shpun-actions-left {'
		+ '  display: flex;'
		+ '  flex-wrap: wrap;'
		+ '  gap: 6px;'
		+ '  flex: 2 1 220px;'
		+ '}'
		+ '.shpun-actions-right {'
		+ '  flex: 1 1 160px;'
		+ '  display: flex;'
		+ '  justify-content: center;'
		+ '}'
		+ '.shpun-btn {'
		+ '  border-radius: 999px;'
		+ '  border: 1px solid rgba(148,163,184,0.6);'
		+ '  background: rgba(15,23,42,0.8);'
		+ '  color: #e5e7eb;'
		+ '  padding: 4px 10px;'
		+ '  font-size: 11px;'
		+ '  cursor: pointer;'
		+ '  text-decoration: none;'
		+ '  display: inline-flex;'
		+ '  align-items: center;'
		+ '  gap: 4px;'
		+ '}'
		+ '.shpun-btn:hover {'
		+ '  background: rgba(31,41,55,0.95);'
		+ '}'
		+ '.shpun-btn-primary {'
		+ '  border-color: #38bdf8;'
		+ '  background: #0f172a;'
		+ '  color: #e0f2fe;'
		+ '}'
		/* Подпись/FAQ */
		+ '.shpun-hint {'
		+ '  font-size: 11px;'
		+ '  color: #9ca3af;'
		+ '  margin-top: 4px;'
		+ '}'
		/* QR-код + подпись */
		+ '.shpun-qr {'
		+ '  border: 1px solid rgba(148,163,184,0.6);'
		+ '  border-radius: 8px;'
		+ '  padding: 4px;'
		+ '  background: #0b1120;'
		+ '  max-width: 140px;'
		+ '  height: auto;'
		+ '  display: block;'
		+ '}'
		+ '.shpun-qr-caption {'
		+ '  font-size: 11px;'
		+ '  color: #9ca3af;'
		+ '  text-align: center;'
		+ '}';

	var style = document.createElement('style');
	style.id = 'shpun-widget-style';
	style.type = 'text/css';
	style.appendChild(document.createTextNode(css));
	document.head.appendChild(style);
}

/* ============================================================
 *  Построение бейджа статуса
 * ========================================================== */

function buildStatusBadge(state) {
	var hasCode = !!(state.code && state.code.trim().length > 0);
	var hasSub  = !!state.has_sub;
	var ready   = !!state.vpn_ready;
	var err     = (state.vpn_error || '').trim();

	var cls  = 'shpun-badge shpun-badge--off';
	var text = 'Ожидает кода';

	if (!hasCode) {
		cls  = 'shpun-badge shpun-badge--off';
		text = 'Код роутера ещё не создан';
	}
	else if (hasCode && !hasSub) {
		cls  = 'shpun-badge shpun-badge--warn';
		text = 'Ожидает привязки в Shpun SDN System';
	}
	else if (hasCode && hasSub && !ready && !err) {
		cls  = 'shpun-badge shpun-badge--warn';
		text = 'Подписка найдена, подключаемся…';
	}
	else if (hasCode && hasSub && ready && !err) {
		cls  = 'shpun-badge shpun-badge--ok';
		text = 'VPN подключен';
	}
	else if (err) {
		cls  = 'shpun-badge shpun-badge--err';
		text = 'Ошибка: ' + err;
	}

	return E('span', { 'class': cls }, [
		E('span', { 'class': 'shpun-badge-dot' }),
		text
	]);
}

/* ============================================================
 *  Основной view LuCI
 * ========================================================== */

return view.extend({
	load: function() {
		injectStyles();
		return callShpunState().then(function(data) {
			return data || {};
		});
	},

	render: function(state) {
		state = state || {};

		var code      = (state.code || '').trim();
		var fwCurrent = (state.fw_current || '').trim();
		var vpnIP     = (state.vpn_ip || '').trim();
		var hasSub    = !!state.has_sub;
		var vpnReady  = !!state.vpn_ready;
		var err       = (state.vpn_error || '').trim();

		if (!fwCurrent)
			fwCurrent = 'неизвестно';

		if (!vpnIP || vpnIP === 'unknown')
			vpnIP = vpnReady ? 'определяется…' : '—';

		/* Ссылка на бота и QR — всегда одна и та же */
		var deepLink = 'https://t.me/shpunvpn_bot';
		var qrUrl    = 'https://api.qrserver.com/v1/create-qr-code/?size=160x160&data=' +
			encodeURIComponent(deepLink);

		/* код: клик = копирование в буфер (без всплытия клика наверх) */
		var codeNode = E('span', {
			'class': 'shpun-code shpun-code-copy',
			'click': ui.createHandlerFn(this, 'handleCopyCode', code)
		}, code || '— — — —');

		var widget = E('div', { 'class': 'shpun-widget-card' }, [

			/* Заголовок + бейдж */
			E('div', { 'class': 'shpun-widget-header' }, [
				E('div', {}, [
					E('div', { 'class': 'shpun-title' }, [ 'Shpun Router / SDN System' ]),
					E('div', { 'class': 'shpun-subtitle' }, [
						code
							? 'Статус подключения роутера к Shpun SDN System'
							: 'Подготовка роутера к подключению Shpun SDN System'
					])
				]),
				buildStatusBadge(state)
			]),

			/* Основной блок: две колонки */
			E('div', { 'class': 'shpun-card-main' }, [

				/* Левая колонка: параметры */
				E('div', { 'class': 'shpun-col-main' }, [
					E('div', { 'class': 'shpun-field' }, [
						E('div', { 'class': 'shpun-field-label' }, [ 'КОД РОУТЕРА' ]),
						E('div', { 'class': 'shpun-field-value' }, [ codeNode ])
					]),
					E('div', { 'class': 'shpun-field' }, [
						E('div', { 'class': 'shpun-field-label' }, [ 'VPN / ПОДПИСКА' ]),
						E('div', { 'class': 'shpun-field-value' }, [
							!code
								? 'ожидает генерации кода'
								: !hasSub
									? 'ожидает привязки'
									: vpnReady
										? 'подключен'
										: (err ? 'ошибка' : 'подключение…')
						])
					]),
					E('div', { 'class': 'shpun-field' }, [
						E('div', { 'class': 'shpun-field-label' }, [ 'ПРОШИВКА' ]),
						E('div', { 'class': 'shpun-field-value' }, [ fwCurrent ])
					]),
					E('div', { 'class': 'shpun-field' }, [
						E('div', { 'class': 'shpun-field-label' }, [ 'VPN IP' ]),
						E('div', { 'class': 'shpun-field-value' }, [ vpnIP ])
					])
				]),

				/* Правая колонка: QR */
				E('div', { 'class': 'shpun-col-side' }, [
					E('img', {
						'class': 'shpun-qr',
						'src': qrUrl,
						'alt': 'QR-код для добавления роутера в Shpun SDN System'
					}),
					E('div', { 'class': 'shpun-qr-caption' }, 'Наведите камеру телефона, чтобы открыть бота')
				])
			]),

			/* Кнопки в один ряд: слева тех, справа бот (под QR) */
			E('div', { 'class': 'shpun-actions' }, [
				E('div', { 'class': 'shpun-actions-left' }, [
					E('button', {
						'class': 'shpun-btn',
						'click': ui.createHandlerFn(this, 'handleRefresh')
					}, 'Обновить статус'),
					E('button', {
						'class': 'shpun-btn',
						'click': ui.createHandlerFn(this, 'handleUpdateFirmware')
					}, 'Проверить обновление прошивки')
				]),
				E('div', { 'class': 'shpun-actions-right' }, [
					E('a', {
						'class': 'shpun-btn shpun-btn-primary',
						'href': deepLink,
						'target': '_blank',
						'rel': 'noreferrer'
					}, 'Открыть бота Shpun SDN System')
				])
			]),

			/* Мини-инструкция */
			E('div', { 'class': 'shpun-hint' }, [
				!code
					? 'Дождитесь генерации кода роутера. Затем откройте бота Shpun SDN System и закажите услугу для роутеров.'
					: !hasSub
						? 'Откройте бота Shpun SDN System, закажите услугу для роутеров, затем откройте мини-приложение и привяжите этот роутер по коду. После этого роутер сам получит конфигурацию и подключится к системе.'
						: !vpnReady
							? (err
								? 'Подписка найдена, но подключиться не удалось: ' + err
								: 'Подписка найдена. Ожидаем подключение VPN, это может занять до минуты.')
							: 'Трафик роутера направляется через Shpun SDN System. При необходимости используйте кнопку обновления прошивки для получения последней версии ПО.'
			])
		]);

		this._state = state;
		return widget;
	},

	/* Клик по коду: копирование в буфер */
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
			} else {
				var input = document.createElement('input');
				input.type = 'text';
				input.value = text;
				document.body.appendChild(input);
				input.select();
				try {
					document.execCommand('copy');
					notifyOk();
				} catch (e) {
					notifyErr(e);
				}
				document.body.removeChild(input);
			}
		} catch (e) {
			notifyErr(e);
		}
	},

	/* Ручное обновление по кнопке */
	handleRefresh: function(ev) {
		if (ev)
			ev.preventDefault();

		var view = this;

		return callShpunState().then(function(st) {
			st = st || {};
			var root = view.render(st);
			var container = view.container;
			if (container && container.parentNode) {
				container.parentNode.replaceChild(root, container);
				view.container = root;
			}
		}).catch(function(err) {
			ui.addNotification(null, E('p', {}, [
				'Не удалось обновить статус Shpun Router: ',
				String(err)
			]), 'error');
		});
	},

	handleUpdateFirmware: function(ev) {
		if (ev)
			ev.preventDefault();

		return callShpunUpdate().then(function(res) {
			res = res || {};
			if (res.ok)
				ui.addNotification(null, E('p', {}, 'Проверка обновлений и авто-обновление прошивки запущены в фоне.'), 'info');
			else
				ui.addNotification(null, E('p', {}, 'Не удалось запустить обновление прошивки: ' +
					(res.error ? String(res.error) : 'неизвестная ошибка')), 'error');
		}).catch(function(err) {
			ui.addNotification(null, E('p', {}, 'Ошибка при вызове обновления прошивки: ' + String(err)), 'error');
		});
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null,

	onmount: function(node) {
		this.container = node;

		/* Спрятать заголовок секции LuCI перед нашим виджетом ([Anonymous45Class] и т.п.) */
		var prev = node.previousElementSibling;
		if (prev && prev.tagName && prev.tagName.toLowerCase() === 'h3') {
			prev.style.display = 'none';
		}

		var view = this;

		/* Автообновление статуса раз в 10 секунд */
		this._pollId = poll.add(function() {
			if (!view.container || !view.container.parentNode)
				return;

			return callShpunState().then(function(st) {
				st = st || {};
				var root = view.render(st);
				var container = view.container;
				if (container && container.parentNode) {
					container.parentNode.replaceChild(root, container);
					view.container = root;
				}
			});
		}, 10);
	},


	onunload: function() {
		if (this._pollId != null)
			poll.remove(this._pollId);
	}
});
