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
  DEPENDS:=+curl +bash +luci-base +luci-compat +luci-lib-jsonc
endef

define Package/shpun-router/description
 Shpun Router integration package:
  * агент для привязки роутера к Shpun VPN
  * LuCI мастер настройки и генерации кода
endef

# Какие файлы считаем конфигами (не стирать при обновлении)
define Package/shpun-router/conffiles
/etc/config/shpun
/etc/shpun/agent.conf
endef

# Ничего не готовим/не компилируем – только скрипты и файлы
define Build/Prepare
endef

define Build/Configure
endef

define Build/Compile
endef

# Разворачиваем содержимое ./files в корень ФС роутера
define Package/shpun-router/install
	$(INSTALL_DIR) $(1)
	$(CP) ./files/* $(1)/
endef

# postinst: выполняется сразу после установки пакета
# создаём флаг первого запуска и включаем автозапуск агента
define Package/shpun-router/postinst
#!/bin/sh
[ -n "$$IPKG_INSTROOT" ] || {
    mkdir -p /etc/shpun
    touch /etc/shpun/first_run

    # включить автозапуск агента, если он есть
    /etc/init.d/shpun-agent enable 2>/dev/null || true

    # если хочешь авт ребут после установки – раскомментируй:
    # reboot &
}
exit 0
endef

$(eval $(call BuildPackage,shpun-router))
