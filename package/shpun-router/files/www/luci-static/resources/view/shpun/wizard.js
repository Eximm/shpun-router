'use strict';
'require view';

return view.extend({
    load: function () {
        return Promise.resolve();
    },

    render: function () {

        /* ================== API helpers (LuCI-safe) ================== */
        async function processResponseJSON(res) {
            if (!res) throw new Error(_('Нет ответа от сервера'));
            if (res.status === 403)
                throw new Error(_('Ошибка 403: нет доступа. Проверьте авторизацию в LuCI и CSRF-токен.'));
            if (!res.ok) throw new Error(_('Ошибка сервера: ') + res.status);

            const text = (await res.text()).trim();
            if (!text) throw new Error(_('Пустой ответ сервера'));
            if (text.startsWith('<!DOCTYPE') || text.startsWith('<html'))
                throw new Error(_('Сервер вернул HTML-страницу (возможна потеря авторизации или неверный путь API).'));

            try { return JSON.parse(text); }
            catch (e) { throw new Error(_('Сервер вернул некорректный JSON: ') + text.slice(0, 160)); }
        }

        function apiPost(urlStr, data) {
            return fetch(L.url(urlStr), {
                method: 'POST',
                credentials: 'same-origin',
                headers: {
                    'Content-Type': 'application/json',
                    'X-CSRF-Token': L.env.token
                },
                body: JSON.stringify(data || {})
            }).then(processResponseJSON);
        }

        function apiGet(urlStr) {
            return fetch(L.url(urlStr), {
                method: 'GET',
                credentials: 'same-origin',
                headers: { 'X-CSRF-Token': L.env.token }
            }).then(processResponseJSON);
        }

        /* ================== UI ================== */
        const root = E('div', { id: 'shpun-wizard', 'class': 'cbi-section' }, [
            E('style', {}, [String.raw`
#shpun-wizard { max-width: 720px; margin: 0 auto; }
#shpun-wizard h2 { margin-bottom: 1rem; }
#shpun-wizard .step { display: none; }
#shpun-wizard .step.active { display: block; }
#shpun-wizard .step-card {
  border: 1px solid #ddd; border-radius: 6px; padding: 16px; margin-bottom: 16px; background: #fff;
}
#shpun-wizard .btn-row { margin-top: 16px; display: flex; gap: 8px; }
#shpun-error, #shpun-success { display:none; margin-bottom:12px; padding:8px 10px; border-radius:4px; font-size:.9em; }
#shpun-error { background:#ffebee; color:#b71c1c; }
#shpun-success{ background:#e8f5e8; color:#2e7d32; }
.shpun-spinner{ width:20px;height:20px;border:3px solid #ccc;border-top-color:#2e7dff;border-radius:50%;
  display:inline-block;vertical-align:middle;animation:shpun-spin .7s linear infinite;margin-left:8px;}
@keyframes shpun-spin { to { transform: rotate(360deg); } }
#router-code{ font-weight:700;font-size:1.2em;color:#2e7d32;background:#f5f5f5;padding:8px 12px;border-radius:4px;display:inline-block;}
.shpun-field{ margin-bottom:10px; } .shpun-field label{ display:block;margin-bottom:4px;font-weight:600; }
.shpun-field input[type="text"], .shpun-field input[type="password"]{ width:100%;max-width:360px;padding:6px 8px;border:1px solid #ccc;border-radius:4px;}
.shpun-muted{ font-size:.9em;color:#666; }
`]),
            E('h2', {}, [_('Мастер настройки Shpun Router')]),
            E('p', { 'class': 'shpun-muted' }, [
                _('Пройдите три шага: настройте подключение к интернету (WAN), Wi-Fi и привяжите роутер к VPN через Telegram.')
            ]),
            E('div', { id: 'shpun-error' }),
            E('div', { id: 'shpun-success' }),

            /* === Шаг 1: WAN === */
            E('div', { 'class': 'step step-1 step-card active' }, [
                E('h3', {}, [_('Шаг 1: Подключение к интернету (WAN)')]),
                E('p', { 'class': 'shpun-muted' }, [
                    _('Если вы не уверены — оставьте DHCP (по умолчанию).')
                ]),
                E('div', { 'class': 'shpun-field' }, [
                    E('label', {}, [_('Тип подключения WAN:')]),
                    E('label', {}, [ E('input', { type:'radio',name:'wan_proto',value:'dhcp',checked:'checked' }), ' ', _('Получить адрес автоматически (DHCP)') ]),
                    E('br'),
                    E('label', {}, [ E('input', { type:'radio',name:'wan_proto',value:'pppoe' }), ' ', _('PPPoE (логин/пароль)') ]),
                    E('br'),
                    E('label', {}, [ E('input', { type:'radio',name:'wan_proto',value:'static' }), ' ', _('Статический IP (Static IP)') ]),
                    E('br'),
                    E('label', {}, [ E('input', { type:'radio',name:'wan_proto',value:'l2tp' }), ' ', _('L2TP (логин/пароль + сервер)') ])
                ]),
                /* PPPoE */
                E('div', { id:'pppoe-fields', style:'display:none;margin-top:8px;' }, [
                    E('div', { 'class':'shpun-field' }, [ E('label', { 'for':'pppoe-user' }, [_('PPPoE логин:')]),  E('input', { id:'pppoe-user', type:'text', autocomplete:'off' }) ]),
                    E('div', { 'class':'shpun-field' }, [ E('label', { 'for':'pppoe-pass' }, [_('PPPoE пароль:')]), E('input', { id:'pppoe-pass', type:'password', autocomplete:'off' }) ])
                ]),
                /* Static IP */
                E('div', { id:'static-fields', style:'display:none;margin-top:8px;' }, [
                    E('div', { 'class':'shpun-field' }, [ E('label', { 'for':'static-ip' },   [_('IP-адрес:')]),        E('input', { id:'static-ip',   type:'text', placeholder:'192.168.0.2' }) ]),
                    E('div', { 'class':'shpun-field' }, [ E('label', { 'for':'static-mask' }, [_('Маска подсети:')]),   E('input', { id:'static-mask', type:'text', placeholder:'255.255.255.0' }) ]),
                    E('div', { 'class':'shpun-field' }, [ E('label', { 'for':'static-gw' },   [_('Шлюз (Gateway):')]), E('input', { id:'static-gw',   type:'text', placeholder:'192.168.0.1' }) ]),
                    E('div', { 'class':'shpun-field' }, [ E('label', { 'for':'static-dns' },  [_('DNS (можно пусто):')]), E('input', { id:'static-dns',  type:'text', placeholder:'1.1.1.1' }) ])
                ]),
                /* L2TP */
                E('div', { id:'l2tp-fields', style:'display:none;margin-top:8px;' }, [
                    E('div', { 'class':'shpun-field' }, [ E('label', { 'for':'l2tp-server' }, [_('Адрес L2TP-сервера:')]), E('input', { id:'l2tp-server', type:'text', placeholder:'vpn.provider.ru' }) ]),
                    E('div', { 'class':'shpun-field' }, [ E('label', { 'for':'l2tp-user' },   [_('L2TP логин:')]),        E('input', { id:'l2tp-user',   type:'text' }) ]),
                    E('div', { 'class':'shpun-field' }, [ E('label', { 'for':'l2tp-pass' },   [_('L2TP пароль:')]),       E('input', { id:'l2tp-pass',   type:'password' }) ])
                ]),
                E('div', { 'class':'btn-row' }, [
                    E('button', { id:'wan-apply','class':'btn cbi-button cbi-button-save','data-busy-text':_('Применяем…'), type:'button' }, [_('Сохранить и далее')]),
                    E('button', { id:'wan-skip', 'class':'btn cbi-button cbi-button-reset', type:'button' }, [_('Пропустить шаг')])
                ])
            ]),

            /* === Шаг 2: Wi-Fi === */
            E('div', { 'class':'step step-2 step-card' }, [
                E('h3', {}, [_('Шаг 2: Настройка Wi-Fi')]),
                E('div', { 'class':'shpun-field' }, [ E('label', { 'for':'wifi-ssid' }, [_('Имя Wi-Fi сети (SSID):')]), E('input', { id:'wifi-ssid', type:'text', value:'Shpun-Router' }) ]),
                E('div', { 'class':'shpun-field' }, [
                    E('label', { 'for':'wifi-key' }, [_('Пароль Wi-Fi (можно оставить пустым):')]),
                    E('input', { id:'wifi-key', type:'text' }),
                    E('p', { 'class':'shpun-muted' }, [_('Если оставить поле пустым — сеть будет открытой (без пароля).')])
                ]),
                E('div', { 'class':'btn-row' }, [
                    E('button', { id:'wifi-apply','class':'btn cbi-button cbi-button-save','data-busy-text':_('Применяем…'), type:'button' }, [_('Сохранить и далее')]),
                    E('button', { id:'wifi-skip','class':'btn cbi-button cbi-button-reset', type:'button' }, [_('Пропустить шаг')])
                ])
            ]),

            /* === Шаг 3: VPN === */
            E('div', { 'class':'step step-3 step-card' }, [
                E('h3', {}, [_('Шаг 3: Привязка к Shpun VPN')]),
                E('div', { 'class':'shpun-field' }, [
                    E('label', {}, [_('Код вашего роутера:')]),
                    E('div', { id:'router-code' }, ['—'])
                ]),
                E('div', { 'class':'shpun-field' }, [
                    E('label', {}, [_('QR-код для Telegram:')]), E('br'),
                    E('a', { id:'tg-link', href:'#', target:'_blank' }, [
                        E('img', { id:'qr-img', src:'', alt:'QR', style:'display:none;width:180px;height:180px;border:1px solid #ddd;border-radius:4px;margin-top:10px;' })
                    ])
                ]),
                E('div', { id:'vpn-status','class':'shpun-field' }, [
                    E('span', { id:'vpn-status-text' }, [_('Проверяем состояние…')]),
                    E('span', { id:'vpn-spinner','class':'shpun-spinner' })
                ]),
                E('div', { 'class':'btn-row' }, [
                    E('button', { id:'finish-btn','class':'btn cbi-button cbi-button-save', type:'button' }, [_('Завершить и перейти к статусу')])
                ])
            ])
        ]);

        /* ================== UI helpers ================== */
        function showStep(n){ root.querySelectorAll('.step').forEach((el,i)=>el.classList.toggle('active', i === (n-1))); }
        function showError(msg){ const e=root.querySelector('#shpun-error'); if(e){e.textContent=msg;e.style.display='block';} root.querySelector('#shpun-success').style.display='none'; }
        function showSuccess(msg){ const s=root.querySelector('#shpun-success'); if(s){s.textContent=msg;s.style.display='block';} root.querySelector('#shpun-error').style.display='none'; }
        function clearMessages(){ root.querySelector('#shpun-error').style.display='none'; root.querySelector('#shpun-success').style.display='none'; }
        function setBusy(btn,b){ if(!btn)return; btn.disabled=!!b; if(b){ btn.dataset.origText=btn.dataset.origText||btn.textContent; btn.textContent=btn.dataset.busyText||_('Подождите…'); } else if (btn.dataset.origText){ btn.textContent=btn.dataset.origText; } }
        function updateWanFields(proto){
            const pppoe=root.querySelector('#pppoe-fields');
            const stat =root.querySelector('#static-fields');
            const l2tp =root.querySelector('#l2tp-fields');
            if(pppoe) pppoe.style.display = (proto==='pppoe')?'block':'none';
            if(stat)  stat.style.display  = (proto==='static')?'block':'none';
            if(l2tp)  l2tp.style.display  = (proto==='l2tp')  ?'block':'none';
        }

        /* ================== WAN ================== */
        const wanApplyBtn=root.querySelector('#wan-apply');
        const wanSkipBtn =root.querySelector('#wan-skip');

        updateWanFields('dhcp');
        root.querySelectorAll('input[name="wan_proto"]').forEach(r=>{
            r.addEventListener('change', function(){ clearMessages(); updateWanFields(this.value); });
        });

        if (wanApplyBtn) {
            wanApplyBtn.onclick = function () {
                clearMessages();
                const protoInput = root.querySelector('input[name="wan_proto"]:checked');
                if (!protoInput) return showError(_('Выберите тип подключения WAN'));

                const proto = protoInput.value;
                const data  = { proto };

                if (proto === 'pppoe') {
                    const user = (root.querySelector('#pppoe-user')||{}).value || '';
                    const pass = (root.querySelector('#pppoe-pass')||{}).value || '';
                    if (!user || !pass) return showError(_('Для PPPoE необходимо указать логин и пароль'));
                    data.user = user.trim(); data.pass = pass;
                } else if (proto === 'static') {
                    const ip  = (root.querySelector('#static-ip')  ||{}).value || '';
                    const msk = (root.querySelector('#static-mask')||{}).value || '';
                    const gw  = (root.querySelector('#static-gw')  ||{}).value || '';
                    const dns = (root.querySelector('#static-dns') ||{}).value || '';
                    if (!ip.trim() || !msk.trim() || !gw.trim())
                        return showError(_('Для статического IP необходимо указать IP, маску и шлюз'));
                    data.ipaddr=ip.trim(); data.netmask=msk.trim(); data.gateway=gw.trim();
                    if (dns.trim()) data.dns = dns.trim();
                } else if (proto === 'l2tp') {
                    const srv  = (root.querySelector('#l2tp-server')||{}).value || '';
                    const user = (root.querySelector('#l2tp-user')  ||{}).value || '';
                    const pass = (root.querySelector('#l2tp-pass')  ||{}).value || '';
                    if (!srv.trim() || !user.trim() || !pass)
                        return showError(_('Для L2TP необходимо указать сервер, логин и пароль'));
                    data.server=srv.trim(); data.user=user.trim(); data.pass=pass;
                }

                setBusy(wanApplyBtn, true);
                apiPost('admin/network/shpun/api/apply_wan', data)
                    .then(res => {
                        if (res && res.ok === 1) {
                            showSuccess(_('Настройки WAN успешно применены! Перезапускаем сеть...'));
                            setTimeout(()=>showStep(2), 1500);
                        } else throw new Error((res && res.error) || _('Неизвестная ошибка сервера'));
                    })
                    .catch(e => showError(_('Не удалось применить настройки WAN: ') + e.message))
                    .finally(()=> setBusy(wanApplyBtn,false));
            };
        }
        if (wanSkipBtn) { wanSkipBtn.onclick = ()=>{ clearMessages(); showStep(2); }; }

        /* ================== Wi-Fi ================== */
        const wifiApplyBtn=root.querySelector('#wifi-apply');
        const wifiSkipBtn =root.querySelector('#wifi-skip');

        if (wifiApplyBtn) {
            wifiApplyBtn.onclick = function(){
                clearMessages();
                const ssid = (root.querySelector('#wifi-ssid')||{}).value || '';
                const key  = (root.querySelector('#wifi-key') ||{}).value || '';
                if (!ssid.trim()) return showError(_('SSID не может быть пустым'));

                setBusy(wifiApplyBtn,true);
                apiPost('admin/network/shpun/api/apply_wifi', { ssid:ssid.trim(), key })
                    .then(res => {
                        if (res && res.ok === 1) {
                            showSuccess(_('Настройки Wi-Fi успешно применены!'));
                            setTimeout(()=>showStep(3), 800);
                        } else throw new Error((res && res.error) || _('Неизвестная ошибка сервера'));
                    })
                    .catch(e => showError(_('Не удалось применить настройки Wi-Fi: ') + e.message))
                    .finally(()=> setBusy(wifiApplyBtn,false));
            };
        }
        if (wifiSkipBtn) { wifiSkipBtn.onclick = ()=>{ clearMessages(); showStep(3); }; }

        /* ================== Finish ================== */
        const finishBtn=root.querySelector('#finish-btn');
        if (finishBtn) finishBtn.onclick = ()=>{ window.location.href = L.url('admin/status/overview'); };

        /* ================== State polling (VPN) ================== */
        function updateState(){
            const spinner=root.querySelector('#vpn-spinner');
            const st     =root.querySelector('#vpn-status-text');

            apiGet('admin/network/shpun/api/state')
                .then(d=>{
                    if (d.code) {
                        const codeText=root.querySelector('#router-code');
                        if (codeText) codeText.textContent = d.code;

                        const bot='shpunvpn_bot';
                        const tg = 'https://t.me/'+bot+'?start=router_'+encodeURIComponent(d.code);
                        const qr = 'https://api.qrserver.com/v1/create-qr-code/?size=180x180&data='+encodeURIComponent(tg);
                        const img=root.querySelector('#qr-img'); if (img){ if (img.src!==qr) img.src=qr; img.style.display='block'; }
                        const a  =root.querySelector('#tg-link'); if (a) a.href=tg;
                    }

                    if (st && spinner) {
                        if (!d.has_sub) {
                            st.textContent = _('Ожидаем привязку…'); spinner.style.display='inline-block';
                            setTimeout(updateState, 5000);
                        } else if (d.has_sub && !d.vpn_ready) {
                            st.textContent = _('Получаем настройки и запускаем VPN…'); spinner.style.display='inline-block';
                            setTimeout(updateState, 3000);
                        } else {
                            st.textContent = _('VPN настроен и работает ✅'); spinner.style.display='none';
                        }
                    }
                })
                .catch(e=>{
                    if (spinner) spinner.style.display='none';
                    if (st) st.textContent = _('Ошибка связи: ') + e.message;
                    setTimeout(updateState, 8000);
                });
        }

        // init
        updateWanFields('dhcp');
        showStep(1);
        updateState();

        return root;
    }
});
