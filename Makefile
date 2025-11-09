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

# Никаких исходников не качаем/не конфигурим
define Build/Configure
endef

define Build/Compile
endef

# Устанавливаем файлы из ./files в корень прошивки
define Package/shpun-router/install
	$(INSTALL_DIR) $(1)/
	$(CP) ./files/* $(1)/
endef

# ВАЖНО: именно эта строка создаёт rule package/shpun-router/compile
$(eval $(call BuildPackage,shpun-router))
