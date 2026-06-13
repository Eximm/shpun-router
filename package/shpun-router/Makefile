include $(TOPDIR)/rules.mk

PKG_NAME:=shpun-router
PKG_VERSION:=1.1.0
PKG_RELEASE:=44

PKG_MAINTAINER:=Shpun VPN
PKG_LICENSE:=MIT

include $(INCLUDE_DIR)/package.mk

define Package/shpun-router
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=VPN
  TITLE:=Shpun Router integration (ucode backend)
  PKGARCH:=all
  DEPENDS:=+luci-base +jsonfilter +ucode +ucode-mod-fs +ucode-mod-uci +rpcd-mod-ucode +kmod-nft-tproxy
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
 - UDP tunneling via nft TPROXY for calls and realtime apps
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
	$(INSTALL_DIR) $(1)/etc/shpun/routes/presets
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_DIR) $(1)/usr/share/rpcd/ucode
	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DIR) $(1)/usr/share/shpun/presets
	$(INSTALL_DIR) $(1)/usr/share/luci/status/include
	$(INSTALL_DIR) $(1)/www/luci-static/resources/view/status/include
	$(INSTALL_DIR) $(1)/etc/uci-defaults

	# --- core scripts ---
	$(INSTALL_BIN) ./files/etc/shpun/agent.sh                 $(1)/etc/shpun/agent.sh
	$(INSTALL_BIN) ./files/etc/shpun/build-config.sh          $(1)/etc/shpun/build-config.sh
	$(INSTALL_BIN) ./files/etc/shpun/rebuild-config-deferred.sh $(1)/etc/shpun/rebuild-config-deferred.sh
	$(INSTALL_BIN) ./files/etc/shpun/switch-server.sh         $(1)/etc/shpun/switch-server.sh
	$(INSTALL_BIN) ./files/etc/shpun/gen_code.sh              $(1)/etc/shpun/gen_code.sh
	$(INSTALL_BIN) ./files/etc/shpun/firewall-xray.sh         $(1)/etc/shpun/firewall-xray.sh
	$(INSTALL_BIN) ./files/etc/shpun/dns-xray.sh              $(1)/etc/shpun/dns-xray.sh
	$(INSTALL_BIN) ./files/etc/shpun/router_updater           $(1)/etc/shpun/router_updater
	$(INSTALL_BIN) ./files/etc/shpun/set-routing-mode.sh      $(1)/etc/shpun/set-routing-mode.sh
	$(INSTALL_BIN) ./files/etc/shpun/apply-custom-routes.sh   $(1)/etc/shpun/apply-custom-routes.sh

	# default config
	$(INSTALL_CONF) ./files/etc/shpun/agent.conf              $(1)/etc/shpun/agent.conf
	# Built-in baseline; the agent owns and extends the live copies under /etc/shpun/routes.
	$(INSTALL_DATA) ./files/etc/shpun/routes/presets/always_vpn.domains \
		$(1)/usr/share/shpun/presets/always_vpn.domains
	$(INSTALL_DATA) ./files/etc/shpun/routes/presets/always_vpn.cidrs \
		$(1)/usr/share/shpun/presets/always_vpn.cidrs

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

	# Remove obsolete candidates left by 1.1.0-r1; live route state stays agent-owned.
	rm -f /etc/shpun/routes/presets/always_vpn.domains-opkg \
		/etc/shpun/routes/presets/always_vpn.cidrs-opkg \
		/etc/shpun/routes/presets/always_vpn.domains-opkg-new \
		/etc/shpun/routes/presets/always_vpn.cidrs-opkg-new 2>/dev/null || true

	chmod +x /etc/shpun/*.sh 2>/dev/null || true

	/etc/init.d/shpun-agent enable 2>/dev/null || true
	/etc/init.d/shpun-vpn enable 2>/dev/null || true

	/etc/init.d/rpcd restart 2>/dev/null || true

	rm -f /tmp/luci-indexcache /tmp/luci-modulecache/* 2>/dev/null || true

	/etc/init.d/uhttpd reload 2>/dev/null || \
	/etc/init.d/uhttpd restart 2>/dev/null || true

	if [ "$$SHPUN_MANAGED_UPDATE" != "1" ]; then
		/etc/init.d/shpun-agent stop 2>/dev/null || true
		/etc/init.d/shpun-vpn stop 2>/dev/null || true
		rm -f /etc/shpun/vpn_ready /etc/shpun/xray_config_pending /etc/shpun/dns_proxy_ready 2>/dev/null || true
		/etc/init.d/shpun-agent start 2>/dev/null || true
	fi
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
