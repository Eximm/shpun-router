include $(TOPDIR)/rules.mk

PKG_NAME:=shpun-router
PKG_VERSION:=1.0.0
PKG_RELEASE:=1

PKG_MAINTAINER:=Eximm
PKG_LICENSE:=MIT

include $(INCLUDE_DIR)/package.mk

define Package/shpun-router
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=VPN
  TITLE:=Shpun Router integration (light)
  # Только luci-base, НИКАКИХ curl/bash и т.п.
  DEPENDS:=+luci-base
endef

define Package/shpun-router/description
 Лёгкий пакет Shpun Router:
  * агент привязки роутера к Shpun VPN
  * LuCI-мастер настройки и генерации кода
  * без curl/bash, максимум экономии флеша
endef

# Конфиги (если используешь)
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

# Установка файлов пакета
define Package/shpun-router/install
	# Копируем всё из ./files с сохранением прав
	$(CP) -a ./files/* $(1)/

	# Гарантируем, что init-скрипт исполняемый
	chmod 0755 $(1)/etc/init.d/shpun-agent
endef

# postinst: первый запуск + автозапуск агента
define Package/shpun-router/postinst
#!/bin/sh
[ -n "$$IPKG_INSTROOT" ] || {
    mkdir -p /etc/shpun
    touch /etc/shpun/first_run
    /etc/init.d/shpun-agent enable 2>/dev/null || true
}
exit 0
endef

# Архитектурно независимый пакет (только скрипты/Lua)
PKGARCH:=all

$(eval $(call BuildPackage,shpun-router))
