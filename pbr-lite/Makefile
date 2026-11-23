#
# pbr-lite -- 精简策略路由内核包（无 UI 也能完整工作）
#
# 纯脚本包，PKGARCH=all。升级本包不会覆盖 /etc/config/pbr-lite（见 conffiles），
# 也不会覆盖生成的 include（那在 /usr/share/nftables.d/ruleset-post/ 下）。
#
include $(TOPDIR)/rules.mk

PKG_NAME:=pbr-lite
PKG_VERSION:=1.0.0
PKG_RELEASE:=1
PKG_LICENSE:=MIT
PKG_MAINTAINER:=gongweijin <gongweijin@banggood.com>
# 注意：这里的 PKGARCH 不生效也要写——真正起作用的是下面 Package 块里的那一行。
PKGARCH:=all

include $(INCLUDE_DIR)/package.mk

# 纯脚本包，没有要编译的东西。但 include/package.mk 给 Build/Compile 留了一个
# 默认实现（在 PKG_BUILD_DIR 里跑 make），而这里根本没有源码和 Makefile，
# 于是一进 compile 阶段就报 "No targets specified and no makefile found"。
# 必须显式清空。
define Build/Compile
endef

define Package/pbr-lite
  SECTION:=net
  CATEGORY:=Network
  TITLE:=Lightweight policy based routing (non-CN traffic via a side router)
  URL:=https://github.com/GN01/pbr-lite
  DEPENDS:=+nftables +curl +ca-bundle +firewall4 +ip-tiny +kmod-nft-core +kmod-nft-nat
  # 架构无关，必须写在 Package 块里。include/package-defaults.mk 的
  # Package/Default 会无条件 PKGARCH:=$(ARCH_PACKAGES)，把顶层的赋值冲掉——
  # 只写顶层的话编出来的包是 Architecture: x86_64，装到 aarch64 路由器上
  # 会被 opkg 以架构不符拒掉。（luci.mk 也是写在 Package 块里的。）
  PKGARCH:=all
endef

define Package/pbr-lite/description
  pbr-lite 是一个「精简版策略路由」：把指定的源地址访问非中国 IP 的流量打上
  firewall mark，再由一条 ip rule 送进独立路由表，走旁路由（例如 dae / clash）。
  中国 IP 与内网保留段直连，不经过旁路由。

  和 pbr 的区别：pbr 会把上万条 CIDR 逐行拼成 nft 规则，一万条要几十秒；
  pbr-lite 只在内容变化时重新生成一份 include，交给 fw4 一次性装载，
  单事务、无「不打标」窗口，日常维护量为零。

  两个能力边界：
    * 只做 IPv4；
    * 只做「按源地址分流」，不做域名分流（那是 dae 的活）。
endef

define Package/pbr-lite/conffiles
/etc/config/pbr-lite
endef

define Package/pbr-lite/install
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/etc/config/pbr-lite $(1)/etc/config/pbr-lite

	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/etc/init.d/pbr-lite $(1)/etc/init.d/pbr-lite

	$(INSTALL_DIR) $(1)/etc/hotplug.d/iface
	$(INSTALL_BIN) ./files/etc/hotplug.d/iface/99-pbr-lite $(1)/etc/hotplug.d/iface/99-pbr-lite

	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) ./files/etc/uci-defaults/90-pbr-lite-firstrun $(1)/etc/uci-defaults/90-pbr-lite-firstrun

	$(INSTALL_DIR) $(1)/usr/sbin
	$(INSTALL_BIN) ./files/usr/sbin/pbr-lite-update $(1)/usr/sbin/pbr-lite-update

	$(INSTALL_DIR) $(1)/usr/share/pbr-lite
	$(INSTALL_DATA) ./files/usr/share/pbr-lite/lib.sh $(1)/usr/share/pbr-lite/lib.sh
	$(INSTALL_BIN) ./files/usr/share/pbr-lite/job.sh $(1)/usr/share/pbr-lite/job.sh
	$(INSTALL_DATA) ./files/usr/share/pbr-lite/gen-not-cn.awk $(1)/usr/share/pbr-lite/gen-not-cn.awk
	$(INSTALL_DATA) ./files/usr/share/pbr-lite/exclude.txt $(1)/usr/share/pbr-lite/exclude.txt
	$(INSTALL_BIN) ./files/usr/share/pbr-lite/conf-export.sh $(1)/usr/share/pbr-lite/conf-export.sh
	$(INSTALL_BIN) ./files/usr/share/pbr-lite/verify.sh $(1)/usr/share/pbr-lite/verify.sh
	$(INSTALL_BIN) ./files/usr/share/pbr-lite/status.sh $(1)/usr/share/pbr-lite/status.sh
	$(INSTALL_BIN) ./files/usr/share/pbr-lite/lookup-ip.sh $(1)/usr/share/pbr-lite/lookup-ip.sh
	$(INSTALL_BIN) ./files/usr/share/pbr-lite/diag.sh $(1)/usr/share/pbr-lite/diag.sh
	$(INSTALL_BIN) ./files/usr/share/pbr-lite/peer-info.sh $(1)/usr/share/pbr-lite/peer-info.sh
endef

# 装完立刻 enable 并尝试生成一次规则（后台，不阻塞 opkg）。
# 生成失败也无所谓：没有任何规则时就是「全部直连」，上网不受影响，
# 下一次 cron 或手动跑一次 pbr-lite-update 就补上了。
define Package/pbr-lite/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
/etc/init.d/pbr-lite enable >/dev/null 2>&1
exit 0
endef

define Package/pbr-lite/prerm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
/etc/init.d/pbr-lite stop >/dev/null 2>&1
/etc/init.d/pbr-lite disable >/dev/null 2>&1
exit 0
endef

$(eval $(call BuildPackage,pbr-lite))
