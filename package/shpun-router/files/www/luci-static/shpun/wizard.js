(function(){
  function ajax(method, url, data){
    return fetch(url, {
      method: method,
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: data ? new URLSearchParams(data) : null
    }).then(r=>r.json());
  }

  function showStep(n){
    document.querySelectorAll('#shpun-wizard .step').forEach(function(el, i){
      el.style.display = (i === n-1 ? 'block' : 'none');
    });
  }

  // Шаг 1 — WAN
  document.getElementById('wan-apply').onclick = function(){
    var proto = document.querySelector('input[name="wan_proto"]:checked').value;
    var data = { proto: proto };
    if (proto === 'pppoe'){
      data.user = document.getElementById('pppoe-user').value;
      data.pass = document.getElementById('pppoe-pass').value;
    }
    ajax('POST', L.env.cgi_base + '/admin/shpun/api/apply_wan', data)
      .then(function(){ showStep(2); });
  };
  document.getElementById('wan-skip').onclick = function(){ showStep(2); };

  // Шаг 2 — WiFi
  document.getElementById('wifi-apply').onclick = function(){
    ajax('POST', L.env.cgi_base + '/admin/shpun/api/apply_wifi', {
      ssid: document.getElementById('wifi-ssid').value,
      key:  document.getElementById('wifi-key').value
    }).then(function(){ showStep(3); });
  };
  document.getElementById('wifi-skip').onclick = function(){ showStep(3); };

  // Подробно обновляем состояние VPN/кода
  function updateState(){
    ajax('GET', L.env.cgi_base + '/admin/shpun/api/state').then(function(d){
      if (d.code){
        document.getElementById('router-code').textContent = d.code;

        // Строим ссылку на бота и QR
        var bot = '@shpunvpn_bot'; // <--- ТУТ поменять на username бота без @
        var tgUrl = 'https://t.me/' + bot + '?start=router_' + encodeURIComponent(d.code);
        var qrUrl = 'https://api.qrserver.com/v1/create-qr-code/?size=180x180&data=' + encodeURIComponent(tgUrl);

        var img = document.getElementById('qr-img');
        if (img.src !== qrUrl){
          img.src = qrUrl;
        }
        img.style.display = 'block';
      }

      var st = document.getElementById('vpn-status-text');
      if (d.has_sub){
        st.textContent = 'подписка найдена, VPN настраивается / уже работает ✅';
      }else{
        st.textContent = 'ожидаем привязку…';
        setTimeout(updateState, 5000);
      }
    });
  }

  // Переключение PPPoE-полей
  document.querySelectorAll('input[name="wan_proto"]').forEach(function(r){
    r.addEventListener('change', function(){
      document.getElementById('pppoe-fields').style.display =
        (this.value === 'pppoe') ? 'block' : 'none';
    });
  });

  document.getElementById('finish-btn').onclick = function(){
    window.location.href = L.env.cgi_base + '/admin/status/overview';
  };

  // Старт
  showStep(1);
  updateState();
})();
