#!/bin/sh
# lookup-ip.sh -- 判断一个 IP 在本系统里会被怎么处理
#
# 这是「单点查询」，不是「列出集合」。界面永远不该把上万条 CIDR 吐给浏览器，
# 需要看具体归属时用这个查一个。
#
# 判定顺序（与数据面一致）：
#   1. 在直连白名单里        -> direct_whitelist （永远直连）
#   2. 在内网/保留段里        -> direct_reserved  （永远直连，安全边界）
#   3. 在非 CN 集合里        -> proxy            （打标送旁路由）
#   4. 都不在                -> cn_unknown       （推定 CN，直连）
#
# 用法：
#   lookup-ip.sh 8.8.8.8
#   lookup-ip.sh 8.8.8.8 --json
set -u

SHARE_DIR=${SHARE_DIR:-/usr/share/pbr-lite}
. "$SHARE_DIR/lib.sh"

IP=''; JSON=0
for a in "$@"; do
    case "$a" in
        --json) JSON=1 ;;
        -h|--help) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) IP="$a" ;;
    esac
done

[ -n "$IP" ] || { echo "用法：lookup-ip.sh <IPv4> [--json]" >&2; exit 2; }
is_ipv4 "$IP" || { echo "不是合法 IPv4：$IP" >&2; exit 2; }

[ -f "$PL_CONF" ] && . "$PL_CONF"

DIRECT_FILE="${DIRECT_FILE:-/var/run/pbr-lite-direct.txt}"

verdict='cn_unknown'; reason='不在非 CN 集合里，按 CN 直连处理'; hit=''
if [ -f "$DIRECT_FILE" ] && in_cidr_file "$IP" "$DIRECT_FILE"; then
    verdict='direct_whitelist'; reason='命中直连白名单，永远直连'
elif in_cidr_file "$IP" "$PL_EXCLUDE"; then
    verdict='direct_reserved'; reason='属于内网/保留段，永远直连（安全边界）'
elif [ -f "$PL_NOTCN" ] && in_cidr_file "$IP" "$PL_NOTCN"; then
    verdict='proxy'; reason='在非 CN 集合里，命中打标规则后送旁路由'
    # 找出命中的那条 CIDR，方便排障
    hit=$(awk -v ip="$IP" '
    function toint(s,  o,n,i,r){ n = split(s,o,"."); r = 0; for (i=1;i<=n;i++) r = r*256 + o[i]; return r }
    BEGIN { ipn = toint(ip) }
    {
        sub(/#.*/, ""); gsub(/[ \t\r]/, "");
        if ($0 == "") next;
        p = index($0, "/"); if (!p) next;
        net = toint(substr($0, 1, p-1)); len = substr($0, p+1) + 0;
        if (len < 0 || len > 32) next;
        blk = 2 ^ (32 - len);
        if (int(ipn / blk) == int(net / blk)) { print $0; exit }
    }' "$PL_NOTCN")
fi

# 这个 IP 的**实际去向**。
# 判定为代理时才带 mark 去查（模拟打标后的结果）；判定为直连就按裸包里
# 没有 mark 去查 —— 否则 CN 地址也会查到 table pbrlite，看着像全都被代理了。
_route=''
if [ "$verdict" = 'proxy' ] && [ -n "${MATCH_VALUE:-}" ]; then
    _route=$(ip -4 route get "$IP" mark "$MATCH_VALUE" 2>/dev/null | head -1)
else
    _route=$(ip -4 route get "$IP" 2>/dev/null | head -1)
fi

if [ "$JSON" = '1' ]; then
    printf '{"ip":"%s","verdict":"%s","cidr":"%s","reason":"%s","route":"%s"}\n' \
        "$IP" "$verdict" "$(pl_jesc "$hit")" "$(pl_jesc "$reason")" "$(pl_jesc "$_route")"
else
    printf 'IP:      %s\n' "$IP"
    printf '结论:    %s\n' "$verdict"
    printf '说明:    %s\n' "$reason"
    [ -n "$hit" ] && printf '命中:    %s\n' "$hit"
    [ -n "$_route" ] && printf '路由:    %s\n' "$_route"
fi
exit 0
