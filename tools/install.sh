#!/bin/sh
# tools/install.sh -- 不编译、直接铺文件的安装/卸载脚本
#
# 用法：
#   sh tools/install.sh              # 安装（覆盖同名文件，保留 /etc/config/pbr-lite）
#   sh tools/install.sh --uninstall  # 卸载（保留配置与生成的 include）
#
# 这个脚本只为「不想装 SDK 编译」的人准备。正式使用建议走 opkg，能享受升级与卸载记录。
set -u

SRC=$(cd "$(dirname "$0")/.." && pwd)
CORE="$SRC/pbr-lite/files"
LUCI="$SRC/luci-app-pbr-lite"

UNINSTALL=0
case "${1:-}" in
    --uninstall) UNINSTALL=1 ;;
    '' ) ;;
    -h|--help) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "未知参数：$1" >&2; exit 2 ;;
esac

[ "$(id -u)" = '0' ] || { echo '需要 root 运行' >&2; exit 1; }
[ -d "$CORE" ] || { echo "找不到 $CORE（请在仓库根目录运行）" >&2; exit 1; }

say() { printf '[install] %s\n' "$*"; }

if [ "$UNINSTALL" = '1' ]; then
    say '停用服务'
    /etc/init.d/pbr-lite stop    >/dev/null 2>&1
    /etc/init.d/pbr-lite disable >/dev/null 2>&1

    say '删除程序文件（保留 /etc/config/pbr-lite 与生成的 include）'
    rm -f /usr/sbin/pbr-lite-update
    rm -f /usr/share/pbr-lite/lib.sh /usr/share/pbr-lite/conf-export.sh \
          /usr/share/pbr-lite/gen-not-cn.awk /usr/share/pbr-lite/exclude.txt \
          /usr/share/pbr-lite/verify.sh /usr/share/pbr-lite/status.sh \
          /usr/share/pbr-lite/lookup-ip.sh /usr/share/pbr-lite/job.sh \
          /usr/share/pbr-lite/diag.sh /usr/share/pbr-lite/peer-info.sh
    rm -f /etc/init.d/pbr-lite /etc/hotplug.d/iface/99-pbr-lite \
          /etc/uci-defaults/90-pbr-lite-firstrun
    rm -f /www/luci-static/resources/view/pbr-lite/*.js
    rm -f /www/luci-static/resources/pbr-lite/common.js
    rmdir /www/luci-static/resources/view/pbr-lite /www/luci-static/resources/pbr-lite 2>/dev/null
    rm -f /usr/share/luci/menu.d/luci-app-pbr-lite.json \
          /usr/share/rpcd/acl.d/luci-app-pbr-lite.json \
          /usr/share/rpcd/ucode/pbr-lite
    rm -f /tmp/luci-indexcache*
    /etc/init.d/rpcd restart >/dev/null 2>&1
    say '已卸载。注意：cron 里的 pbr-lite-update 行需要自己删，nft 集合与 ip rule 也仍然在'
    exit 0
fi

say "从 $SRC 安装"

# ---- 内核包：files/ 就是根目录结构 ----
mkdir -p /etc/config /etc/init.d /etc/hotplug.d/iface /etc/uci-defaults \
         /usr/sbin /usr/share/pbr-lite
if [ -f /etc/config/pbr-lite ]; then
    say '已存在 /etc/config/pbr-lite，保留原配置不覆盖'
else
    cp -f "$CORE/etc/config/pbr-lite" /etc/config/pbr-lite
fi

cp -f "$CORE/etc/init.d/pbr-lite"              /etc/init.d/pbr-lite
cp -f "$CORE/etc/hotplug.d/iface/99-pbr-lite"  /etc/hotplug.d/iface/99-pbr-lite
cp -f "$CORE/etc/uci-defaults/90-pbr-lite-firstrun" /etc/uci-defaults/90-pbr-lite-firstrun
cp -f "$CORE/usr/sbin/pbr-lite-update"         /usr/sbin/pbr-lite-update

for f in lib.sh gen-not-cn.awk exclude.txt conf-export.sh verify.sh status.sh lookup-ip.sh job.sh diag.sh peer-info.sh; do
    cp -f "$CORE/usr/share/pbr-lite/$f" "/usr/share/pbr-lite/$f"
done

chmod 755 /etc/init.d/pbr-lite /etc/hotplug.d/iface/99-pbr-lite \
          /etc/uci-defaults/90-pbr-lite-firstrun /usr/sbin/pbr-lite-update \
          /usr/share/pbr-lite/conf-export.sh /usr/share/pbr-lite/verify.sh \
          /usr/share/pbr-lite/status.sh /usr/share/pbr-lite/lookup-ip.sh \
          /usr/share/pbr-lite/job.sh /usr/share/pbr-lite/diag.sh \
          /usr/share/pbr-lite/peer-info.sh
chmod 644 /usr/share/pbr-lite/lib.sh /usr/share/pbr-lite/gen-not-cn.awk \
          /usr/share/pbr-lite/exclude.txt

# ---- LuCI 包 ----
if [ -d "$LUCI" ]; then
    mkdir -p /www/luci-static/resources/view/pbr-lite \
             /www/luci-static/resources/pbr-lite \
             /usr/share/luci/menu.d /usr/share/rpcd/acl.d /usr/share/rpcd/ucode
    for f in overview settings advanced source diagnostics; do
        cp -f "$LUCI/htdocs/luci-static/resources/view/pbr-lite/$f.js" \
              "/www/luci-static/resources/view/pbr-lite/$f.js"
    done
    cp -f "$LUCI/htdocs/luci-static/resources/pbr-lite/common.js" \
          /www/luci-static/resources/pbr-lite/common.js
    cp -f "$LUCI/root/usr/share/luci/menu.d/luci-app-pbr-lite.json" \
          /usr/share/luci/menu.d/luci-app-pbr-lite.json
    cp -f "$LUCI/root/usr/share/rpcd/acl.d/luci-app-pbr-lite.json" \
          /usr/share/rpcd/acl.d/luci-app-pbr-lite.json
    cp -f "$LUCI/root/usr/share/rpcd/ucode/pbr-lite" \
          /usr/share/rpcd/ucode/pbr-lite
    chmod 644 /www/luci-static/resources/view/pbr-lite/*.js \
              /www/luci-static/resources/pbr-lite/common.js \
              /usr/share/luci/menu.d/luci-app-pbr-lite.json \
              /usr/share/rpcd/acl.d/luci-app-pbr-lite.json \
              /usr/share/rpcd/ucode/pbr-lite
    rm -f /tmp/luci-indexcache*
    /etc/init.d/rpcd restart >/dev/null 2>&1   # reload 在这个 init 脚本里只发 SIGHUP，不重读插件
    say 'LuCI 界面已装好（服务 → PBR Lite）'
fi

/etc/init.d/pbr-lite enable >/dev/null 2>&1
say '已设置开机自启'

# 还没生成过 include 就先跑一次，失败也不影响上网（没有规则=全部直连）
if [ ! -f /usr/share/nftables.d/ruleset-post/30-pbr-lite.nft ]; then
    say '首次生成规则（约 15 秒）…'
    /usr/sbin/pbr-lite-update --force || say '生成失败，稍后手动跑 /usr/sbin/pbr-lite-update'
fi

echo
say '完成。下一步：'
cat <<'EOF'
  1) 改配置：uci set pbr-lite.lan.src_addr=... / pbr-lite.dae.next_hop=... / pbr-lite.dae.mac=...
  2) uci commit pbr-lite && /usr/share/pbr-lite/conf-export.sh
  3) /usr/sbin/pbr-lite-update --force
  4) /usr/share/pbr-lite/verify.sh
  5) 加 cron：17 4 * * * /usr/sbin/pbr-lite-update
EOF
