include $(TOPDIR)/rules.mk

PKG_NAME:=shpun-router
PKG_VERSION:=1.0.0
PKG_RELEASE:=1

PKG_MAINTAINER:=Eximm
PKG_LICENSE:=MIT

# Универсальный пакет — ставится на любые архитектуры
PKGARCH:=all

include $(INCLUDE_DIR)/package.mk

define Package/shpun-router
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=VPN
  TITLE:=Shpun Router integration (light)
  # НИКАКИХ тяжёлых зависимостей:
  # luci-base и так уже есть на любом роутере с веб-мордой
  DEPENDS:=+luci-base
endef

define Package/shpun-router/description
 Лёгкий пакет Shpun Router:
  * агент привязки роутера к Shpun VPN
  * LuCI-мастер настройки и генерации кода
  * без curl/bash, максимум экономии флеша
endef

# Можно оставить, если реально используешь эти конфиги
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

# Кладём всё из ./files в файловую систему роутера
define Package/shpun-router/install
	$(CP) -a ./files/* $(1)/
endef

# postinst: создаём флаг первого запуска и включаем автозапуск агента
define Package/shpun-router/postinst
#!/bin/sh
[ -n "$$IPKG_INSTROOT" ] || {
    mkdir -p /etc/shpun
    touch /etc/shpun/first_run
    /etc/init.d/shpun-agent enable 2>/dev/null || true
}
exit 0
endef

$(eval $(call BuildPackage,shpun-router))
