include $(TOPDIR)/rules.mk

PKG_NAME:=shpun-router
PKG_VERSION:=0.1.0
PKG_RELEASE:=1
PKGARCH:=all

PKG_MAINTAINER:=Shpun VPN

include $(INCLUDE_DIR)/package.mk

define Package/shpun-router
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=VPN
  TITLE:=Shpun VPN router integration
  DEPENDS:=+xray-core +curl +ca-bundle +ca-certificates +luci-base
endef

define Package/shpun-router/description
 Shpun VPN auto-pairing agent and LuCI setup wizard.
endef

define Package/shpun-router/install
	$(INSTALL_DIR) $(1)/etc/shpun
	$(INSTALL_BIN) ./files/etc/shpun/gen_code.sh $(1)/etc/shpun/gen_code.sh
	$(INSTALL_BIN) ./files/etc/shpun/agent.sh $(1)/etc/shpun/agent.sh

	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/etc/init.d/shpun-agent $(1)/etc/init.d/shpun-agent

	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/controller
	$(INSTALL_DATA) ./files/usr/lib/lua/luci/controller/shpun.lua $(1)/usr/lib/lua/luci/controller/shpun.lua

	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/view/shpun
	$(INSTALL_DATA) ./files/usr/lib/lua/luci/view/shpun/wizard.htm $(1)/usr/lib/lua/luci/view/shpun/wizard.htm

	$(INSTALL_DIR) $(1)/www/luci-static/shpun
	$(INSTALL_DATA) ./files/www/luci-static/shpun/wizard.js $(1)/www/luci-static/shpun/wizard.js
endef

$(eval $(call BuildPackage,shpun-router))
