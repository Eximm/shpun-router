include $(TOPDIR)/rules.mk

PKG_NAME:=shpun-router
PKG_VERSION:=1.0.9
PKG_RELEASE:=1

PKG_MAINTAINER:=Shpun VPN
PKG_LICENSE:=MIT

include $(INCLUDE_DIR)/package.mk

define Package/shpun-router
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=VPN
  TITLE:=Shpun Router integration (ucode backend)
  PKGARCH:=all
  DEPENDS:=+luci-base +jsonfilter +ucode +ucode-mod-fs +ucode-mod-uci +rpcd-mod-ucode
endef

define Package/$(PKG_NAME)/description
Shpun Router Integration:
 - automatic router code generation
 - integration with Shpun VPN billing
 - automatic engine fetch (multi-arch)
 - VPN status widget (LuCI Dashboard)
 - OTA firmware update (from widget)
 - subscription server selection from LuCI widget
 - route feed update for split routing and smart RU presets
 - routing mode switch: full / smart_ru / split_ru
 - custom routing rules: force VPN / direct for IP, CIDR and domains
 - optional UDP tunneling via nft TPROXY
endef

define Build/Compile
	# Nothing to compile - pure script package
endef


#######################################
# INSTALL
#######################################

define Package/$(PKG_NAME)/install
	$(INSTALL_DIR) $(1)/etc/shpun
	$(INSTALL_DIR) $(1)/etc/shpun/routes
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_DIR) $(1)/usr/share/rpcd/ucode
	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DIR) $(1)/usr/share/luci/status/include
	$(INSTALL_DIR) $(1)/www/luci-static/resources/view/status/include
	$(INSTALL_DIR) $(1)/etc/uci-defaults

	# --- core scripts ---
	$(INSTALL_BIN) ./files/etc/shpun/agent.sh                 $(1)/etc/shpun/agent.sh
	$(INSTALL_BIN) ./files/etc/shpun/build-config.sh          $(1)/etc/shpun/build-config.sh
	$(INSTALL_BIN) ./files/etc/shpun/gen_code.sh              $(1)/etc/shpun/gen_code.sh
	$(INSTALL_BIN) ./files/etc/shpun/firewall-xray.sh         $(1)/etc/shpun/firewall-xray.sh
	$(INSTALL_BIN) ./files/etc/shpun/router_updater           $(1)/etc/shpun/router_updater
	$(INSTALL_BIN) ./files/etc/shpun/set-routing-mode.sh      $(1)/etc/shpun/set-routing-mode.sh
	$(INSTALL_BIN) ./files/etc/shpun/apply-custom-routes.sh   $(1)/etc/shpun/apply-custom-routes.sh

	# default config
	$(INSTALL_CONF) ./files/etc/shpun/agent.conf              $(1)/etc/shpun/agent.conf

	# --- init scripts ---
	$(INSTALL_BIN) ./files/etc/init.d/shpun-agent             $(1)/etc/init.d/shpun-agent
	$(INSTALL_BIN) ./files/etc/init.d/shpun-vpn               $(1)/etc/init.d/shpun-vpn

	# --- rpcd ucode backend ---
	$(INSTALL_DATA) ./files/usr/share/rpcd/ucode/shpun.uc     $(1)/usr/share/rpcd/ucode/shpun.uc

	# --- ACL ---
	$(INSTALL_DATA) ./files/usr/share/rpcd/acl.d/shpun.json   $(1)/usr/share/rpcd/acl.d/shpun.json

	# --- Status widget descriptor (JSON) ---
	$(INSTALL_DATA) ./files/usr/share/luci/status/include/01_shpunvpn.json \
		$(1)/usr/share/luci/status/include/01_shpunvpn.json

	# --- Status widget JS ---
	$(INSTALL_DATA) ./files/www/luci-static/resources/view/status/include/01_shpunvpn.js \
		$(1)/www/luci-static/resources/view/status/include/01_shpunvpn.js

	# --- uci-defaults ---
	$(INSTALL_BIN) ./files/etc/uci-defaults/99_shpun-router   $(1)/etc/uci-defaults/99_shpun-router

	# --- firmware version files ---
	echo "$(PKG_VERSION)" > $(1)/etc/shpun/fw_current
	echo "$(PKG_VERSION)" > $(1)/etc/shpun/router_software_version
	echo "$(PKG_VERSION)" > $(1)/etc/shpun/router_version
endef


#######################################
# POSTINST
#######################################

define Package/$(PKG_NAME)/postinst
#!/bin/sh
[ -n "$$IPKG_INSTROOT" ] || {

	mkdir -p /etc/shpun
	mkdir -p /etc/shpun/routes

	chmod +x /etc/shpun/*.sh 2>/dev/null || true

	/etc/init.d/shpun-agent enable 2>/dev/null || true
	/etc/init.d/shpun-vpn enable 2>/dev/null || true

	/etc/init.d/rpcd restart 2>/dev/null || true

	rm -f /tmp/luci-indexcache /tmp/luci-modulecache/* 2>/dev/null || true

	/etc/init.d/uhttpd reload 2>/dev/null || \
	/etc/init.d/uhttpd restart 2>/dev/null || true

	/etc/init.d/shpun-agent restart 2>/dev/null || true
}
exit 0
endef


#######################################
# CONFFILES
#######################################

define Package/$(PKG_NAME)/conffiles
/etc/shpun/agent.conf
endef

#######################################

$(eval $(call BuildPackage,$(PKG_NAME)))
