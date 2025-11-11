'use strict';
'require view';
'require ui';

return view.extend({
    load: function() {
        // Если потом понадобится что-то грузить через rpc, можно использовать здесь
        return Promise.resolve();
    },

    render: function() {
        var base = L.env.cgi_base || '';

        var root = E('div', { id: 'shpun-wizard', 'class': 'cbi-section' }, [
            E('style', {}, [String.raw`
#shpun-wizard { max-width: 720px; margin: 0 auto; }
#shpun-wizard h2 { margin-bottom: 1rem; }
#shpun-wizard .step { display: none; }
#shpun-wizard .step.active { display: block; }
#shpun-wizard .step-card {
  border: 1px solid #ddd;
  border-radius: 6px;
  padding: 16px;
  margin-bottom: 16px;
  background: #fff;
}
#shpun-wizard .btn-row {
  margin-top: 16px;
  display: flex;
  gap: 8px;
}
#shpun-error {
  display: none;
  margin-bottom: 12px;
  padding: 8px 10px;
  border-radius: 4px;
  background: #ffebee;
  color: #b71c1c;
  font-size: 0.9em;
}
.shpun-spinner {
  width: 20px;
  height: 20px;
  border: 3px solid #ccc;
  border-top-color: #2e7dff;
  border-radius: 50%;
  display: inline-block;
  vertical-align: middle;
  animation: shpun-spin 0.7s linear infinite;
  margin-left: 8px;
}
@keyframes shpun-spin { to { transform: rotate(360deg); } }
#vpn-status { margin-top: 8px; }
#qr-img {
  margin-top: 10px;
  border: 1px solid #ddd;
  border-radius: 4px;
}
#router-code {
  font-weight: bold;
  font-size: 1.2em;
}
.shpun-field { margin-bottom: 10px; }
.shpun-field label {
  display: block;
  margin-bottom: 4px;
  font-weight: 600;
}
.shpun-field input[type="text"],
.shpun-field input[type="password"] {
  width: 100%;
  max-width: 360px;
}
.shpun-muted { font-size: 0.9em; color: #666; }
`]),
            E('h2', {}, [_('Мастер настройки Shpun Router')]),
            E('p', { 'class': 'shpun-muted' }, [
                _('Пройдите три шага: настройте подключение к интернету (WAN), Wi-Fi и привяжите роутер к VPN через Telegram.')
            ]),

            E('div', { id: 'shpun-error' }),

            // Шаг 1
            E('div', { 'class': 'step step-1 step-card active' }, [
                E('h3', {}, [_('Шаг 1: Подключение к интернету (WAN)')]),
                E('p', { 'class': 'shpun-muted' }, [
                    _('Выберите, как ваш роутер подключается к интернету. Если вы не уверены — оставьте DHCP (по умолчанию).')
                ]),
                E('div', { 'class': 'shpun-field' }, [
                    E('label', {}, [_('Тип подключения WAN:')]),
                    E('label', {}, [
                        E('input', { type: 'radio', name: 'wan_proto', value: 'dhcp', checked: 'checked' }), ' ',
                        _('Получить адрес автоматически (DHCP)')
                    ]),
                    E('br'),
                    E('label', {}, [
                        E('input', { type: 'radio', name: 'wan_proto', value: 'pppoe' }), ' ',
                        _('PPPoE (логин/пароль от провайдера)')
                    ])
                ]),
                E('div', { id: 'pppoe-fields', style: 'display:none; margin-top:8px;' }, [
                    E('div', { 'class': 'shpun-field' }, [
                        E('label', { 'for': 'pppoe-user' }, [_('PPPoE логин:')]),
                        E('input', { id: 'pppoe-user', type: 'text', autocomplete: 'off' })
                    ]),
                    E('div', { 'class': 'shpun-field' }, [
                        E('label', { 'for': 'pppoe-pass' }, [_('PPPoE пароль:')]),
                        E('input', { id: 'pppoe-pass', type: 'password', autocomplete: 'off' })
                    ]),
                    E('p', { 'class': 'shpun-muted' }, [
                        _('Эти данные вы можете найти в договоре с провайдером или личном кабинете.')
                    ])
                ]),
                E('div', { 'class': 'btn-row' }, [
                    E('button', {
                        id: 'wan-apply',
                        'class': 'btn cbi-button cbi-button-save',
                        'data-busy-text': _('Применяем…'),
                        type: 'button'
                    }, [_('Сохранить и далее')]),
                    E('button', {
                        id: 'wan-skip',
                        'class': 'btn cbi-button cbi-button-reset',
                        type: 'button'
                    }, [_('Пропустить шаг')])
                ])
            ]),

            // Шаг 2
            E('div', { 'class': 'step step-2 step-card' }, [
                E('h3', {}, [_('Шаг 2: Настройка Wi-Fi')]),
                E('p', { 'class': 'shpun-muted' }, [
                    _('Укажите имя Wi-Fi сети и, при необходимости, пароль доступа.')
                ]),
                E('div', { 'class': 'shpun-field' }, [
                    E('label', { 'for': 'wifi-ssid' }, [_('Имя Wi-Fi сети (SSID):')]),
                    E('input', { id: 'wifi-ssid', type: 'text', value: 'Shpun-Router' })
                ]),
                E('div', { 'class': 'shpun-field' }, [
                    E('label', { 'for': 'wifi-key' }, [_('Пароль Wi-Fi (можно оставить пустым):')]),
                    E('input', { id: 'wifi-key', type: 'text' }),
                    E('p', { 'class': 'shpun-muted' }, [
                        _('Если оставить поле пустым — сеть будет открытой (без пароля).')
                    ])
                ]),
                E('div', { 'class': 'btn-row' }, [
                    E('button', {
                        id: 'wifi-apply',
                        'class': 'btn cbi-button cbi-button-save',
                        'data-busy-text': _('Применяем…'),
                        type: 'button'
                    }, [_('Сохранить и далее')]),
                    E('button', {
                        id: 'wifi-skip',
                        'class': 'btn cbi-button cbi-button-reset',
                        type: 'button'
                    }, [_('Пропустить шаг')])
                ])
            ]),

            // Шаг 3
            E('div', { 'class': 'step step-3 step-card' }, [
                E('h3', {}, [_('Шаг 3: Привязка к Shpun VPN')]),
                E('p', {}, [
                    _('Отсканируйте QR-код или используйте код роутера, чтобы привязать его к вашей VPN-подписке через Telegram-бота.')
                ]),
                E('div', { 'class': 'shpun-field' }, [
                    E('label', {}, [_('Код вашего роутера:')]),
                    E('div', { id: 'router-code' }, ['—']),
                    E('p', { 'class': 'shpun-muted' }, [
                        _('Этот код нужно ввести в боте Shpun VPN или перейти по ссылке с QR-кода.')
                    ])
                ]),
                E('div', { 'class': 'shpun-field' }, [
                    E('label', {}, [_('QR-код для Telegram:')]),
                    E('br'),
                    E('a', { id: 'tg-link', href: '#', target: '_blank' }, [
                        E('img', {
                            id: 'qr-img',
                            src: '',
                            alt: 'QR-код для привязки роутера',
                            style: 'display:none; width:180px; height:180px;'
                        })
                    ]),
                    E('p', { 'class': 'shpun-muted' }, [
                        _('Нажмите на QR-код, чтобы открыть бота Shpun VPN на этом устройстве.')
                    ])
                ]),
                E('div', { id: 'vpn-status', 'class': 'shpun-field' }, [
                    E('span', { id: 'vpn-status-text' }, [_('Ожидаем привязку…')]),
                    E('span', { id: 'vpn-spinner', 'class': 'shpun-spinner', style: 'display:none;' })
                ]),
                E('div', { 'class': 'btn-row' }, [
                    E('button', {
                        id: 'finish-btn',
                        'class': 'btn cbi-button cbi-button-save',
                        type: 'button'
                    }, [_('Завершить и перейти к статусу')])
                ])
            ])
        ]);

        /* ===== вспомогательные функции ===== */

        function showStep(n) {
            root.querySelectorAll('.step').forEach(function(el, i) {
                el.classList.toggle('active', i === (n - 1));
            });
        }

        function showError(msg) {
            var box = root.querySelector('#shpun-error');
            if (box) {
                box.textContent = msg;
                box.style.display = 'block';
            }
        }

        function setBusy(btn, busy) {
            if (!btn) return;
            btn.disabled = !!busy;
            if (busy) {
                btn.dataset.origText = btn.dataset.origText || btn.textContent;
                btn.textContent = btn.dataset.busyText || _('Подождите…');
            } else if (btn.dataset.origText) {
                btn.textContent = btn.dataset.origText;
            }
        }

        /* ===== логика шагов ===== */

        // WAN
        var wanApplyBtn = root.querySelector('#wan-apply');
        var wanSkipBtn  = root.querySelector('#wan-skip');

        if (wanApplyBtn) {
            wanApplyBtn.onclick = function() {
                var protoInput = root.querySelector('input[name="wan_proto"]:checked');
                if (!protoInput) {
                    showError(_('Выберите тип подключения WAN'));
                    return;
                }

                var proto = protoInput.value;
                var data = new URLSearchParams();
                data.set('proto', proto);

                if (proto === 'pppoe') {
                    var userEl = root.querySelector('#pppoe-user');
                    var passEl = root.querySelector('#pppoe-pass');
                    var user = userEl ? userEl.value : '';
                    var pass = passEl ? passEl.value : '';

                    if (!user || !pass) {
                        showError(_('Для PPPoE необходимо указать логин и пароль'));
                        return;
                    }

                    data.set('user', user.trim());
                    data.set('pass', pass);
                }

                setBusy(wanApplyBtn, true);
                fetch(base + '/admin/network/shpun/api/apply_wan', {
                    method: 'POST',
                    headers: {
                        'Content-Type': 'application/x-www-form-urlencoded',
                        'X-Requested-With': 'XMLHttpRequest'
                    },
                    body: data
                })
                .then(function(r) {
                    if (!r.ok) throw new Error('HTTP ' + r.status);
                    return r.json();
                })
                .then(function() {
                    showStep(2);
                })
                .catch(function(e) {
                    showError(_('Не удалось применить настройки WAN: ') + e.message);
                })
                .finally(function() {
                    setBusy(wanApplyBtn, false);
                });
            };
        }

        if (wanSkipBtn) {
            wanSkipBtn.onclick = function() {
                showStep(2);
            };
        }

        // переключение PPPoE блока
        root.querySelectorAll('input[name="wan_proto"]').forEach(function(radio) {
            radio.addEventListener('change', function() {
                var block = root.querySelector('#pppoe-fields');
                if (!block) return;
                block.style.display = (this.value === 'pppoe') ? 'block' : 'none';
            });
        });

        // Wi-Fi
        var wifiApplyBtn = root.querySelector('#wifi-apply');
        var wifiSkipBtn  = root.querySelector('#wifi-skip');

        if (wifiApplyBtn) {
            wifiApplyBtn.onclick = function() {
                var ssidEl = root.querySelector('#wifi-ssid');
                var keyEl  = root.querySelector('#wifi-key');
                var ssid = ssidEl ? ssidEl.value : '';
                var key  = keyEl ? keyEl.value : '';

                if (!ssid.trim()) {
                    showError(_('SSID не может быть пустым'));
                    return;
                }

                var data = new URLSearchParams();
                data.set('ssid', ssid.trim());
                data.set('key', key);

                setBusy(wifiApplyBtn, true);
                fetch(base + '/admin/network/shpun/api/apply_wifi', {
                    method: 'POST',
                    headers: {
                        'Content-Type': 'application/x-www-form-urlencoded',
                        'X-Requested-With': 'XMLHttpRequest'
                    },
                    body: data
                })
                .then(function(r) {
                    if (!r.ok) throw new Error('HTTP ' + r.status);
                    return r.json();
                })
                .then(function() {
                    showStep(3);
                })
                .catch(function(e) {
                    showError(_('Не удалось применить настройки Wi-Fi: ') + e.message);
                })
                .finally(function() {
                    setBusy(wifiApplyBtn, false);
                });
            };
        }

        if (wifiSkipBtn) {
            wifiSkipBtn.onclick = function() {
                showStep(3);
            };
        }

        // Кнопка "Завершить"
        var finishBtn = root.querySelector('#finish-btn');
        if (finishBtn) {
            finishBtn.onclick = function() {
                window.location.href = base + '/admin/status/overview';
            };
        }

        // Опрос состояния VPN/кода/QR
        function updateState(delay) {
            if (typeof delay === 'number' && delay > 0) {
                window.setTimeout(function() { updateState(); }, delay);
                return;
            }

            var spinner = root.querySelector('#vpn-spinner');
            var st      = root.querySelector('#vpn-status-text');

            fetch(base + '/admin/network/shpun/api/state', {
                method: 'GET',
                headers: { 'X-Requested-With': 'XMLHttpRequest' }
            })
            .then(function(r) {
                if (!r.ok) throw new Error('HTTP ' + r.status);
                return r.json();
            })
            .then(function(d) {
                if (d.code) {
                    var codeText = root.querySelector('#router-code');
                    if (codeText) codeText.textContent = d.code;

                    var botUsername = 'shpunvpn_bot';
                    var tgUrl = 'https://t.me/' + botUsername +
                                '?start=router_' + encodeURIComponent(d.code);
                    var qrUrl = 'https://api.qrserver.com/v1/create-qr-code/?size=180x180&data=' +
                                encodeURIComponent(tgUrl);

                    var img = root.querySelector('#qr-img');
                    if (img) {
                        if (img.src !== qrUrl) img.src = qrUrl;
                        img.style.display = 'block';
                    }
                    var linkEl = root.querySelector('#tg-link');
                    if (linkEl) linkEl.href = tgUrl;
                }

                if (st && spinner) {
                    if (!d.has_sub) {
                        st.textContent = _('Ожидаем привязку…');
                        spinner.style.display = 'none';
                        updateState(5000);
                    } else if (d.has_sub && !d.vpn_ready) {
                        st.textContent = _('Получаем настройки и запускаем VPN…');
                        spinner.style.display = 'inline-block';
                        updateState(3000);
                    } else if (d.has_sub && d.vpn_ready) {
                        st.textContent = _('VPN настроен и работает ✅');
                        spinner.style.display = 'none';
                    }
                } else if (!d.has_sub) {
                    updateState(5000);
                }
            })
            .catch(function() {
                if (root.querySelector('#vpn-spinner')) {
                    root.querySelector('#vpn-spinner').style.display = 'none';
                }
                updateState(8000);
            });
        }

        showStep(1);
        updateState();

        return root;
    }
});
