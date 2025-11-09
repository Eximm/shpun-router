include $(TOPDIR)/rules.mk

PKG_NAME:=shpun-router
PKG_RELEASE:=1

include $(INCLUDE_DIR)/package.mk

define Package/shpun-router
  SECTION:=utils
  CATEGORY:=Utilities
  TITLE:=Shpun Router Integration
  DEPENDS:=+luci-base +curl
endef

define Package/shpun-router/description
 Shpun VPN router integration: agent + LuCI wizard.
endef

define Build/Configure
endef

define Build/Compile
endef

define Package/shpun-router/install
	$(INSTALL_DIR) $(1)/
	$(CP) ./files/* $(1)/
endef

$(eval $(call BuildPackage,shpun-router))
