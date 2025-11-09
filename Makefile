include $(TOPDIR)/rules.mk

PKG_NAME:=shpun-router
PKG_RELEASE:=1

include $(INCLUDE_DIR)/package.mk

define Package/shpun-router
  SECTION:=utils
  CATEGORY:=Utilities
  TITLE:=Shpun Router Integration
  DEPENDS:=+luci-base
endef

define Package/shpun-router/description
 Shpun VPN router integration: agent + LuCI wizard.
endef

# У нас нет исходников/компиляции — только скрипты и LuCI
define Build/Configure
endef

define Build/Compile
endef

# Кладём всё из ./files в корень образа
define Package/shpun-router/install
	$(INSTALL_DIR) $(1)/
	$(CP) ./files/* $(1)/
endef

# ВОТ ЭТА СТРОКА СОЗДАЁТ RULE package/shpun-router/compile
$(eval $(call BuildPackage,shpun-router))
