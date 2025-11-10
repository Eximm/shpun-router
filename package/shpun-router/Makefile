include $(TOPDIR)/rules.mk

PKG_NAME:=shpun-router
PKG_VERSION:=1.0.0
PKG_RELEASE:=1

PKG_MAINTAINER:=Eximm
PKG_LICENSE:=MIT

# Делаем пакет универсальным, чтобы ставился на любые архитектуры
PKGARCH:=all

include $(INCLUDE_DIR)/package.mk

define Package/shpun-router
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=VPN
  TITLE:=Shpun Router integration
  DEPENDS:=+curl +luci-base +luci-compat
endef

define Package/shpun-router/description
 Shpun Router integration package:
  * агент для привязки роутера к Shpun VPN
  * LuCI мастер настройки и генерации кода
endef

# Нам ничего не нужно конфигурировать/компилировать – только скрипты
define Build/Prepare
endef

define Build/Configure
endef

define Build/Compile
endef

# Устанавливаем файлы из ./files в корень файловой системы роутера
define Package/shpun-router/install
	$(INSTALL_DIR) $(1)
	$(CP) ./files/* $(1)/
endef

$(eval $(call BuildPackage,shpun-router))
