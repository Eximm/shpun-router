(function () {
  var base = L.env.cgi_base || "";
  // Имя бота БЕЗ @
  var botUsername = "shpunvpn_bot";

  function ajax(method, url, data) {
    var opts = {
      method: method,
      headers: {}
    };

    if (method === "GET" && data) {
      var qs = new URLSearchParams(data).toString();
      url += (url.indexOf("?") === -1 ? "?" : "&") + qs;
    } else if (method !== "GET" && data) {
      opts.headers["Content-Type"] = "application/x-www-form-urlencoded";
      opts.body = new URLSearchParams(data);
    }

    opts.headers["X-Requested-With"] = "XMLHttpRequest";

    return fetch(url, opts).then(function (r) {
      if (!r.ok) {
        throw new Error("HTTP " + r.status);
      }
      return r.json();
    });
  }

  function showStep(n) {
    document.querySelectorAll("#shpun-wizard .step").forEach(function (el, i) {
      el.style.display = i === n - 1 ? "block" : "none";
    });
  }

  function showError(msg) {
    var box = document.getElementById("shpun-error");
    if (box) {
      box.textContent = msg;
      box.style.display = "block";
    } else {
      console.error(msg);
      alert(msg);
    }
  }

  function setBusy(btn, busy) {
    if (!btn) return;
    btn.disabled = !!busy;
    if (busy) {
      btn.dataset.origText = btn.dataset.origText || btn.textContent;
      btn.textContent = btn.dataset.busyText || "Подождите…";
    } else if (btn.dataset.origText) {
      btn.textContent = btn.dataset.origText;
    }
  }

  // --- Шаг 1: WAN ---

  var wanApplyBtn = document.getElementById("wan-apply");
  var wanSkipBtn = document.getElementById("wan-skip");

  if (wanApplyBtn) {
    wanApplyBtn.onclick = function () {
      var protoInput = document.querySelector('input[name="wan_proto"]:checked');
      if (!protoInput) {
        showError("Выберите тип подключения WAN");
        return;
      }

      var proto = protoInput.value;
      var data = { proto: proto };

      if (proto === "pppoe") {
        var userEl = document.getElementById("pppoe-user");
        var passEl = document.getElementById("pppoe-pass");
        var user = userEl ? userEl.value.trim() : "";
        var pass = passEl ? passEl.value : "";

        if (!user || !pass) {
          showError("Для PPPoE необходимо указать логин и пароль");
          return;
        }

        data.user = user;
        data.pass = pass;
      }

      setBusy(wanApplyBtn, true);
      ajax("POST", base + "/admin/network/shpun/api/apply_wan", data)
        .then(function () {
          showStep(2);
        })
        .catch(function (e) {
          showError("Не удалось применить настройки WAN: " + e.message);
        })
        .finally(function () {
          setBusy(wanApplyBtn, false);
        });
    };
  }

  if (wanSkipBtn) {
    wanSkipBtn.onclick = function () {
      showStep(2);
    };
  }

  // --- Шаг 2: Wi-Fi ---

  var wifiApplyBtn = document.getElementById("wifi-apply");
  var wifiSkipBtn = document.getElementById("wifi-skip");

  if (wifiApplyBtn) {
    wifiApplyBtn.onclick = function () {
      var ssidEl = document.getElementById("wifi-ssid");
      var keyEl = document.getElementById("wifi-key");
      var ssid = ssidEl ? ssidEl.value.trim() : "";
      var key = keyEl ? keyEl.value : "";

      if (!ssid) {
        showError("SSID не может быть пустым");
        return;
      }

      setBusy(wifiApplyBtn, true);
      ajax("POST", base + "/admin/network/shpun/api/apply_wifi", {
        ssid: ssid,
        key: key
      })
        .then(function () {
          showStep(3);
        })
        .catch(function (e) {
          showError("Не удалось применить настройки Wi-Fi: " + e.message);
        })
        .finally(function () {
          setBusy(wifiApplyBtn, false);
        });
    };
  }

  if (wifiSkipBtn) {
    wifiSkipBtn.onclick = function () {
      showStep(3);
    };
  }

  // --- Обновление состояния VPN/кода ---

  function updateState(delay) {
    if (typeof delay === "number" && delay > 0) {
      setTimeout(function () {
        updateState();
      }, delay);
      return;
    }

    var spinner = document.getElementById("vpn-spinner");
    var st = document.getElementById("vpn-status-text");

    ajax("GET", base + "/admin/network/shpun/api/state")
      .then(function (d) {
        if (d.code) {
          var codeText = document.getElementById("router-code");
          if (codeText) {
            codeText.textContent = d.code;
          }

          var tgUrl =
            "https://t.me/" +
            botUsername +
            "?start=router_" +
            encodeURIComponent(d.code);
          var qrUrl =
            "https://api.qrserver.com/v1/create-qr-code/?size=180x180&data=" +
            encodeURIComponent(tgUrl);

          var img = document.getElementById("qr-img");
          if (img) {
            if (img.src !== qrUrl) {
              img.src = qrUrl;
            }
            img.style.display = "block";
          }

          var linkEl = document.getElementById("tg-link");
          if (linkEl) {
            linkEl.href = tgUrl;
          }
        }

        if (st && spinner) {
          if (!d.has_sub) {
            st.textContent = "Ожидаем привязку…";
            spinner.style.display = "none";
            updateState(5000);
          } else if (d.has_sub && !d.vpn_ready) {
            st.textContent = "Получаем настройки и запускаем VPN…";
            spinner.style.display = "inline-block";
            updateState(3000);
          } else if (d.has_sub && d.vpn_ready) {
            st.textContent = "VPN настроен и работает ✅";
            spinner.style.display = "none";
          }
        } else if (!d.has_sub) {
          updateState(5000);
        }
      })
      .catch(function (e) {
        console.warn("state update failed:", e);
        if (spinner) spinner.style.display = "none";
        updateState(8000);
      });
  }

  // --- Переключение полей PPPoE ---

  var protoRadios = document.querySelectorAll('input[name="wan_proto"]');
  if (protoRadios && protoRadios.length) {
    protoRadios.forEach(function (r) {
      r.addEventListener("change", function () {
        var block = document.getElementById("pppoe-fields");
        if (!block) return;
        block.style.display = this.value === "pppoe" ? "block" : "none";
      });
    });
  }

  // --- Кнопка "Завершить" ---

  var finishBtn = document.getElementById("finish-btn");
  if (finishBtn) {
    finishBtn.onclick = function () {
      window.location.href = base + "/admin/status/overview";
    };
  }

  // --- Старт мастера ---

  showStep(1);
  updateState();
})();
