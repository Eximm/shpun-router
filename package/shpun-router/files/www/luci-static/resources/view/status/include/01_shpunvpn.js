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

var callShpunResetVpn = rpc.declare({
	object: 'shpun',
	method: 'reset_vpn',
	expect: { '': {} }
});

/* ============================================================
 *  Стили виджета
 * ========================================================== */

function injectStyles() {
	if (document.getElementById('shpun-widget-style'))
		return;

	var css = ''
		/* Карточка */
		+ '.shpun-widget-card{'
		+ '  border-radius:10px;'
		+ '  padding:12px 14px 14px;'
		+ '  background:#1f2933;'
		+ '  color:#f9fafb;'
		+ '  box-shadow:0 2px 5px rgba(0,0,0,.35);'
		+ '  margin:0 0 16px;'
		+ '  display:flex;'
		+ '  flex-direction:column;'
		+ '  gap:10px;'
		+ '}'
		/* Шапка */
		+ '.shpun-widget-header{display:flex;justify-content:space-between;align-items:center;}'
		+ '.shpun-title{font-weight:600;font-size:15px;}'
		+ '.shpun-subtitle{font-size:11px;color:#d1d5db;}'
		/* Бейджи */
		+ '.shpun-badge{display:inline-flex;align-items:center;border-radius:999px;padding:2px 8px;font-size:11px;font-weight:500;}'
		+ '.shpun-badge-dot{width:8px;height:8px;border-radius:999px;margin-right:6px;}'
		+ '.shpun-badge--off{background:rgba(148,163,184,.15);color:#e5e7eb;}'
		+ '.shpun-badge--off .shpun-badge-dot{background:#6b7280;}'
		+ '.shpun-badge--warn{background:rgba(250,204,21,.15);color:#facc15;}'
		+ '.shpun-badge--warn .shpun-badge-dot{background:#facc15;}'
		+ '.shpun-badge--ok{background:rgba(34,197,94,.2);color:#bbf7d0;}'
		+ '.shpun-badge--ok .shpun-badge-dot{background:#22c55e;}'
		+ '.shpun-badge--err{background:rgba(248,113,113,.2);color:#fecaca;}'
		+ '.shpun-badge--err .shpun-badge-dot{background:#f87171;}'
		/* Основной блок: две колонки */
		+ '.shpun-card-main{'
		+ '  display:flex;'
		+ '  flex-wrap:nowrap;'
		+ '  gap:32px;'
		+ '  align-items:flex-start;'
		+ '  justify-content:space-between;'
		+ '  margin-top:8px;'
		+ '}'
		/* Левая колонка */
		+ '.shpun-col-main{'
		+ '  flex:0 0 auto;'
		+ '  min-width:260px;'
		+ '  display:flex;'
		+ '  flex-direction:column;'
		+ '  gap:8px;'
		+ '  margin-top:14px;'
		+ '}'
		/* Правая колонка с QR */
		+ '.shpun-col-side{'
		+ '  flex:0 0 auto;'
		+ '  display:flex;'
		+ '  flex-direction:column;'
		+ '  align-items:center;'
		+ '  gap:10px;'
		+ '  margin-top:14px;'
		+ '  margin-right:18px;'
		+ '  margin-left:auto;'
		+ '  width:250px;'
		+ '}'
		/* Поля слева */
		+ '.shpun-field{min-width:130px;margin-bottom:6px;}'
		+ '.shpun-field-label{font-size:11px;color:#9ca3af;text-transform:uppercase;letter-spacing:.04em;margin-bottom:2px;}'
		+ '.shpun-field-value{font-size:13px;font-weight:500;line-height:1.35;}'
		+ '.shpun-code{font-family:monospace;font-size:16px;font-weight:700;letter-spacing:.12em;}'
		+ '.shpun-code-copy{cursor:pointer;border-bottom:1px dashed rgba(148,163,184,.7);}'
		+ '.shpun-code-copy:hover{color:#bae6fd;border-bottom-color:#38bdf8;}'
		/* Кнопки */
		+ '.shpun-actions{display:flex;flex-wrap:wrap;gap:6px;margin-top:8px;align-items:center;}'
		+ '.shpun-actions-left{display:flex;flex-wrap:wrap;gap:6px;flex:1 1 auto;}'
		+ '.shpun-actions-right{'
		+ '  display:flex;'
		+ '  justify-content:center;'
		+ '  flex:0 0 auto;'
		+ '  margin-left:auto;'
		+ '  margin-right:18px;'
		+ '  width:250px;'
		+ '}'
		+ '.shpun-btn{border-radius:999px;border:1px solid rgba(148,163,184,.6);background:rgba(15,23,42,.8);color:#e5e7eb;padding:4px 10px;font-size:11px;cursor:pointer;text-decoration:none;display:inline-flex;align-items:center;gap:4px;}'
		+ '.shpun-btn:hover{background:rgba(31,41,55,.95);}'
		/* Подсказка в рамке */
		+ '.shpun-hint-box{margin-top:6px;padding:6px 8px;border-radius:8px;border:1px solid rgba(148,163,184,.45);background:rgba(15,23,42,.85);font-size:11px;color:#9ca3af;}'
		/* QR */
		+ '.shpun-qr{border:1px solid rgba(148,163,184,.6);border-radius:8px;padding:4px;background:#0b1120;max-width:140px;height:auto;display:block;}'
		+ '.shpun-qr-caption{font-size:11px;color:#9ca3af;text-align:center;}'
		/* Бейдж новой версии */
		+ '.shpun-fw-badge{display:inline-block;margin-left:4px;padding:1px 6px;border-radius:999px;font-size:10px;background:rgba(56,189,248,.15);color:#7dd3fc;box-shadow:0 0 0 0 rgba(56,189,248,.5);animation:shpun-fw-pulse 1.6s.ease-in-out infinite;}'
		+ '@keyframes shpun-fw-pulse{0%{box-shadow:0 0 0 0 rgba(56,189,248,.5);}70%{box-shadow:0 0 0 6px rgba(56,189,248,0);}100%{box-shadow:0 0 0 0 rgba(56,189,248,0);}}';

	var style = document.createElement('style');
	style.id = 'shpun-widget-style';
	style.type = 'text/css';
	style.appendChild(document.createTextNode(css));
	document.head.appendChild(style);
}

/* ============================================================
 *  Бейдж статуса
 * ========================================================== */

function buildStatusBadge(state) {
	var hasCode = !!(state.code && state.code.trim().length > 0);
	var hasSub  = !!state.has_sub;
	var ready   = !!state.vpn_ready;
	var err     = (state.vpn_error || '').trim();

	var cls, text;

	if (err) {
		cls  = 'shpun-badge shpun-badge--err';
		text = 'Ошибка: ' + err;
	}
	else if (!hasCode) {
		cls  = 'shpun-badge shpun-badge--off';
		text = 'Код роутера ещё не создан';
	}
	else if (hasCode && !hasSub) {
		cls  = 'shpun-badge shpun-badge--warn';
		text = 'Ожидает привязки в Shpun SDN System';
	}
	else if (hasCode && hasSub && !ready) {
		cls  = 'shpun-badge shpun-badge--warn';
		text = 'Подписка найдена, подключаемся…';
	}
	else if (hasCode && hasSub && ready) {
		cls  = 'shpun-badge shpun-badge--ok';
		text = 'VPN подключен';
	}
	else {
		cls  = 'shpun-badge shpun-badge--off';
		text = 'Ожидает кода';
	}

	return E('span', { 'class': cls }, [
		E('span', { 'class': 'shpun-badge-dot' }),
		text
	]);
}

/* ============================================================
 *  Спрятать стандартный заголовок LuCI
 * ========================================================== */

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

/* ============================================================
 *  Основной view
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
		this._state = state;

		var code = (state.code || '').trim();

		var fwCurrentRaw = (state.fw_current || '').trim();
		var fwCurrentDisplay = fwCurrentRaw || '—';

		var fwLatest = (state.fw_latest || '').trim();
		var hasNewFw = !!(fwLatest && fwCurrentRaw && fwLatest !== fwCurrentRaw);

		var hasSub   = !!state.has_sub;
		var vpnReady = !!state.vpn_ready;
		var err      = (state.vpn_error || '').trim();

		var deepLink = 'https://t.me/shpunvpn_bot';
		var qrUrl    = 'https://api.qrserver.com/v1/create-qr-code/?size=160x160&data=' +
			encodeURIComponent(deepLink);

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
		} else {
			fwValue = fwCurrentDisplay;
		}

		var updateBtnLabel = hasNewFw
			? ('Установить обновление ' + fwLatest)
			: 'Проверить обновление прошивки';

		var hintText =
			!code
				? 'Дождитесь генерации кода роутера. Затем откройте бота Shpun SDN System и закажите услугу для роутеров.'
				: !hasSub
					? 'Откройте бота Shpun SDN System, закажите услугу для роутеров, затем откройте мини-приложение и привяжите этот роутер по коду. После этого роутер сам получит конфигурацию и подключится к системе.'
					: !vpnReady
						? (err
							? 'Подписка найдена, но подключиться не удалось: ' + err
							: 'Подписка найдена. Ожидаем подключение VPN, это может занять до минуты.')
						: 'Трафик роутера направляется через Shpun SDN System. При необходимости используйте обновление прошивки для получения последней версии ПО.';

		var widget = E('div', { 'class': 'shpun-widget-card' }, [

			/* Шапка */
			E('div', { 'class': 'shpun-widget-header' }, [
				E('div', {}, [
					E('div', { 'class': 'shpun-title' }, 'Shpun Router / SDN System'),
					E('div', { 'class': 'shpun-subtitle' }, [
						code
							? 'Статус подключения роутера к Shpun SDN System'
							: 'Подготовка роутера к подключению Shpun SDN System'
					])
				]),
				buildStatusBadge(state)
			]),

			/* Подсказка */
			E('div', { 'class': 'shpun-hint-box' }, hintText),

			/* Две колонки */
			E('div', { 'class': 'shpun-card-main' }, [
				E('div', { 'class': 'shpun-col-main' }, [
					E('div', { 'class': 'shpun-field' }, [
						E('div', { 'class': 'shpun-field-label' }, 'КОД РОУТЕРА'),
						E('div', { 'class': 'shpun-field-value' }, [ codeNode ])
					]),
					E('div', { 'class': 'shpun-field' }, [
						E('div', { 'class': 'shpun-field-label' }, 'VPN / ПОДПИСКА'),
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
						E('div', { 'class': 'shpun-field-label' }, 'ПРОШИВКА'),
						E('div', { 'class': 'shpun-field-value' }, [ fwValue ])
					])
				]),

				/* Правая колонка: QR */
				E('div', { 'class': 'shpun-col-side' }, [
					E('a', {
						'href': deepLink,
						'target': '_blank',
						'rel': 'noreferrer'
					}, [
						E('img', {
							'class': 'shpun-qr',
							'src': qrUrl,
							'alt': 'QR-код для добавления роутера в Shpun SDN System'
						})
					]),
					E('div', { 'class': 'shpun-qr-caption' },
						'Наведите камеру телефона, чтобы открыть бота')
				])
			]),

			/* Кнопки */
			E('div', { 'class': 'shpun-actions' }, [
				E('div', { 'class': 'shpun-actions-left' }, [
					E('button', {
						'class': 'shpun-btn',
						'click': ui.createHandlerFn(this, 'handleRefresh')
					}, 'Обновить статус'),
					E('button', {
						'class': 'shpun-btn',
						'click': ui.createHandlerFn(this, 'handleUpdateFirmware')
					}, updateBtnLabel),
					E('button', {
						'class': 'shpun-btn',
						'click': ui.createHandlerFn(this, 'handleResetVpn')
					}, 'Сбросить VPN и настройки')
				]),
				E('div', { 'class': 'shpun-actions-right' }, [
					E('a', {
						'class': 'shpun-btn',
						'href': deepLink,
						'target': '_blank',
						'rel': 'noreferrer'
					}, 'Открыть бота')
				])
			])
		]);

		return widget;
	},

	/* Копирование кода */
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

	/* Обновить статус */
	handleRefresh: function(ev) {
		if (ev)
			ev.preventDefault();

		var view = this;

		return callShpunState().then(function(st) {
			st = st || {};
			view._state = st;
			var root = view.render(st);
			var container = view.container;
			if (container && container.parentNode) {
				container.parentNode.replaceChild(root, container);
				view.container = root;
				hideLuCIHeader(root);
			}
		}).catch(function(err) {
			ui.addNotification(null, E('p', {}, [
				'Не удалось обновить статус Shpun Router: ',
				String(err)
			]), 'error');
		});
	},

	/* Проверка/установка обновления */
	handleUpdateFirmware: function(ev) {
		if (ev)
			ev.preventDefault();

		var view = this;
		var st = view._state || {};

		var fwCurrentRaw = (st.fw_current || '').trim();
		var fwLatest = (st.fw_latest || '').trim();
		var hasNew   = !!(fwLatest && fwCurrentRaw && fwLatest !== fwCurrentRaw);
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
				E('p', {}, 'Установить обновление сейчас? В процессе VPN-соединение будет перезапущено.'),
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
									callShpunState().then(function(st2) {
										st2 = st2 || {};
										view._state = st2;
										var root2 = view.render(st2);
										var container2 = view.container;
										if (container2 && container2.parentNode) {
											container2.parentNode.replaceChild(root2, container2);
											view.container = root2;
											hideLuCIHeader(root2);
										}
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
			E('p', {}, 'Проверка обновлений запущена… Роутер связывается с сервером Shpun SDN System.'),
			'info'
		);

		return callShpunOtaCheck().then(function() {
			return new Promise(function(resolve) {
				window.setTimeout(resolve, 12000);
			});
		}).then(function() {
			return callShpunState();
		}).then(function(st2) {
			st2 = st2 || {};
			view._state = st2;

			var fwCurRaw = (st2.fw_current || '').trim();
			var fwLat = (st2.fw_latest || '').trim();
			var fwCurDisplay = fwCurRaw || '—';
			var hasNewNow = !!(fwLat && fwCurRaw && fwLat !== fwCurRaw);

			var root = view.render(st2);
			var container = view.container;
			if (container && container.parentNode) {
				container.parentNode.replaceChild(root, container);
				view.container = root;
				hideLuCIHeader(root);
			}

			if (!hasNewNow) {
				ui.addNotification(
					null,
					E('p', {}, 'Новая версия прошивки не найдена. Установлена актуальная версия: ' + fwCurDisplay + '.'),
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

	/* Сброс VPN */
	handleResetVpn: function(ev) {
		if (ev)
			ev.preventDefault();

		var view = this;

		ui.showModal('Сброс VPN и настроек', [
			E('p', {}, [
				'Вы действительно хотите полностью сбросить VPN-конфигурацию Shpun Router ',
				'и вернуть устройство в состояние после установки пакета? ',
				'Будет сгенерирован новый код роутера, текущая привязка в боте и конфигурация VPN будут потеряны.'
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
									E('p', {}, 'VPN-конфигурация сброшена. Роутер переведён в режим первоначальной настройки (будет создан новый код).'),
									'info'
								);
								return callShpunState().then(function(st2) {
									st2 = st2 || {};
									view._state = st2;
									var root2 = view.render(st2);
									var container2 = view.container;
									if (container2 && container2.parentNode) {
										container2.parentNode.replaceChild(root2, container2);
										view.container = root2;
										hideLuCIHeader(root2);
									}
								});
							}
							else {
								ui.addNotification(
									null,
									E('p', {}, 'Не удалось сбросить VPN-настройки: ' +
										(res.error ? String(res.error) : 'неизвестная ошибка')),
									'error'
								);
							}
						}).catch(function(err) {
							ui.addNotification(
								null,
								E('p', {}, 'Ошибка при вызове сброса VPN-настроек: ' + String(err)),
								'error'
							);
						});
					}
				}, 'Сбросить VPN')
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

			return callShpunState().then(function(st) {
				st = st || {};
				view._state = st;
				var root = view.render(st);
				var container = view.container;
				if (container && container.parentNode) {
					container.parentNode.replaceChild(root, container);
					view.container = root;
					hideLuCIHeader(root);
				}
			});
		}, 10);
	},

	onunload: function() {
		if (this._pollId != null)
			poll.remove(this._pollId);
	}
});
