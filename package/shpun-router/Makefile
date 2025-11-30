include $(TOPDIR)/rules.mk

PKG_NAME:=shpun-router
PKG_VERSION:=1.0.0
PKG_RELEASE:=2
PKG_MAINTAINER:=Eximm
PKG_LICENSE:=MIT

# Универсальная архитектура, чтобы ставилось на любой OpenWrt 24.10+
PKGARCH:=all

include $(INCLUDE_DIR)/package.mk

define Package/shpun-router
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=VPN
  TITLE:=Shpun Router integration (ucode backend)
  DEPENDS:=+luci-base +uclient-fetch +jsonfilter +ucode +ucode-mod-fs +ucode-mod-uci +rpcd-mod-ucode
endef

define Package/shpun-router/description
 Shpun Router:
  • shpun-agent (привязка к VPN)
  • LuCI wizard (JS + ucode backend через ubus)
  • статус-виджет VPN
  • обёртка для внешнего VPN-движка (shpun-vpn)
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
	# --- uci-defaults ---
	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) ./files/etc/uci-defaults/99_shpun-router \
		$(1)/etc/uci-defaults/99_shpun-router

	# --- init ---
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/etc/init.d/shpun-agent \
		$(1)/etc/init.d/shpun-agent
	$(INSTALL_BIN) ./files/etc/init.d/shpun-vpn \
		$(1)/etc/init.d/shpun-vpn

	# --- агент и конфиги ---
	$(INSTALL_DIR) $(1)/etc/shpun
	$(INSTALL_BIN) ./files/etc/shpun/agent.sh \
		$(1)/etc/shpun/agent.sh
	$(INSTALL_BIN) ./files/etc/shpun/gen_code.sh \
		$(1)/etc/shpun/gen_code.sh
	$(INSTALL_BIN) ./files/etc/shpun/build-config.sh \
		$(1)/etc/shpun/build-config.sh
	$(INSTALL_DATA) ./files/etc/shpun/agent.conf \
		$(1)/etc/shpun/agent.conf
	$(INSTALL_BIN) ./files/etc/shpun/firewall-xray.sh \
		$(1)/etc/shpun/firewall-xray.sh 

	# --- dnsmasq.d ---
	$(INSTALL_DIR) $(1)/etc/dnsmasq.d
	$(INSTALL_DATA) ./files/etc/dnsmasq.d/shpun-dns.conf \
		$(1)/etc/dnsmasq.d/shpun-dns.conf

	# --- меню LuCI ---
	$(INSTALL_DIR) $(1)/usr/share/luci/menu.d
	$(INSTALL_DATA) ./files/usr/share/luci/menu.d/shpun.json \
		$(1)/usr/share/luci/menu.d/shpun.json

	# --- JS wizard ---
	$(INSTALL_DIR) $(1)/www/luci-static/resources/view/shpun
	$(INSTALL_DATA) ./files/www/luci-static/resources/view/shpun/wizard.js \
		$(1)/www/luci-static/resources/view/shpun/wizard.js

	# --- статус-виджет ---
	$(INSTALL_DIR) $(1)/usr/share/luci/status/include
	$(INSTALL_DATA) ./files/usr/share/luci/status/include/shpunvpn.json \
		$(1)/usr/share/luci/status/include/shpunvpn.json
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/view/status/include
	$(INSTALL_DATA) ./files/usr/lib/lua/luci/view/status/include/20_shpunvpn.htm \
		$(1)/usr/lib/lua/luci/view/status/include/20_shpunvpn.htm

	# --- ucode backend ---
	$(INSTALL_DIR) $(1)/usr/share/rpcd/ucode
	$(INSTALL_BIN) ./files/usr/share/rpcd/ucode/shpun.uc \
		$(1)/usr/share/rpcd/ucode/shpun.uc

	# --- ACL ---
	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DATA) ./files/usr/share/rpcd/acl.d/shpun.json \
		$(1)/usr/share/rpcd/acl.d/shpun.json
endef


define Package/shpun-router/postinst
#!/bin/sh
[ -n "$$IPKG_INSTROOT" ] || {
    mkdir -p /etc/shpun
    touch /etc/shpun/first_run

    /etc/init.d/shpun-agent enable 2>/dev/null || true
    /etc/init.d/shpun-agent restart 2>/dev/null || true
    /etc/init.d/shpun-vpn enable 2>/dev/null || true

    /etc/init.d/rpcd restart 2>/dev/null || true

    rm -f /tmp/luci-indexcache /tmp/luci-modulecache/* 2>/dev/null || true
    /etc/init.d/uhttpd reload 2>/dev/null || /etc/init.d/uhttpd restart 2>/dev/null || true
}
exit 0
endef

$(eval $(call BuildPackage,shpun-router))
