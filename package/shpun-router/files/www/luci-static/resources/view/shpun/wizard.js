'use strict';
'require view';
'require request';

return view.extend({
    load: function() {
        return Promise.resolve();
    },

    render: function() {
        const root = E('div', { id: 'shpun-wizard', 'class': 'cbi-section' }, [
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

            /* === Шаг 1: WAN === */
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
                    ]),
                    E('br'),
                    E('label', {}, [
                        E('input', { type: 'radio', name: 'wan_proto', value: 'static' }), ' ',
                        _('Статический IP (Static IP)')
                    ]),
                    E('br'),
                    E('label', {}, [
                        E('input', { type: 'radio', name: 'wan_proto', value: 'l2tp' }), ' ',
                        _('L2TP (логин/пароль + сервер)')
                    ])
                ]),

                /* PPPoE */
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

                /* Static IP */
                E('div', { id: 'static-fields', style: 'display:none; margin-top:8px;' }, [
                    E('div', { 'class': 'shpun-field' }, [
                        E('label', { 'for': 'static-ip' }, [_('IP-адрес:')]),
                        E('input', { id: 'static-ip', type: 'text', placeholder: '192.168.0.2' })
                    ]),
                    E('div', { 'class': 'shpun-field' }, [
                        E('label', { 'for': 'static-mask' }, [_('Маска подсети:')]),
                        E('input', { id: 'static-mask', type: 'text', placeholder: '255.255.255.0' })
                    ]),
                    E('div', { 'class': 'shpun-field' }, [
                        E('label', { 'for': 'static-gw' }, [_('Шлюз (Gateway):')]),
                        E('input', { id: 'static-gw', type: 'text', placeholder: '192.168.0.1' })
                    ]),
                    E('div', { 'class': 'shpun-field' }, [
                        E('label', { 'for': 'static-dns' }, [_('DNS-сервер (можно оставить пустым):')]),
                        E('input', { id: 'static-dns', type: 'text', placeholder: '1.1.1.1' })
                    ]),
                    E('p', { 'class': 'shpun-muted' }, [
                        _('Все параметры вы берёте у провайдера. Если что-то не знаете — лучше используйте DHCP.')
                    ])
                ]),

                /* L2TP */
                E('div', { id: 'l2tp-fields', style: 'display:none; margin-top:8px;' }, [
                    E('div', { 'class': 'shpun-field' }, [
                        E('label', { 'for': 'l2tp-server' }, [_('Адрес L2TP-сервера:')]),
                        E('input', { id: 'l2tp-server', type: 'text', placeholder: 'vpn.provider.ru' })
                    ]),
                    E('div', { 'class': 'shpun-field' }, [
                        E('label', { 'for': 'l2tp-user' }, [_('L2TP логин:')]),
                        E('input', { id: 'l2tp-user', type: 'text' })
                    ]),
                    E('div', { 'class': 'shpun-field' }, [
                        E('label', { 'for': 'l2tp-pass' }, [_('L2TP пароль:')]),
                        E('input', { id: 'l2tp-pass', type: 'password' })
                    ]),
                    E('p', { 'class': 'shpun-muted' }, [
                        _('Используется провайдерами, где вы подключаетесь к VPN-серверу L2TP.')
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

            /* === Шаг 2: Wi-Fi === */
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

            /* === Шаг 3: VPN === */
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

        /* === Вспомогательные функции === */

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

        function clearError() {
            var box = root.querySelector('#shpun-error');
            if (box) {
                box.style.display = 'none';
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

        function updateWanFields(proto) {
            var pppoe = root.querySelector('#pppoe-fields');
            var stat  = root.querySelector('#static-fields');
            var l2tp  = root.querySelector('#l2tp-fields');

            if (pppoe) pppoe.style.display = (proto === 'pppoe') ? 'block' : 'none';
            if (stat)  stat.style.display  = (proto === 'static') ? 'block' : 'none';
            if (l2tp)  l2tp.style.display  = (proto === 'l2tp') ? 'block' : 'none';
        }

        function handleApiResponse(res) {
            if (!res || res.status !== 200) {
                throw new Error(_('Ошибка сервера: ') + (res ? res.status : 'нет ответа'));
            }
            
            return res.text().then(function(text) {
                // Пытаемся распарсить JSON
                try {
                    if (text) {
                        return JSON.parse(text);
                    }
                    return {};
                } catch (e) {
                    console.error('Failed to parse JSON:', e, 'Response:', text.substring(0, 200));
                    
                    // Если это HTML страница, это ошибка
                    if (text.trim().startsWith('<!DOCTYPE') || text.trim().startsWith('<html')) {
                        throw new Error(_('Сервер вернул HTML вместо данных. Проверьте настройки API.'));
                    }
                    
                    // Если это пустой ответ, считаем успехом
                    if (!text.trim()) {
                        return { success: true };
                    }
                    
                    throw new Error(_('Некорректный ответ от сервера: ') + text.substring(0, 100));
                }
            });
        }

        /* === Логика WAN === */

        var wanApplyBtn = root.querySelector('#wan-apply');
        var wanSkipBtn  = root.querySelector('#wan-skip');

        // Стартовое состояние
        updateWanFields('dhcp');

        root.querySelectorAll('input[name="wan_proto"]').forEach(function(r) {
            r.addEventListener('change', function() {
                clearError();
                updateWanFields(this.value);
            });
        });

        if (wanApplyBtn) {
            wanApplyBtn.onclick = function() {
                clearError();
                var protoInput = root.querySelector('input[name="wan_proto"]:checked');
                if (!protoInput) {
                    showError(_('Выберите тип подключения WAN'));
                    return;
                }

                var proto = protoInput.value;
                var data = { proto: proto };

                if (proto === 'pppoe') {
                    var user = (root.querySelector('#pppoe-user') || {}).value || '';
                    var pass = (root.querySelector('#pppoe-pass') || {}).value || '';

                    if (!user || !pass) {
                        showError(_('Для PPPoE необходимо указать логин и пароль'));
                        return;
                    }

                    data.user = user.trim();
                    data.pass = pass;
                }
                else if (proto === 'static') {
                    var ip  = (root.querySelector('#static-ip')   || {}).value || '';
                    var msk = (root.querySelector('#static-mask') || {}).value || '';
                    var gw  = (root.querySelector('#static-gw')   || {}).value || '';
                    var dns = (root.querySelector('#static-dns')  || {}).value || '';

                    if (!ip.trim() || !msk.trim() || !gw.trim()) {
                        showError(_('Для статического IP необходимо указать IP, маску и шлюз'));
                        return;
                    }

                    data.ipaddr  = ip.trim();
                    data.netmask = msk.trim();
                    data.gateway = gw.trim();
                    if (dns.trim())
                        data.dns = dns.trim();
                }
                else if (proto === 'l2tp') {
                    var srv  = (root.querySelector('#l2tp-server') || {}).value || '';
                    var user2 = (root.querySelector('#l2tp-user')   || {}).value || '';
                    var pass2 = (root.querySelector('#l2tp-pass')   || {}).value || '';

                    if (!srv.trim() || !user2.trim() || !pass2) {
                        showError(_('Для L2TP необходимо указать сервер, логин и пароль'));
                        return;
                    }

                    data.server = srv.trim();
                    data.user   = user2.trim();
                    data.pass   = pass2;
                }

                setBusy(wanApplyBtn, true);
                
                request.post(L.url('admin/network/shpun/api/apply_wan'), data)
                    .then(handleApiResponse)
                    .then(function(result) {
                        console.log('WAN settings applied:', result);
                        showStep(2);
                    })
                    .catch(function(e) {
                        console.error('WAN apply error:', e);
                        showError(_('Не удалось применить настройки WAN: ') + e.message);
                    })
                    .finally(function() {
                        setBusy(wanApplyBtn, false);
                    });
            };
        }

        if (wanSkipBtn) {
            wanSkipBtn.onclick = function() {
                clearError();
                showStep(2);
            };
        }

        /* === Логика Wi-Fi === */

        var wifiApplyBtn = root.querySelector('#wifi-apply');
        var wifiSkipBtn  = root.querySelector('#wifi-skip');

        if (wifiApplyBtn) {
            wifiApplyBtn.onclick = function() {
                clearError();
                var ssid = (root.querySelector('#wifi-ssid') || {}).value || '';
                var key  = (root.querySelector('#wifi-key')  || {}).value || '';

                if (!ssid.trim()) {
                    showError(_('SSID не может быть пустым'));
                    return;
                }

                var data = {
                    ssid: ssid.trim(),
                    key:  key
                };

                setBusy(wifiApplyBtn, true);
                request.post(L.url('admin/network/shpun/api/apply_wifi'), data)
                    .then(handleApiResponse)
                    .then(function(result) {
                        console.log('WiFi settings applied:', result);
                        showStep(3);
                    })
                    .catch(function(e) {
                        console.error('WiFi apply error:', e);
                        showError(_('Не удалось применить настройки Wi-Fi: ') + e.message);
                    })
                    .finally(function() {
                        setBusy(wifiApplyBtn, false);
                    });
            };
        }

        if (wifiSkipBtn) {
            wifiSkipBtn.onclick = function() {
                clearError();
                showStep(3);
            };
        }

        /* === Кнопка "Завершить" === */

        var finishBtn = root.querySelector('#finish-btn');
        if (finishBtn) {
            finishBtn.onclick = function() {
                window.location.href = L.url('admin/status/overview');
            };
        }

        /* === Опрос состояния VPN / кода / QR === */

        function updateState(delay) {
            if (typeof delay === 'number' && delay > 0) {
                window.setTimeout(function() { updateState(); }, delay);
                return;
            }

            var spinner = root.querySelector('#vpn-spinner');
            var st      = root.querySelector('#vpn-status-text');

            fetch(L.url('admin/network/shpun/api/state'), {
                method: 'GET',
                headers: { 'X-Requested-With': 'XMLHttpRequest' }
            })
            .then(function(r) {
                if (!r.ok) throw new Error('HTTP ' + r.status);
                return r.text();
            })
            .then(function(text) {
                try {
                    var d = text ? JSON.parse(text) : {};
                    
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
                } catch (e) {
                    console.error('State parse error:', e);
                    if (st) {
                        st.textContent = _('Ошибка получения статуса');
                    }
                    updateState(8000);
                }
            })
            .catch(function(e) {
                console.error('State fetch error:', e);
                var spinner = root.querySelector('#vpn-spinner');
                if (spinner) spinner.style.display = 'none';
                if (st) {
                    st.textContent = _('Нет связи с сервером');
                }
                updateState(8000);
            });
        }

        // Инициализация
        showStep(1);
        updateState();

        return root;
    }
});