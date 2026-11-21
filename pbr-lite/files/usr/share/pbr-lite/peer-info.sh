#!/bin/sh
# peer-info.sh -- 探测「旁路由」的 MAC 与出口接口
#
# 场景：旁路由换了网卡/换了机器，dae.mac 要跟着改，否则「循环兜底」规则要么
# 不生效、要么误丢别人的包。手工去 `ip neigh` 抄 MAC 容易抄错，这里一次读出来。
#
# 判定顺序：
#   1. ip route get <ip>  → 走哪个接口出去（顺便判断是不是真在 LAN 上）
#   2. ip neigh show <ip> → lladdr 与状态
#   3. 邻居表里没有（或 INCOMPLETE/FAILED）就先 ping 一下触发 ARP，再读一次
#
# 只读：不写配置、不改邻居表（除了 ping 本身会触发一次正常 ARP 解析）。
#
# 用法：
#   peer-info.sh 192.168.0.253
#   peer-info.sh 192.168.0.253 --json
set -u

SHARE_DIR=${SHARE_DIR:-/usr/share/pbr-lite}
. "$SHARE_DIR/lib.sh"

IP=''; JSON=0
for a in "$@"; do
    case "$a" in
        --json) JSON=1 ;;
        -h|--help) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) IP="$a" ;;
    esac
done

[ -n "$IP" ] || { echo "用法：peer-info.sh <IPv4> [--json]" >&2; exit 2; }
is_ipv4 "$IP" || { echo "不是合法 IPv4：$IP" >&2; exit 2; }

[ -f "$PL_CONF" ] && . "$PL_CONF"
EXPECT_DEV="${LAN_DEV:-}"

# ---------------------------------------------------------------- 出口接口
_route=$(ip -4 route get "$IP" 2>/dev/null | head -1)
_dev=$(printf '%s' "$_route" | awk '{ for (i = 1; i < NF; i++) if ($i == "dev") { print $(i+1); exit } }')

# ---------------------------------------------------------------- 邻居表
_read_neigh() {
    _nb=$(ip -4 neigh show "$IP" 2>/dev/null | head -1)
    _mac=$(printf '%s' "$_nb" | awk '{ for (i = 1; i < NF; i++) if ($i == "lladdr") { print $(i+1); exit } }')
    _state=$(printf '%s' "$_nb" | awk 'NF { print $NF }')
}

_read_neigh

_pinged=0
if [ -z "$_mac" ]; then
    # 邻居表里没有（新开机、刚重启过路由器都会这样）：ping 一次把 ARP 打出来。
    # -W1 是必须的，不然一个不可达的地址会把界面卡住几秒。
    ping -c1 -W1 "$IP" >/dev/null 2>&1
    _pinged=1
    _read_neigh
fi

# 出口不是 LAN 接口时，读到的 MAC 是**网关**的，填进 dae.mac 会让兜底规则认错机器。
_on_lan=1
_note=''
if [ -n "$EXPECT_DEV" ] && [ -n "$_dev" ] && [ "$_dev" != "$EXPECT_DEV" ]; then
    _on_lan=0
    _note="这个地址从 $_dev 出去，不是 $EXPECT_DEV —— 读到的 MAC 是下一跳网关的，不能当旁路由 MAC 用"
fi

# ---------------------------------------------------------------- 输出
if [ "$JSON" = '1' ]; then
    printf '{"ok":true,"ip":"%s","mac":"%s","dev":"%s","state":"%s","on_lan":%s,"pinged":%s,"note":"%s","route":"%s"}\n' \
        "$(pl_jesc "$IP")" "$(pl_jesc "$_mac")" "$(pl_jesc "$_dev")" \
        "$(pl_jesc "$_state")" "$_on_lan" "$_pinged" "$(pl_jesc "$_note")" "$(pl_jesc "$_route")"
else
    printf 'IP:        %s\n' "$IP"
    printf '出口接口:  %s\n' "${_dev:-?}"
    printf 'MAC:       %s\n' "${_mac:-（读不到）}"
    printf '邻居状态:  %s\n' "${_state:-?}"
    if [ "$_pinged" = '1' ]; then
        if [ -n "$_mac" ]; then
            printf '说明:      邻居表里原来没有，ping 了一次才读到\n'
        else
            printf '说明:      邻居表里没有，ping 了也没有回应\n'
        fi
    fi
    [ -n "$_note" ] && printf '警告:      %s\n' "$_note"
fi

exit 0
