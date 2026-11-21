#!/bin/sh
# conf-export.sh -- 把 UCI 配置导出成 shell 变量，供更新器 / 校验 / init.d source
#
# 为什么要有这一层：
#   现有三个 shell 脚本全靠 `source /etc/sdwan.conf` 拿变量。UCI 化之后如果直接改
#   这三个脚本去调 uci，等于把「配置怎么读」这件事复制三份，迟早不一致。
#   这里做唯一入口：UCI -> /var/run/pbr-lite.conf（shell 变量），其余脚本只认导出的文件。
#
# 另外一个好处：/var/run 是 tmpfs，改配置不会磨损 flash；且导出文件是「上一次成功
# 解析的结果」，即使 UCI 被改坏，也能从系统的前一份导出继续跑（配合 state 排障）。
#
# 用法：
#   conf-export.sh              # 写到默认位置
#   conf-export.sh /tmp/x.conf  # 写到指定位置（调试用）
set -u

UCI_NAME='pbr-lite'
OUT="${1:-/var/run/pbr-lite.conf}"
DIRECT_OUT='/var/run/pbr-lite-direct.txt'
SELF_DIR=$(dirname "$0")

die() { echo "[conf-export] $*" >&2; exit 1; }

command -v uci >/dev/null 2>&1 || die 'uci 不存在'
uci -q show "$UCI_NAME" >/dev/null 2>&1 || die "/etc/config/$UCI_NAME 不存在或为空"

g() { uci -q get "$UCI_NAME.$1" 2>/dev/null; }
d() { _v=$(g "$1"); [ -n "$_v" ] || _v="$2"; printf '%s' "$_v"; }

# ---- 开关 ----
ENABLED=$(d main.enabled '1')
[ "$ENABLED" = '1' ] || ENABLED=0
GUARD=$(d guard.enabled '1')
[ "$GUARD" = '1' ] || GUARD=0

# ---- 源地址（UCI list，uci get 会返回空格分隔）----
SRC_ADDRS=$(g lan.src_addr)
[ -n "$SRC_ADDRS" ] || SRC_ADDRS=''

# ---- 旁路由 ----
DAE_MAC=$(d dae.mac '')
NEXT_HOP=$(d dae.next_hop '192.168.0.253')
LAN_DEV=$(d dae.lan_dev 'br-lan')

# ---- mark ----
MARK_VALUE=$(d mark.value '0x010000')
MARK_MASK=$(d mark.keep_mask '0xff00ffff')

# ---- 列表来源 ----
SRC_URL=$(d source.url 'https://ispip.clang.cn/all_cn.txt')
MIN_ENTRIES=$(d source.min_entries '5000')
MAX_DRIFT=$(d source.max_drift '40')

# ---- nft 对象 ----
SET_SRC=$(d nft.set_src 'pbrlite_src')
SET_DST=$(d nft.set_dst 'pbrlite_notcn')
INCLUDE=$(d nft.include '/usr/share/nftables.d/ruleset-post/30-pbr-lite.nft')

# ---- 路由层 ----
TABLE_ID=$(d route.table_id '250')
TABLE_NAME=$(d route.table_name 'pbrlite')
PREF=$(d route.pref '28000')

# ---- 派生：ip rule 的 fwmark 值/掩码，从 MARK_MASK 反推 ----
# 这两个值以前在 init.d 里硬编码，和 nft 的 MARK_MASK 是「同一件事的两个写法」，
# 改一处忘另一处就会出现「打了标但 ip rule 看不见」。现在只保留一个来源。
. "$SELF_DIR/lib.sh"
MATCH_VALUE="$MARK_VALUE"
MATCH_MASK=$(pl_match_mask "$MARK_MASK" 2>/dev/null)
[ -n "${MATCH_MASK:-}" ] || MATCH_MASK='0xff0000'

# ---- 直连白名单（UCI list）----
DIRECT_DST=$(g direct.dst 2>/dev/null || true)
[ -n "$DIRECT_DST" ] || DIRECT_DST=''

# ---- 输出：直连白名单文件（gen-not-cn.awk 读它）----
: > "${DIRECT_OUT}.tmp" || die "无法写 $DIRECT_OUT"
for _e in $DIRECT_DST; do
    case "$_e" in
        */*) printf '%s\n' "$_e" >> "${DIRECT_OUT}.tmp" ;;
        *)   printf '%s/32\n' "$_e" >> "${DIRECT_OUT}.tmp" ;;
    esac
done
mv -f "${DIRECT_OUT}.tmp" "$DIRECT_OUT" || die "写入 $DIRECT_OUT 失败"

# ---- 输出：shell 变量文件 ----
{
    echo "# 由 conf-export.sh 从 /etc/config/$UCI_NAME 生成于 $(pl_human)"
    echo "# 不要手工编辑：改配置请用 uci / LuCI，然后重跑 conf-export.sh"
    echo "ENABLED='$ENABLED'"
    echo "GUARD='$GUARD'"
    echo "SRC_ADDRS='$SRC_ADDRS'"
    echo "DAE_MAC='$DAE_MAC'"
    echo "NEXT_HOP='$NEXT_HOP'"
    echo "LAN_DEV='$LAN_DEV'"
    echo "MARK_VALUE='$MARK_VALUE'"
    echo "MARK_MASK='$MARK_MASK'"
    echo "MATCH_VALUE='$MATCH_VALUE'"
    echo "MATCH_MASK='$MATCH_MASK'"
    echo "SRC_URL='$SRC_URL'"
    echo "MIN_ENTRIES='$MIN_ENTRIES'"
    echo "MAX_DRIFT='$MAX_DRIFT'"
    echo "SET_SRC='$SET_SRC'"
    echo "SET_DST='$SET_DST'"
    echo "INCLUDE='$INCLUDE'"
    echo "TABLE_ID='$TABLE_ID'"
    echo "TABLE_NAME='$TABLE_NAME'"
    echo "PREF='$PREF'"
    echo "DIRECT_DST='$DIRECT_DST'"
    echo "DIRECT_FILE='$DIRECT_OUT'"
} > "${OUT}.tmp" || die "无法写 $OUT"
mv -f "${OUT}.tmp" "$OUT" || die "写入 $OUT 失败"

# 语法自检：导出文件必须能被 sh 解析，否则后面所有脚本会莫名其妙地半途而废
sh -n "$OUT" 2>/dev/null || die "导出的 $OUT 语法有问题（配置里有引号/换行的值？）"

exit 0
