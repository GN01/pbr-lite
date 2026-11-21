#!/bin/sh
# migrate.sh -- 把旧的 sdwan 脚本安装迁移成 pbr-lite
#
# 这是一次性脚本，跑之前请先看一眼它做什么。它按下面的顺序保证「不出现无规则窗口」：
#
#   1. 备份所有旧文件到 /root/pbr-lite-migrate-<时间戳>/
#   2. 读 /etc/sdwan.conf 生成 /etc/config/pbr-lite（UCI）
#   3. 把旧 include 30-sdwan.nft 改名成 .disabled（移出 ruleset-post）
#      —— 注意：改名不会影响内核里已经装载的规则，fw4 不 reload 就不会变
#   4. 跑 pbr-lite-update：生成新 include -> fw4 只 reload 一次 -> 精确校验
#      校验失败会自动回滚新文件；本脚本随后把旧 include 改回来
#   5. 成功后才摘掉旧组件：init.d 符号链接、hotplug、脚本、cron 行
#   6. 最后跑一遍 verify.sh 出结论
#
# 任何一步失败都停在原地，不会把系统留在「两边都没有」的状态。
#
# 用法：
#   sh /usr/share/pbr-lite/migrate.sh --prepare-only   # 只生成 UCI 配置，不动线上规则
#   sh /usr/share/pbr-lite/migrate.sh                  # 完整迁移

set -u

PREPARE_ONLY=0
for _a in "$@"; do
    case "$_a" in
        --prepare-only) PREPARE_ONLY=1 ;;
        -h|--help) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown arg: $_a" >&2; exit 2 ;;
    esac
done

STAMP=$(date +%Y%m%d-%H%M%S)
BAK="/root/pbr-lite-migrate-$STAMP"
OLD_CONF='/etc/sdwan.conf'
OLD_INC='/usr/share/nftables.d/ruleset-post/30-sdwan.nft'
NEW_INC='/usr/share/nftables.d/ruleset-post/30-pbr-lite.nft'
UCI_NAME='pbr-lite'

say()  { printf '[migrate] %s\n' "$*"; }
die()  { printf '[migrate] 失败：%s\n' "$*" >&2; exit 1; }

[ "$(id -u)" = '0' ] || die '必须 root 运行'

if [ ! -f "$OLD_CONF" ] && [ -f "/etc/config/$UCI_NAME" ]; then
    say '看起来已经迁移过（没有 /etc/sdwan.conf，但 UCI 配置在），退出'
    exit 0
fi
[ -f "$OLD_CONF" ] || die "$OLD_CONF 不存在，无法确定分流来源地址"

# ---------------------------------------------------------------- 1. 备份
mkdir -p "$BAK" || die "无法创建备份目录 $BAK"
for f in "$OLD_CONF" /usr/sbin/sdwan-list-update /usr/share/sdwan \
         /etc/init.d/sdwan-route /etc/hotplug.d/iface/99-sdwan "$OLD_INC"; do
    [ -e "$f" ] && cp -a "$f" "$BAK/" 2>/dev/null
done
crontab -l > "$BAK/crontab.txt" 2>/dev/null
cp -a /etc/iproute2/rt_tables "$BAK/rt_tables" 2>/dev/null
say "旧文件已备份到 $BAK"

# ---------------------------------------------------------------- 2. 生成 UCI
# shellcheck disable=SC1090
. "$OLD_CONF" 2>/dev/null || die "$OLD_CONF 语法有误"
[ -n "${SRC_ADDRS:-}" ] || die "旧配置里 SRC_ADDRS 为空"

rm -f "/etc/config/$UCI_NAME"
touch "/etc/config/$UCI_NAME" || die "无法写 /etc/config/$UCI_NAME"

uci -q set "$UCI_NAME.main=pbrlite" || die 'uci set 失败'
uci -q set "$UCI_NAME.main.enabled=1"

uci -q set "$UCI_NAME.lan=lan"
for _ip in $SRC_ADDRS; do
    uci -q add_list "$UCI_NAME.lan.src_addr=$_ip"
done

uci -q set "$UCI_NAME.dae=dae"
uci -q set "$UCI_NAME.dae.mac=$DAE_MAC"
uci -q set "$UCI_NAME.dae.next_hop=192.168.0.253"
uci -q set "$UCI_NAME.dae.lan_dev=br-lan"

uci -q set "$UCI_NAME.mark=mark"
uci -q set "$UCI_NAME.mark.value=$MARK_VALUE"
uci -q set "$UCI_NAME.mark.keep_mask=$MARK_MASK"

uci -q set "$UCI_NAME.source=source"
uci -q set "$UCI_NAME.source.url=$SRC_URL"
uci -q set "$UCI_NAME.source.min_entries=5000"
uci -q set "$UCI_NAME.source.max_drift=40"

uci -q set "$UCI_NAME.direct=direct"

uci -q set "$UCI_NAME.nft=nft"
uci -q set "$UCI_NAME.nft.set_src=pbrlite_src"
uci -q set "$UCI_NAME.nft.set_dst=pbrlite_notcn"
uci -q set "$UCI_NAME.nft.include=$NEW_INC"

uci -q set "$UCI_NAME.route=route"
uci -q set "$UCI_NAME.route.table_id=250"
uci -q set "$UCI_NAME.route.table_name=pbrlite"
uci -q set "$UCI_NAME.route.pref=28000"

uci -q set "$UCI_NAME.guard=guard"
uci -q set "$UCI_NAME.guard.enabled=1"

uci -q commit "$UCI_NAME" || die 'uci commit 失败'
say '已生成 /etc/config/pbr-lite'
say "  源地址: $SRC_ADDRS"
say "  旁路由: $DAE_MAC / 192.168.0.253"

# 导出一次，后面 init.d 与更新器都依赖它
/usr/share/pbr-lite/conf-export.sh || die 'conf-export.sh 失败'
[ -f /var/run/pbr-lite.conf ] || die '/var/run/pbr-lite.conf 没生成'

if [ "$PREPARE_ONLY" = '1' ]; then
    say '--prepare-only：只准备好配置，线上规则一点没动'
    echo '--- /var/run/pbr-lite.conf ---'
    cat /var/run/pbr-lite.conf
    exit 0
fi

# ---------------------------------------------------------------- 3. 摘掉旧 include
HAD_OLD_INC=0
if [ -f "$OLD_INC" ]; then
    mv -f "$OLD_INC" "$OLD_INC.disabled" || die "无法移走 $OLD_INC"
    HAD_OLD_INC=1
    say "旧 include 已改名为 $(basename "$OLD_INC").disabled（内核规则未受影响）"
fi

# ---------------------------------------------------------------- 4. 生成并装载
say '生成新规则并装载（会 fw4 reload 一次）...'
if ! /usr/sbin/pbr-lite-update --force; then
    say '新规则装载失败，回滚到旧 include'
    [ "$HAD_OLD_INC" = '1' ] && mv -f "$OLD_INC.disabled" "$OLD_INC"
    fw4 -q reload
    die "装载失败（已恢复旧 include 并 reload，系统应仍在原状态下工作）"
fi

if [ ! -f "$NEW_INC" ]; then
    [ "$HAD_OLD_INC" = '1' ] && mv -f "$OLD_INC.disabled" "$OLD_INC" && fw4 -q reload
    die "新 include 没生成"
fi

# ---------------------------------------------------------------- 5. 切路由层 + 摘旧组件
# 顺序很关键：先起新的，再拆旧的，而且**绝不调用旧 init 的 stop**。
# 旧 sdwan-route 的 stop 会 `ip rule del pref 28000` + `ip route flush table 250`，
# 那正是新层要用的同一个 pref 和同一张表 —— 调它等于把刚装好的路由层一起拆了。
# 两边 pref / 表号 / 下一跳完全一致，pbr-lite start 内部是 route replace + rule del/add，
# 纯幂等覆盖，全程没有「打了标却找不到下一跳」的窗口。
say '装载成功，把路由层切到 pbr-lite'
/etc/init.d/pbr-lite enable >/dev/null 2>&1
if ! /etc/init.d/pbr-lite start; then
    say 'pbr-lite start 失败，停在原地：新规则已装载，旧 sdwan-route 仍完好（两者等价）'
    die "路由层没切过去。排查：/etc/init.d/pbr-lite start; logread -e pbr-lite"
fi
say '路由层已切换，摘掉旧组件'
/etc/init.d/sdwan-route disable >/dev/null 2>&1
rm -f /etc/rc.d/S99sdwan-route /etc/rc.d/K10sdwan-route
rm -f /etc/hotplug.d/iface/99-sdwan
rm -f /etc/init.d/sdwan-route

# cron：把旧命令换成新的，其余行原样保留
if crontab -l 2>/dev/null | grep -q 'sdwan-list-update'; then
    crontab -l 2>/dev/null \
        | sed 's#/usr/sbin/sdwan-list-update#/usr/sbin/pbr-lite-update#g' \
        | crontab -
    say 'cron 已切换到 pbr-lite-update'
fi

# 旧脚本与旧配置：留着会让人以为还在用
rm -f /usr/sbin/sdwan-list-update
rm -rf /usr/share/sdwan
mv -f "$OLD_CONF" "$BAK/sdwan.conf.migrated"
rm -f "$OLD_INC.disabled"

# ---------------------------------------------------------------- 6. 结论
say '迁移完成，开始自检'
echo
/usr/share/pbr-lite/verify.sh
RC=$?
echo
if [ "$RC" -eq 0 ]; then
    say "自检通过。备份在 $BAK（确认没问题后可以删）"
else
    say "自检有 FAIL，先别删备份：$BAK"
fi
exit "$RC"
