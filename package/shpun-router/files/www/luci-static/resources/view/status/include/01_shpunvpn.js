'use strict';
'require view';
'require rpc';
'require ui';
'require poll';

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

/* если у тебя есть отдельная функция injectStyles() — оставляем;
 * если нет, можно сделать заглушку:
 */
function injectStyles() {
	/* no-op, если стили уже подключены из CSS */
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
 *  Хелпер: спрятать заголовки LuCI над нашим виджетом
 * ========================================================== */
function hideLuCIHeader(rootNode) {
	if (!rootNode)
		return;

	var parent = rootNode.parentNode;
	if (!parent)
		return;

	var prev = rootNode.previousSibling;
	while (prev) {
		if (prev.style !== undefined)
			prev.style.display = 'none';
		prev = prev.previousSibling;
	}
}

/* ============================================================
 *  Основной view LuCI
 * ========================================================== */

return view.extend({
	load: function() {
		injectStyles();
		return callShpunState().then(function(data) {
			return data || {};
		}).catch(function(err) {
			/* чтобы виджет не падал, если ubus/шпун ещё не готов */
			return {};
		});
	},

	render: function(state) {
		state = state || {};

		var code      = (state.code || '').trim();

		/* Версии прошивки */
		var fwCurrent = (state.fw_current || '').trim();
		if (!fwCurrent)
			fwCurrent = '1.0.0';

		var fwLatest  = (state.fw_latest || '').trim();
		var hasNewFw  = fwLatest && fwLatest !== fwCurrent;

		var fwLabel = fwCurrent;
		if (hasNewFw)
			fwLabel = fwCurrent + ' (доступна ' + fwLatest + ')';

		var hasSub    = !!state.has_sub;
		var vpnReady  = !!state.vpn_ready;
		var err       = (state.vpn_error || '').trim();

		var deepLink = 'https://t.me/shpunvpn_bot';
		var qrUrl    = 'https://api.qrserver.com/v1/create-qr-code/?size=160x160&data=' +
			encodeURIComponent(deepLink);

		var codeNode = E('span', {
			'class': 'shpun-code shpun-code-copy',
			'click': ui.createHandlerFn(this, 'handleCopyCode', code)
		}, code || '— — — —');

		var widget = E('div', { 'class': 'shpun-widget-card' }, [

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

			E('div', { 'class': 'shpun-card-main' }, [

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
						E('div', { 'class': 'shpun-field-value' }, [ fwLabel ])
					])
				]),

				E('div', { 'class': 'shpun-col-side' }, [
					E('img', {
						'class': 'shpun-qr',
						'src': qrUrl,
						'alt': 'QR-код для добавления роутера в Shpun SDN System'
					}),
					E('div', { 'class': 'shpun-qr-caption' }, 'Наведите камеру телефона, чтобы открыть бота')
				])
			]),

			E('div', { 'class': 'shpun-actions' }, [
				E('div', { 'class': 'shpun-actions-left' }, [
					E('button', {
						'class': 'shpun-btn',
						'click': ui.createHandlerFn(this, 'handleRefresh')
					}, 'Обновить статус'),
					E('button', {
						'class': 'shpun-btn',
						'click': ui.createHandlerFn(this, 'handleUpdateFirmware')
					}, 'Проверить обновление прошивки'),
					E('button', {
						'class': 'shpun-btn',
						'click': ui.createHandlerFn(this, 'handleResetVpn')
					}, 'Сбросить VPN и настройки')
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
				hideLuCIHeader(root);
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

		var view = this;

		ui.addNotification(
			null,
			E('p', {}, 'Проверка обновлений запущена… Роутер связывается с сервером Shpun SDN System.'),
			'info'
		);

		return callShpunOtaCheck().then(function(res) {
			return new Promise(function(resolve) {
				window.setTimeout(resolve, 12000);
			});
		}).then(function() {
			return callShpunState();
		}).then(function(st) {
			st = st || {};

			var fwCurrent = (st.fw_current || '').trim();
			if (!fwCurrent)
				fwCurrent = '1.0.0';

			var fwLatest = (st.fw_latest || '').trim();
			var hasNew   = fwLatest && fwLatest !== fwCurrent;

			var root = view.render(st);
			var container = view.container;
			if (container && container.parentNode) {
				container.parentNode.replaceChild(root, container);
				view.container = root;
				hideLuCIHeader(root);
			}

			if (!hasNew) {
				ui.addNotification(
					null,
					E('p', {}, 'Новая версия прошивки не найдена. Установлена актуальная версия: ' + fwCurrent + '.'),
					'info'
				);
				return;
			}

			ui.showModal('Обнаружено обновление прошивки', [
				E('p', {}, [
					'Доступна новая версия прошивки Shpun Router: ',
					E('strong', {}, fwCurrent),
					' → ',
					E('strong', {}, fwLatest),
					'.'
				]),
				E('p', {}, 'Установить обновление сейчас? В процессе VPN-соединение будет перезапущено.'),
				E('div', { 'style': 'margin-top:10px; text-align:right' }, [
					E('button', {
						'class': 'btn',
						'click': function() {
							ui.hideModal();
						}
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

							callShpunOtaInstall().then(function(res) {
								window.setTimeout(function() {
									callShpunState().then(function(st2) {
										st2 = st2 || {};
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
		}).catch(function(err) {
			ui.addNotification(
				null,
				E('p', {}, 'Ошибка при проверке обновления прошивки: ' + String(err)),
				'error'
			);
		});
	},

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
					'click': function() {
						ui.hideModal();
					}
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
								return callShpunState().then(function(st) {
									st = st || {};
									var root = view.render(st);
									var container = view.container;
									if (container && container.parentNode) {
										container.parentNode.replaceChild(root, container);
										view.container = root;
										hideLuCIHeader(root);
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
				var root = view.render(st);
				var container = view.container;
				if (container && container.parentNode) {
					container.parentNode.replaceChild(root, container);
					view.container = root;
					hideLuCIHeader(root);
				}
			}).catch(function(err) {
				/* глушим ошибки, чтобы не ломать виджет */
			});
		}, 10);
	},

	onunload: function() {
		if (this._pollId != null)
			poll.remove(this._pollId);
	}
});
