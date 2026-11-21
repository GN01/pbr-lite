#!/bin/sh
# diag.sh -- pbr-lite 诊断信息采集
#
# 目的：出问题时不用先 SSH 上去，界面上一眼看到「规则长什么样、日志说了什么」，
# 拿不准就下一份诊断包贴到 issue 里。
#
# 只读：不改配置、不 reload、不加锁。可以随时跑。
#
# 用法：
#   diag.sh --json      结构化输出，给 LuCI 页面用
#   diag.sh --bundle    纯文本报告，给「下载诊断包」用
#
# 输出里刻意**不含**那 1.1 万条 CIDR：include 只给头部若干行看结构，
# 集合内容走 lookup-ip.sh 单点查。诊断包也是同样的原则。
set -u

SHARE_DIR=${SHARE_DIR:-/usr/share/pbr-lite}
. "$SHARE_DIR/lib.sh"

JSON=0; BUNDLE=0
for a in "$@"; do
    case "$a" in
        --json)   JSON=1 ;;
        --bundle) BUNDLE=1 ;;
        -h|--help) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown arg: $a" >&2; exit 2 ;;
    esac
done

[ -f "$PL_CONF" ] && . "$PL_CONF"
INCLUDE="${INCLUDE:-$PL_INCLUDE}"

HEAD_LINES=40        # 页面预览
BUNDLE_HEAD=200      # 诊断包里多给一点
LOG_LINES=60

# ---------------------------------------------------------------- 采集
_ts=$(date +%s)
# OpenWrt 通常没有 /etc/hostname，退回 uname -n / uci
_host=$(cat /etc/hostname 2>/dev/null)
[ -n "$_host" ] || _host=$(uname -n 2>/dev/null)
[ -n "$_host" ] || _host=$(uci -q get system.@system[0].hostname 2>/dev/null)
[ -n "$_host" ] || _host='?'
_rel=$(sed -n "s/^DISTRIB_RELEASE='\(.*\)'/\1/p" /etc/openwrt_release 2>/dev/null | head -1)
_tgt=$(sed -n "s/^DISTRIB_TARGET='\(.*\)'/\1/p" /etc/openwrt_release 2>/dev/null | head -1)
_model=$(sed -n "s/^DISTRIB_DESCRIPTION='\(.*\)'/\1/p" /etc/openwrt_release 2>/dev/null | head -1)
_model="${_model:-?}${_rel:+ ${_rel}}${_tgt:+ (${_tgt})}"
_kern=$(uname -sr 2>/dev/null)
_up=$(cut -d' ' -f1 /proc/uptime 2>/dev/null)

# include 头部：只看结构（add set 行 + 前几条元素），不上万行
if [ -f "$INCLUDE" ]; then
    _inc_exists=1
    _inc_bytes=$(wc -c < "$INCLUDE" 2>/dev/null | tr -d ' ')
    _inc_lines=$(wc -l < "$INCLUDE" 2>/dev/null | tr -d ' ')
    _inc_head=$(sed -n "1,${HEAD_LINES}p" "$INCLUDE" 2>/dev/null)
else
    _inc_exists=0; _inc_bytes=0; _inc_lines=0; _inc_head=''
fi

# 两条规则原文（打标 + 兜底 drop）。两个都引用 @$SET_DST，一网打尽。
_ch=$(nft list chain inet fw4 mangle_prerouting 2>/dev/null)
_rules=$(printf '%s\n' "$_ch" | grep -F "@${SET_DST}" 2>/dev/null)

# 日志：pbr-lite 自己的 + fw4 的报错，两边都要看
_log=$(logread 2>/dev/null | grep -iE 'pbr-lite|fw4|nft' | tail -n "$LOG_LINES")

_env="主机      ${_host}
系统      ${_model:-?}
内核      ${_kern:-?}
运行时长  ${_up:-?} 秒
nft       $(nft --version 2>/dev/null | head -1)
设置      源集合 @${SET_SRC}  目标集合 @${SET_DST}  路由表 ${TABLE_ID}(${TABLE_NAME})  优先级 ${PREF}
下一步    ${NEXT_HOP} via ${LAN_DEV}  打标 ${MARK_VALUE}/${MATCH_VALUE}"

# ---------------------------------------------------------------- 诊断包
if [ "$BUNDLE" = '1' ]; then
    printf 'pbr-lite 诊断包\n'
    printf '生成时间  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    printf '════════════════════════════════════════════════════════\n\n'

    printf '## 1. 环境\n%s\n\n' "$_env"

    printf '## 2. UCI 配置\n'
    uci -q show pbr-lite 2>/dev/null
    printf '\n'

    printf '## 3. 导出变量（/var/run/pbr-lite.conf）\n'
    cat "$PL_CONF" 2>/dev/null
    printf '\n'

    printf '## 4. include 头部（前 %s 行，共 %s 行 / %s 字节）\n' "$BUNDLE_HEAD" "$_inc_lines" "$_inc_bytes"
    sed -n "1,${BUNDLE_HEAD}p" "$INCLUDE" 2>/dev/null
    printf '\n'

    printf '## 5. 内核规则（引用 @%s）\n%s\n\n' "$SET_DST" "$_rules"

    printf '## 6. 路由与规则\n'
    ip -4 rule show 2>/dev/null | grep -E "^(0|[1-9][0-9]*):" | head -20
    printf -- '--- table %s ---\n' "$TABLE_ID"
    ip -4 route show table "$TABLE_ID" 2>/dev/null
    printf '\n'

    printf '## 7. 自检结果\n'
    "$SHARE_DIR/verify.sh" --json --fast 2>/dev/null
    printf '\n\n'

    printf '## 8. 系统日志（最近 %s 行，含 pbr-lite / fw4 / nft）\n%s\n' "$LOG_LINES" "$_log"
    exit 0
fi

# ---------------------------------------------------------------- JSON
[ "$JSON" = '1' ] || { echo "请用 --json 或 --bundle" >&2; exit 2; }

printf '{"ok":true,"ts":%s,"host":"%s","kernel":"%s","uptime":"%s",' \
    "$_ts" "$(pl_jesc "$_host")" "$(pl_jesc "$_kern")" "$(pl_jesc "$_up")"
printf '"include":{"path":"%s","exists":%s,"bytes":%s,"lines":%s,"head":"%s"},' \
    "$(pl_jesc "$INCLUDE")" "$_inc_exists" "$_inc_bytes" "$_inc_lines" "$(pl_jesc_ml "$_inc_head")"
printf '"rules":"%s","logread":"%s","env":"%s"}\n' \
    "$(pl_jesc_ml "$_rules")" "$(pl_jesc_ml "$_log")" "$(pl_jesc_ml "$_env")"

exit 0
