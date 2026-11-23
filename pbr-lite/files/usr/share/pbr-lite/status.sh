#!/bin/sh
# status.sh -- 只读状态汇总（LuCI 概览页与 CLI 共用的唯一数据源）
#
# 只读四类东西，不改任何东西，任何时候都能跑：
#   1. 导出配置 /var/run/pbr-lite.conf
#   2. 生成的 include 文件（条目数、字节数）
#   3. 内核里的集合与 mangle_prerouting 规则（条目数、命中计数）
#   4. ip rule / 路由表 / 邻居表 / crontab / 备份目录
#
# state.json 不在这里读：它是「上一次更新的结果」，由调用方（rpcd）自己合并，
# 这样 status.sh 的输出永远是「内核当前事实」，不会和状态文件混为一谈。
#
# 用法：
#   status.sh           人类可读
#   status.sh --json    机器可读
set -u

SHARE_DIR=${SHARE_DIR:-/usr/share/pbr-lite}
. "$SHARE_DIR/lib.sh"

JSON=0
for _a in "$@"; do
    case "$_a" in
        --json) JSON=1 ;;
        -h|--help) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown arg: $_a" >&2; exit 2 ;;
    esac
done

if [ ! -f "$PL_CONF" ]; then
    if [ "$JSON" = '1' ]; then
        printf '{"ok":false,"error":"%s 不存在，先跑 /usr/share/pbr-lite/conf-export.sh"}\n' "$PL_CONF"
    else
        echo "配置未导出：$PL_CONF 不存在，先跑 conf-export.sh" >&2
    fi
    exit 1
fi
# shellcheck disable=SC1090
. "$PL_CONF"

# ---------------------------------------------------------------- include 文件
# 成本控制：这个函数会被界面每 15 秒调一次，所以只做便宜的事。
#   * 字节数/行数用 wc（一次 read，几十毫秒）
#   * 文件条目数优先读 not-cn.txt 镜像（wc -l，极便宜），镜像与 include 的一致性
#     由 verify.sh 单独校验，不在这里重复付 19 万行 sed 的代价
fe=0; ib=0; il=0
if [ -f "$INCLUDE" ]; then
    ib=$(wc -c < "$INCLUDE" | tr -d ' ')
    il=$(wc -l < "$INCLUDE" | tr -d ' ')
fi
if [ -f "$PL_NOTCN" ]; then
    fe=$(wc -l < "$PL_NOTCN" | tr -d ' ')
elif [ -f "$INCLUDE" ]; then
    _blk=$(sed -n "/^add element inet fw4 ${SET_DST} {/,/^}/p" "$INCLUDE" 2>/dev/null)
    [ -n "$_blk" ] && fe=$(( $(printf '%s' "$_blk" | grep -o ',' | wc -l | tr -d ' ') + 1 ))
fi

# ---------------------------------------------------------------- 内核集合
kc=0; kset_ok=0
_sout=$(nft list set inet fw4 "$SET_DST" 2>/dev/null)
if [ -n "$_sout" ]; then
    kset_ok=1
    if printf '%s' "$_sout" | grep -q 'elements = {'; then
        kc=$(printf '%s' "$_sout" | grep -o ',' | wc -l | tr -d ' ')
        kc=$(( ${kc:-0} + 1 ))
    fi
fi

# ---------------------------------------------------------------- 规则与计数
_ch=$(nft list chain inet fw4 mangle_prerouting 2>/dev/null)
rl=0
[ -n "$_ch" ] && rl=$(printf '%s' "$_ch" | grep -c "@$SET_DST" 2>/dev/null || true)
rl=${rl:-0}

# 命中计数：两条规则各有一组 counter packets/bytes。
# fw4 reload 会把计数清零，所以这是「本次重载以来」的量。
set -- $(printf '%s' "$_ch" | awk -v set="$SET_DST" '
    index($0, "@" set) {
        p = 0; b = 0
        for (i = 1; i <= NF; i++) {
            if ($i == "packets") p = $(i + 1) + 0
            if ($i == "bytes")   b = $(i + 1) + 0
        }
        if (index($0, "ether saddr")) { gp = p; gb = b }
        else                          { mp = p; mb = b }
    }
    END { printf "%d %d %d %d\n", mp + 0, mb + 0, gp + 0, gb + 0 }')
mark_pk=${1:-0}; mark_by=${2:-0}; guard_pk=${3:-0}; guard_by=${4:-0}

# ---------------------------------------------------------------- 路由层
_rule=$(ip -4 rule show 2>/dev/null | awk -v p="$PREF" '$1 == p":"')
_rdef=$(ip -4 route show table "$TABLE_ID" 2>/dev/null | awk '/^default/ { print; exit }')
route_ok=0
[ -n "$_rdef" ] && route_ok=1
rule_ok=0
[ -n "$_rule" ] && rule_ok=1

# ---------------------------------------------------------------- 邻居（旁路由）
_neigh=$(ip -4 neigh show "$NEXT_HOP" 2>/dev/null | head -1)
n_mac=$(printf '%s' "$_neigh" | awk '{ for (i = 1; i < NF; i++) if ($i == "lladdr") { print $(i + 1); exit } }')
n_state=$(printf '%s' "$_neigh" | awk '{ if (NF) print $NF }')
n_match=0
[ -n "$n_mac" ] && [ "$n_mac" = "$DAE_MAC" ] && n_match=1

# ---------------------------------------------------------------- cron / 服务
_cron=$(crontab -l 2>/dev/null | grep 'pbr-lite-update' | grep -v '^#' | head -1)
svc_enabled=0
[ -f /etc/rc.d/S99pbr-lite ] && svc_enabled=1
dcount=0
[ -f "$PL_DIRECT" ] && dcount=$(grep -c . "$PL_DIRECT" 2>/dev/null || true)
dcount=${dcount:-0}

# ---------------------------------------------------------------- 备份槽
_baks=''
if [ -d "$PL_BAKDIR" ]; then
    for _f in $(ls -1t "$PL_BAKDIR"/30-pbr-lite.nft.* 2>/dev/null); do
        _n=$(basename "$_f" | sed 's/^30-pbr-lite\.nft\.//')
        _sz=$(wc -c < "$_f" | tr -d ' ')
        _mt=$(stat -c %Y "$_f" 2>/dev/null || echo 0)
        [ -n "$_baks" ] && _baks="$_baks,"
        _baks="$_baks{\"slot\":\"$_n\",\"bytes\":$_sz,\"mtime\":$_mt}"
    done
fi

consistent=0
[ "$fe" -gt 0 ] && [ "$kc" -eq "$fe" ] && consistent=1

# flow offload 状态。开启时被加速的包不经过 nft 规则链（硬件加速更是完全不进 CPU），
# counters 里的打标命中只统计到「未卸载的那部分」，界面上必须据此标注 ——
# 否则用户会把它当成真实流量（实测差 50 倍以上）。
_fo_sw=$(uci -q get 'firewall.@defaults[0].flow_offloading' 2>/dev/null)
_fo_hw=$(uci -q get 'firewall.@defaults[0].flow_offloading_hw' 2>/dev/null)
if [ "$_fo_hw" = '1' ]; then
    offload='hw'
elif [ "$_fo_sw" = '1' ]; then
    offload='sw'
else
    offload=''
fi

# ---------------------------------------------------------------- 输出
if [ "$JSON" = '1' ]; then
    printf '{"ok":true,"ts":%s,"version":"%s",' "$(pl_now)" "$PL_VERSION"
    printf '"config":{"enabled":%s,"guard":%s,"src_addrs":"%s","dae_mac":"%s","next_hop":"%s","lan_dev":"%s",' \
        "${ENABLED:-0}" "${GUARD:-0}" "$(pl_jesc "$SRC_ADDRS")" "$(pl_jesc "${DAE_MAC:-}")" \
        "$(pl_jesc "$NEXT_HOP")" "$(pl_jesc "$LAN_DEV")"
    printf '"mark_value":"%s","mark_keep_mask":"%s","mark_match_mask":"%s",' \
        "$MARK_VALUE" "$MARK_MASK" "$MATCH_MASK"
    printf '"table_id":"%s","table_name":"%s","pref":"%s",' "$TABLE_ID" "$TABLE_NAME" "$PREF"
    printf '"src_url":"%s","min_entries":%s,"max_drift":%s,"direct_entries":%s,' \
        "$(pl_jesc "$SRC_URL")" "${MIN_ENTRIES:-0}" "${MAX_DRIFT:-0}" "$dcount"
    printf '"set_src":"%s","set_dst":"%s"},' "$SET_SRC" "$SET_DST"
    printf '"runtime":{"include_exists":%s,"include_bytes":%s,"include_lines":%s,"file_entries":%s,' \
        "$([ -f "$INCLUDE" ] && echo 1 || echo 0)" "$ib" "$il" "$fe"
    printf '"set_loaded":%s,"kernel_entries":%s,"consistent":%s,"rules":%s,' \
        "$kset_ok" "$kc" "$consistent" "$rl"
    printf '"rule_ok":%s,"route_ok":%s,"offload":"%s"},' "$rule_ok" "$route_ok" "$offload"
    printf '"counters":{"mark_packets":%s,"mark_bytes":%s,"guard_packets":%s,"guard_bytes":%s},' \
        "$mark_pk" "$mark_by" "$guard_pk" "$guard_by"
    printf '"route":{"rule":"%s","default":"%s"},' \
        "$(pl_jesc "$_rule")" "$(pl_jesc "$_rdef")"
    printf '"neigh":{"mac":"%s","state":"%s","match":%s},' \
        "$(pl_jesc "$n_mac")" "$(pl_jesc "$n_state")" "$n_match"
    printf '"cron":{"installed":%s,"line":"%s","service_enabled":%s},' \
        "$([ -n "$_cron" ] && echo 1 || echo 0)" "$(pl_jesc "$_cron")" "$svc_enabled"
    printf '"backups":[%s]}\n' "$_baks"
    exit 0
fi

# 人类可读
echo "pbr-lite $PL_VERSION"
echo "  开关        : enabled=$ENABLED guard=$GUARD  服务开机自启=$svc_enabled"
echo "  源地址      : $SRC_ADDRS"
echo "  旁路由      : $NEXT_HOP ($DAE_MAC) via $LAN_DEV"
echo "  数据一致性  : 文件 $fe 条 / 内核 $kc 条 $([ "$consistent" = '1' ] && echo '✅' || echo '❌')"
echo "  include     : ${ib} 字节 / ${il} 行"
echo "  规则        : ${rl} 条引用 @$SET_DST（期望 >= 2），ip rule $PREF $([ "$rule_ok" = '1' ] && echo 在位 || echo 缺失)"
echo "  选路        : ${_rdef:-表 $TABLE_ID 无 default 路由}"
echo "  计数        : 打标 ${mark_pk} 包 / 兜底 ${guard_pk} 包（本次重载以来）"
echo "  旁路由邻居  : ${n_mac:-无表项} ${n_state} $([ "$n_match" = '1' ] && echo '✅ 与配置一致' || echo '⚠️ 与配置不一致')"
echo "  直连白名单  : ${dcount} 条"
echo "  定时更新    : ${_cron:-未安装}"
echo "  备份槽      : $(ls -1 "$PL_BAKDIR" 2>/dev/null | wc -l | tr -d ' ') 份"
[ -f "$PL_STATE" ] && { echo; echo '--- state.json ---'; cat "$PL_STATE"; }
exit 0
