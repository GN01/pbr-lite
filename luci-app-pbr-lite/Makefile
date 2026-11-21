#
# luci-app-pbr-lite -- pbr-lite 的 LuCI 界面（纯界面层）
#
# 界面出问题不该影响分流：本包只提供 JS 视图 + 一个 rpcd ucode 插件，
# 不往系统里装任何会改变数据面的东西。卸载它，分流照常工作。
#
# 这里不用 feeds/luci/luci.mk，而是走标准 package.mk，好处是这个包放进任何
# 目录（feed 或 package/ 下）都能编，不依赖 luci feed 的具体路径。
#
include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-pbr-lite
PKG_VERSION:=1.0.0
PKG_RELEASE:=1
PKG_LICENSE:=MIT
PKG_MAINTAINER:=gongweijin <gongweijin@banggood.com>
PKGARCH:=all

include $(INCLUDE_DIR)/package.mk

define Package/luci-app-pbr-lite
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=LuCI support for PBR Lite
  URL:=https://github.com/gongweijin/pbr-lite
  DEPENDS:=+luci-base +rpcd-mod-ucode +ucode-mod-uci +pbr-lite
endef

define Package/luci-app-pbr-lite/description
  在「服务」菜单下给 pbr-lite 提供三个页面：
    概览     -- 运行状态、文件与内核的数据一致性、打标/兜底计数、ARP 健康、9 组自检
    分流设置 -- 开关、生效地址、直连白名单、旁路由、打标值、路由表、nft 对象
    规则源   -- 列表地址、条目下限/漂移阈值、立即更新、备份回滚

  长任务（重建规则 10 秒级）不在请求里同步跑：ubus 只做校验+落配置+起任务，
  页面轮询进度。配置写坏会自动回滚到改动前那一份。
endef

define Package/luci-app-pbr-lite/install
	$(INSTALL_DIR) $(1)/www/luci-static/resources/view/pbr-lite
	$(INSTALL_DATA) ./htdocs/luci-static/resources/view/pbr-lite/overview.js \
		$(1)/www/luci-static/resources/view/pbr-lite/overview.js
	$(INSTALL_DATA) ./htdocs/luci-static/resources/view/pbr-lite/settings.js \
		$(1)/www/luci-static/resources/view/pbr-lite/settings.js
	$(INSTALL_DATA) ./htdocs/luci-static/resources/view/pbr-lite/source.js \
		$(1)/www/luci-static/resources/view/pbr-lite/source.js
	$(INSTALL_DATA) ./htdocs/luci-static/resources/view/pbr-lite/advanced.js \
		$(1)/www/luci-static/resources/view/pbr-lite/advanced.js
	$(INSTALL_DATA) ./htdocs/luci-static/resources/view/pbr-lite/diagnostics.js \
		$(1)/www/luci-static/resources/view/pbr-lite/diagnostics.js

	$(INSTALL_DIR) $(1)/www/luci-static/resources/pbr-lite
	$(INSTALL_DATA) ./htdocs/luci-static/resources/pbr-lite/common.js \
		$(1)/www/luci-static/resources/pbr-lite/common.js

	$(INSTALL_DIR) $(1)/usr/share/luci/menu.d
	$(INSTALL_DATA) ./root/usr/share/luci/menu.d/luci-app-pbr-lite.json \
		$(1)/usr/share/luci/menu.d/luci-app-pbr-lite.json

	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DATA) ./root/usr/share/rpcd/acl.d/luci-app-pbr-lite.json \
		$(1)/usr/share/rpcd/acl.d/luci-app-pbr-lite.json

	$(INSTALL_DIR) $(1)/usr/share/rpcd/ucode
	$(INSTALL_DATA) ./root/usr/share/rpcd/ucode/pbr-lite \
		$(1)/usr/share/rpcd/ucode/pbr-lite

	# i18n：界面文案的 msgid 本身就是简体中文，所以不编 .lmo 也能正常显示。
	# 这里只在 buildroot 里确实有 po2lmo 时才编——没有就静默跳过，
	# 不把「能不能翻译」变成「能不能装」的前提。
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/i18n
	-for po in ./po/*/*.po; do \
		[ -f "$$po" ] || continue; \
		lang=$$(basename $$(dirname "$$po")); \
		$(STAGING_DIR_HOST)/bin/po2lmo "$$po" \
			"$(1)/usr/lib/lua/luci/i18n/luci-app-pbr-lite.$$lang.lmo" || true; \
	done
endef

define Package/luci-app-pbr-lite/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	rm -f /tmp/luci-indexcache* 2>/dev/null
	/etc/init.d/rpcd reload >/dev/null 2>&1
}
exit 0
endef

define Package/luci-app-pbr-lite/postrm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	rm -f /tmp/luci-indexcache* 2>/dev/null
	/etc/init.d/rpcd reload >/dev/null 2>&1
}
exit 0
endef

$(eval $(call BuildPackage,luci-app-pbr-lite))
