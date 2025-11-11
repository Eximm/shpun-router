include $(TOPDIR)/rules.mk

PKG_NAME:=shpun-router
PKG_VERSION:=1.0.0
PKG_RELEASE:=1

PKG_MAINTAINER:=Eximm
PKG_LICENSE:=MIT

# по сути noarch, но SDK всё равно положит в каталог arch'а
PKGARCH:=all

include $(INCLUDE_DIR)/package.mk

define Package/shpun-router
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=VPN
  TITLE:=Shpun Router integration (light)
  DEPENDS:=+luci-base
endef

define Package/shpun-router/description
 Лёгкий пакет Shpun Router:
  * агент привязки роутера к Shpun VPN
  * LuCI-мастер настройки и генерации кода
  * без curl/bash, максимум экономии флеша
endef

define Package/shpun-router/conffiles
/etc/config/shpun
/etc/shpun/agent.conf
endef

define Build/Prepare
endef

define Build/Configure
endef

define Build/Compile
endef

define Package/shpun-router/install
	# init-скрипт агента
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/etc/init.d/shpun-agent $(1)/etc/init.d/shpun-agent

	# скрипты агента
	$(INSTALL_DIR) $(1)/etc/shpun
	$(INSTALL_BIN) ./files/etc/shpun/agent.sh    $(1)/etc/shpun/agent.sh
	$(INSTALL_BIN) ./files/etc/shpun/gen_code.sh $(1)/etc/shpun/gen_code.sh

	# контроллер LuCI
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/controller
	$(INSTALL_DATA) ./files/usr/lib/lua/luci/controller/shpun.lua \
		$(1)/usr/lib/lua/luci/controller/shpun.lua

	# виджет статуса (20_shpunvpn.htm)
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/view/status/include
	$(INSTALL_DATA) ./files/usr/lib/lua/luci/view/status/include/20_shpunvpn.htm \
		$(1)/usr/lib/lua/luci/view/status/include/20_shpunvpn.htm

	# JSON-меню LuCI
	$(INSTALL_DIR) $(1)/usr/share/luci/menu.d
	$(INSTALL_DATA) ./files/usr/share/luci/menu.d/shpun.json \
		$(1)/usr/share/luci/menu.d/shpun.json

	# JSON для status (если используешь)
	$(INSTALL_DIR) $(1)/usr/share/luci/status/include
	$(INSTALL_DATA) ./files/usr/share/luci/status/include/shpunvpn.json \
		$(1)/usr/share/luci/status/include/shpunvpn.json

	# JS-мастер (новый путь для LuCI 24.10+)
	$(INSTALL_DIR) $(1)/www/luci-static/resources/view/shpun
	$(INSTALL_DATA) ./files/www/luci-static/resources/view/shpun/wizard.js \
		$(1)/www/luci-static/resources/view/shpun/wizard.js
endef

define Package/shpun-router/postinst
#!/bin/sh
[ -n "$$IPKG_INSTROOT" ] || {
    mkdir -p /etc/shpun
    touch /etc/shpun/first_run
    /etc/init.d/shpun-agent enable 2>/dev/null || true
}
exit 0
endef

$(eval $(call BuildPackage,shpun-router))
