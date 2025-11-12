include $(TOPDIR)/rules.mk

PKG_NAME:=shpun-router
PKG_VERSION:=1.0.0
PKG_RELEASE:=1
PKG_MAINTAINER:=Eximm
PKG_LICENSE:=MIT
# ⚠️ Не задаём PKGARCH вручную — SDK сам подставит (например mips_24kc)
# PKGARCH:=all

include $(INCLUDE_DIR)/package.mk

define Package/shpun-router
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=VPN
  TITLE:=Shpun Router integration (optimized)
  DEPENDS:=+luci-base +lua +luci-compat
endef

define Package/shpun-router/description
 Оптимизированный лёгкий пакет Shpun Router:
  • агент привязки (shpun-agent)
  • LuCI мастер (контроллер + JS)
  • виджет статуса VPN
  • поддержка автозапуска xray/xray-lite
endef

define Package/shpun-router/conffiles
/etc/shpun/agent.conf
endef

define Build/Prepare
endef
define Build/Configure
endef
define Build/Compile
endef

define Package/shpun-router/install
	# --- init скрипты ---
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/etc/init.d/shpun-agent \
		$(1)/etc/init.d/shpun-agent

	# xray-lite (если есть)
	- [ -f ./files/etc/init.d/xray-lite ] && \
	  $(INSTALL_BIN) ./files/etc/init.d/xray-lite \
	  $(1)/etc/init.d/xray-lite || true

	# --- агент и вспомогательные ---
	$(INSTALL_DIR) $(1)/etc/shpun
	$(INSTALL_BIN) ./files/etc/shpun/agent.sh \
		$(1)/etc/shpun/agent.sh
	$(INSTALL_BIN) ./files/etc/shpun/gen_code.sh \
		$(1)/etc/shpun/gen_code.sh
	- [ -f ./files/etc/shpun/agent.conf ] && \
	  $(INSTALL_DATA) ./files/etc/shpun/agent.conf \
	  $(1)/etc/shpun/agent.conf || true

	# --- LuCI контроллер ---
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/controller
	$(INSTALL_DATA) ./files/usr/lib/lua/luci/controller/shpun.lua \
		$(1)/usr/lib/lua/luci/controller/shpun.lua

	# --- LuCI меню ---
	$(INSTALL_DIR) $(1)/usr/share/luci/menu.d
	$(INSTALL_DATA) ./files/usr/share/luci/menu.d/shpun.json \
		$(1)/usr/share/luci/menu.d/shpun.json

	# --- LuCI мастер ---
	$(INSTALL_DIR) $(1)/www/luci-static/resources/view/shpun
	$(INSTALL_DATA) ./files/www/luci-static/resources/view/shpun/wizard.js \
		$(1)/www/luci-static/resources/view/shpun/wizard.js

	# --- Виджет статуса ---
	$(INSTALL_DIR) $(1)/usr/share/luci/status/include
	$(INSTALL_DATA) ./files/usr/share/luci/status/include/shpunvpn.json \
		$(1)/usr/share/luci/status/include/shpunvpn.json
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/view/status/include
	$(INSTALL_DATA) ./files/usr/lib/lua/luci/view/status/include/20_shpunvpn.htm \
		$(1)/usr/lib/lua/luci/view/status/include/20_shpunvpn.htm
endef

# --- postinst выполняется после установки пакета ---
define Package/shpun-router/postinst
#!/bin/sh
[ -n "$$IPKG_INSTROOT" ] || {
    mkdir -p /etc/shpun
    touch /etc/shpun/first_run

    # --- Автозапуск агента ---
    /etc/init.d/shpun-agent enable 2>/dev/null || true
    /etc/init.d/shpun-agent restart 2>/dev/null || true

    # --- Автозапуск системного xray (если есть) ---
    [ -x /etc/init.d/xray ] && /etc/init.d/xray enable 2>/dev/null || true

    # --- Автозапуск xray-lite (если установлен) ---
    [ -x /etc/init.d/xray-lite ] && {
        /etc/init.d/xray-lite enable 2>/dev/null || true
        /etc/init.d/xray-lite restart 2>/dev/null || true
    }

    # --- Очистка кэша LuCI и перезапуск веб-интерфейса ---
    rm -f /tmp/luci-indexcache /tmp/luci-modulecache/* 2>/dev/null || true
    /etc/init.d/uhttpd reload 2>/dev/null || /etc/init.d/uhttpd restart 2>/dev/null || true
}
exit 0
endef

$(eval $(call BuildPackage,shpun-router))
