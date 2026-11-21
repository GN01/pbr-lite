#!/bin/sh
# verify.sh -- pbr-lite 自检：逐项核对「配置 -> 文件 -> 内核 -> 路由」是否首尾一致
#
# 只读，不改任何配置。所有结论来自现场读取，不信任任何缓存。
# 退出码：0 全通过（允许 WARN）  1 有 FAIL
#
# 用法：
#   verify.sh            人读，带颜色，逐项打印
#   verify.sh --json     机器读（LuCI 用），输出 {summary, items}
#   verify.sh --fast     跳过 3 秒兜底差分（界面轮询用）

SHARE_DIR=${SHARE_DIR:-/usr/share/pbr-lite}
. "$SHARE_DIR/lib.sh"

JSON=0; FAST=0
for a in "$@"; do
    case "$a" in
        --json) JSON=1; PL_QUIET=1 ;;
        --fast) FAST=1 ;;
        -h|--help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown arg: $a" >&2; exit 2 ;;
    esac
done

"$SHARE_DIR/conf-export.sh" >/dev/null 2>&1
if [ -f "$PL_CONF" ]; then
    . "$PL_CONF"
else
    echo "严重：$PL_CONF 不存在，配置无法读取" >&2
    exit 1
fi
INCLUDE="${INCLUDE:-$PL_INCLUDE}"

PASS=0; WARN=0; FAIL=0
CUR='未分组'
fe=0; kc=0
REC=$(mktemp /tmp/pbr-verify.XXXXXX) || exit 1
trap 'rm -f "$REC"' EXIT INT TERM

_rec() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$REC"; }
ok()   { PASS=$((PASS+1)); _rec pass "$CUR" "$*"; [ "$JSON" = '1' ] || printf '  \033[32mPASS\033[0m  %s\n' "$*"; }
no()   { FAIL=$((FAIL+1)); _rec fail "$CUR" "$*"; [ "$JSON" = '1' ] || printf '  \033[31mFAIL\033[0m  %s\n' "$*"; }
warn() { WARN=$((WARN+1)); _rec warn "$CUR" "$*"; [ "$JSON" = '1' ] || printf '  \033[33mWARN\033[0m  %s\n' "$*"; }
hdr()  { CUR="$*"; [ "$JSON" = '1' ] || printf '\n[%s]\n' "$*"; }

# ---------------------------------------------------------------- 1. 配置
hdr '1. 配置'
[ -f /etc/config/pbr-lite ] && ok '/etc/config/pbr-lite 存在' || no '/etc/config/pbr-lite 不存在'
[ -f "$PL_CONF" ] && ok "导出配置 $PL_CONF 存在" || no "导出配置 $PL_CONF 不存在（conf-export.sh 失败？）"
for v in SRC_ADDRS DAE_MAC SRC_URL MARK_VALUE MARK_MASK SET_SRC SET_DST NEXT_HOP; do
    eval "_val=\${$v:-}"
    [ -n "$_val" ] && ok "$v=$_val" || no "$v 为空"
done
if [ "${ENABLED:-0}" = '1' ]; then ok '分流已启用'; else warn '分流已关闭（只保留集合，不下发规则）'; fi

# mark 一致性：保留掩码 / 匹配掩码 / 实际 ip rule 三者必须对得上
mv=$(hex2dec "${MARK_VALUE:-0x0}"); mm=$(hex2dec "${MARK_MASK:-0x0}")
mval=$(hex2dec "${MATCH_VALUE:-0x0}"); mmask=$(hex2dec "${MATCH_MASK:-0x0}")
if [ "$mv" = 'ERR' ] || [ "$mm" = 'ERR' ] || [ "$mmask" = 'ERR' ]; then
    no "mark 取值不是合法十六进制"
else
    [ "$(band "$mv" "$mm")" = '0' ] \
        && ok "保留掩码 $MARK_MASK 已清空 $MARK_VALUE 位" \
        || no "保留掩码 $MARK_MASK 会清掉自己置的位，打标永不生效"
    _want=$(awk -v m="$mm" 'BEGIN { printf "%.0f", 4294967295 - m }')
    [ "$(awk -v a="$mmask" -v b="$_want" 'BEGIN{print (a==b)?"1":"0"}')" = '1' ] \
        && ok "匹配掩码 $MATCH_MASK 与保留掩码互补（推导正确）" \
        || no "匹配掩码 $MATCH_MASK 与 $MARK_MASK 不互补"
fi

for f in "$PL_EXCLUDE" "$PL_AWK" "$SHARE_DIR/conf-export.sh"; do
    [ -s "$f" ] && ok "$(basename "$f") 存在" || no "$f 缺失"
done
_xn=$(grep -vcE '^\s*(#|$)' "$PL_EXCLUDE" 2>/dev/null || echo 0)
[ "${_xn:-0}" -ge 10 ] && ok "排除段 $_xn 条（安全边界）" || no "排除段只有 $_xn 条，内网段可能被删"

# ---------------------------------------------------------------- 2. 旧版残留
hdr '2. 旧版与 pbr 残留'
opkg list-installed 2>/dev/null | grep -q '^pbr ' \
    && no 'pbr 包仍装着（会与本模块重复打标）' || ok 'pbr 包已卸载'
_lf=''
for f in /etc/sdwan.conf /usr/sbin/sdwan-list-update /etc/init.d/sdwan-route \
         /etc/hotplug.d/iface/99-sdwan /usr/share/nftables.d/ruleset-post/30-sdwan.nft; do
    [ -e "$f" ] && _lf="$_lf $f"
done
[ -z "$_lf" ] && ok '没有 sdwan 旧版文件残留' || warn "旧版文件还在：$_lf"
# 旧 include 若还在，fw4 reload 会把它一起装回去（双份规则）
[ -f /usr/share/nftables.d/ruleset-post/30-sdwan.nft ] \
    && no '30-sdwan.nft 仍在 ruleset-post（每次 reload 会重复装载旧规则）' \
    || ok '旧 include 已移出 ruleset-post'
_orphan=''
for s in sdwan_src sdwan_notcn; do
    nft list set inet fw4 "$s" >/dev/null 2>&1 && _orphan="$_orphan $s"
done
[ -z "$_orphan" ] && ok '内核里没有旧集合残留' || warn "内核仍残留旧集合：$_orphan（nft delete set 可清）"

# ---------------------------------------------------------------- 3. 生成文件
hdr '3. 生成的 include'
if [ -f "$INCLUDE" ]; then
    _lines=$(wc -l < "$INCLUDE" | tr -d ' '); _sz=$(wc -c < "$INCLUDE" | tr -d ' ')
    ok "$(basename "$INCLUDE") 存在（$_lines 行 / $_sz 字节）"
    fe=$(sed -n "/add set inet fw4 ${SET_DST}/,/^}/p" "$INCLUDE" 2>/dev/null | grep -o ',' | wc -l | tr -d ' ')
    fe=$(( ${fe:-0} + 1 ))
    [ "$fe" -ge 1000 ] && ok "文件里 $fe 条 CIDR" || no "文件里只有 $fe 条 CIDR（应数千条）"
    grep -qE '生成于|Generated at|generated_at' "$INCLUDE" \
        && warn '文件里带时间戳，会让 cmp 永远判定「有变化」而每天 reload' \
        || ok '文件里没有时间戳（内容稳定）'
    grep -q "^# 源 sha256: [0-9a-f]\{64\}" "$INCLUDE" \
        && ok '头部带源 sha256（可追溯是哪份列表生成的）' \
        || warn '头部缺源 sha256'
else
    no "$INCLUDE 不存在（分流规则根本没装载）"
fi

# ---------------------------------------------------------------- 4. 内核
hdr '4. 内核装载'
ch=$(nft list chain inet fw4 mangle_prerouting 2>/dev/null)
[ -n "$ch" ] && ok 'mangle_prerouting 链存在' || no 'mangle_prerouting 不存在（fw4 没起来）'

# 集合内容只 dump 一次。nft 要把 1.1 万个元素格式化成文本，单次约 2s，
# 原来「存在性检查」和「元素计数」各 dump 一次，这一节光 dump 就 4s。
_sd=$(nft list set inet fw4 "$SET_DST" 2>/dev/null)
[ -n "$_sd" ] && ok "集合 $SET_DST 已装载" || no "集合 $SET_DST 不存在"
nft list set inet fw4 "$SET_SRC" >/dev/null 2>&1 && ok "集合 $SET_SRC 已装载" || no "集合 $SET_SRC 不存在"

kc=$(printf '%s' "$_sd" | grep -o ',' | wc -l | tr -d ' ')
kc=$(( ${kc:-0} + 1 ))
if [ "$kc" -eq "$fe" ] && [ "$kc" -ge 1000 ]; then
    ok "内核 $kc 条 == 文件 $fe 条（精确比对通过）"
elif [ "$kc" -ge 1000 ]; then
    no "内核 $kc 条 != 文件 $fe 条（集合没刷新成功，或装载不全）"
else
    no "内核集合只有 $kc 条（应为数千条）"
fi

_rl=$(printf '%s' "$ch" | grep -c "@$SET_DST" || true)
if [ "${ENABLED:-0}" = '1' ]; then
    [ "${_rl:-0}" -ge 1 ] && ok "mangle_prerouting 里有 ${_rl} 条规则引用 @$SET_DST" \
        || no "没有规则引用 @$SET_DST（打标失效）"
    printf '%s' "$ch" | grep -q "ip saddr @$SET_SRC" \
        && ok "源地址限定在 @$SET_SRC（不影响其他设备）" || no "规则没有源地址限定"
    printf '%s' "$ch" | grep -q "meta mark set" \
        && ok '打标规则在位' || no '没有 meta mark set 规则'
    printf '%s' "$ch" | grep -qE "0x0*$(printf '%s' "$MARK_VALUE" | sed 's/^0x0*//')" \
        && ok "打标值 $MARK_VALUE 正确" || warn "没在规则里看到 $MARK_VALUE"
else
    [ "${_rl:-0}" -eq 0 ] && ok '已关闭分流：内核里没有引用集合的规则' \
        || no "声明关闭，但内核里还有 ${_rl} 条规则引用 @$SET_DST"
fi

# 兜底规则
if [ "${ENABLED:-0}" = '1' ] && [ "${GUARD:-0}" = '1' ]; then
    _dl=$(printf '%s\n' "$ch" | grep -n 'ether saddr' | grep 'drop' | cut -d: -f1)
    _ml=$(printf '%s\n' "$ch" | grep -n 'meta mark set' | cut -d: -f1)
    if [ -n "$_dl" ]; then
        ok '循环兜底 drop 规则在位'
        if [ -n "$_ml" ] && [ "$_dl" -lt "$_ml" ]; then
            ok "兜底（第 $_dl 行）排在打标（第 $_ml 行）之前"
        else
            warn "兜底与打标顺序可疑（drop 第 $_dl 行 / mark 第 ${_ml:-?} 行）"
        fi
        _drop_line=$(printf '%s\n' "$ch" | grep 'ether saddr' | grep 'drop')
        _mac=$(printf '%s' "$_drop_line" | grep -oE 'ether saddr [0-9a-f:]+' | awk '{print $3}')
        _real=$(ip neigh show "$NEXT_HOP" 2>/dev/null | grep -o 'lladdr [0-9a-f:]*' | awk '{print $2}')
        if [ -n "$_real" ] && [ "$_mac" != "$_real" ]; then
            no "兜底 MAC $_mac 与 $NEXT_HOP 实际 $_real 不一致（换过网卡？改 dae.mac）"
        elif [ -n "$_real" ]; then
            ok "兜底 MAC 与实际一致（$_mac）"
        else
            warn "$NEXT_HOP 的 neigh 表项不存在，无法核对兜底 MAC"
        fi
        if [ "$FAST" = '0' ]; then
            _p1=$(printf '%s' "$_drop_line" | grep -o 'packets [0-9]*' | awk '{print $2}')
            sleep 3
            _p2=$(nft list chain inet fw4 mangle_prerouting 2>/dev/null | grep 'ether saddr' | grep 'drop' | grep -o 'packets [0-9]*' | awk '{print $2}')
            _d=$(( ${_p2:-0} - ${_p1:-0} ))
            if [ "$_d" -gt 5 ] 2>/dev/null; then
                no "3 秒内兜底丢了 $_d 个包（累计 ${_p2}）→ 旁路由在把包原样转回来"
            elif [ "${_p2:-0}" -gt 0 ] 2>/dev/null; then
                ok "兜底累计 ${_p2}，3 秒新增 $_d（静态属历史残留）"
            else
                ok '兜底零命中'
            fi
        fi
    else
        no '没有循环兜底规则（旁路由挂掉时包会弹到 TTL 耗尽）'
    fi
fi

# not-cn.txt 是 lookup-ip 与第 7 组比对用的「数据面镜像」，必须与 include 元素块一致。
# 踩过的坑：回滚只换了 include，镜像停在上一版 —— 数据面是对的，查询结论却是错的。
if [ -f "$PL_NOTCN" ] && [ -f "$INCLUDE" ]; then
    _ma=$(md5sum < "$PL_NOTCN" | awk '{print $1}')
    _mb=$(sed -n "/^add element inet fw4 ${SET_DST} {/,/^}/p" "$INCLUDE" 2>/dev/null \
          | sed '1d;$d' | tr -d ' ' | tr ',' '\n' | sed '/^$/d' | md5sum | awk '{print $1}')
    if [ "$_ma" = "$_mb" ]; then
        ok '镜像 not-cn.txt 与 include 元素块一致'
    else
        _mbn=$(sed -n "/^add element inet fw4 ${SET_DST} {/,/^}/p" "$INCLUDE" | sed '1d;$d' \
               | tr -d ' ' | tr ',' '\n' | sed '/^$/d' | wc -l | tr -d ' ')
        no "镜像 not-cn.txt 与 include 不一致（$(wc -l < "$PL_NOTCN" | tr -d ' ') 条 vs $_mbn 条）—— 跑一次 pbr-lite-update 自动纠正"
    fi
fi

# ---------------------------------------------------------------- 5. ip rule
hdr '5. ip rule 与路由表'
_r=$(ip -4 rule | awk -v p="$PREF" '$1==p":"')
if [ -n "$_r" ]; then
    ok "pref $PREF: $_r"
    # 注意：内核/iproute2 打印 fwmark 会去掉前导零（0x010000 显示成 0x10000），
    # 所以不能拿字符串直接比，必须按数值比。
    _rm=$(printf '%s' "$_r" | grep -o 'fwmark [^ ]*' | awk '{print $2}')
    if [ -z "$_rm" ]; then
        no "pref $PREF 上没有 fwmark 条件"
    elif [ "$(hex2dec "${_rm%%/*}")" = "$(hex2dec "$MATCH_VALUE")" ] && \
         [ "$(hex2dec "${_rm##*/}")" = "$(hex2dec "$MATCH_MASK")" ]; then
        ok "fwmark 数值与匹配掩码对齐（实际 $_rm，期望 $MATCH_VALUE/$MATCH_MASK）"
    else
        no "fwmark 不符：期望 $MATCH_VALUE/$MATCH_MASK，实际 $_rm"
    fi
    printf '%s' "$_r" | grep -qE "lookup ($TABLE_ID|$TABLE_NAME)" \
        && ok "查表 $TABLE_ID（$TABLE_NAME）" || no "pref $PREF 未指向表 $TABLE_ID"
else
    no "缺少 pref $PREF（/etc/init.d/pbr-lite start）"
fi
_t=$(ip -4 route show table "$TABLE_ID" 2>/dev/null)
printf '%s' "$_t" | grep -q "default via $NEXT_HOP dev $LAN_DEV" \
    && ok "表 $TABLE_ID default via $NEXT_HOP dev $LAN_DEV" \
    || no "表 $TABLE_ID 缺 default via $NEXT_HOP dev $LAN_DEV"
printf '%s' "$_t" | grep -q '192\.168\.' \
    && ok 'LAN 直连路由已复制进表' || warn '表里没看到 192.168 直连路由（L2 路径可能缺失）'

# ---------------------------------------------------------------- 6. 选路实测
hdr '6. 选路实测'
_g1=$(ip -4 route get 8.8.8.8 mark "$MATCH_VALUE" 2>/dev/null | head -1)
printf '%s' "$_g1" | grep -q "$NEXT_HOP" \
    && ok "打标去 8.8.8.8 -> $(printf '%s' "$_g1" | awk '{print $3, $5}')" \
    || no "打标去 8.8.8.8 没走 $NEXT_HOP：$_g1"
_g2=$(ip -4 route get 223.5.5.5 2>/dev/null | head -1)
printf '%s' "$_g2" | grep -q pppoe \
    && ok "未打标去 223.5.5.5 -> $(printf '%s' "$_g2" | awk '{print $3, $5}')" \
    || warn "未打标去 223.5.5.5 的选路：$_g2"

# ---------------------------------------------------------------- 7. 地址表抽查
hdr '7. 地址表抽查'
ELEM="$PL_NOTCN"
_cleanup_elem=0
if [ ! -s "$ELEM" ] && [ -f "$INCLUDE" ]; then
    ELEM=$(mktemp /tmp/pbr-elem.XXXXXX); _cleanup_elem=1
    sed -n "/add set inet fw4 ${SET_DST}/,/^}/p" "$INCLUDE" \
        | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+' > "$ELEM"
fi
if [ -s "$ELEM" ]; then
    _cn=$(wc -l < "$ELEM" | tr -d ' ')
    # 6 个固定抽查 + 直连白名单扣除校验，合成一次扫描。
    # 单地址版每调一次都要重读整个表（1.1 万行约 0.8s），这里原来要扫 6+N 遍，
    # 是整个 verify 耗时的大头（实测 9.7s 里的 5s）。
    _neg='223.5.5.5 114.114.114.114 36.110.228.204'
    _pos='8.8.8.8 1.1.1.1 104.16.0.1'
    _dir=''
    for _d in ${DIRECT_DST:-}; do _dir="$_dir ${_d%%/*}"; done
    _chk=$(mktemp /tmp/pbr-chk.XXXXXX)

    # 这一步即使合并成一遍仍要 2.4s（busybox awk 每行 ~200µs，1.1 万行 × 6 个地址）。
    # 但答案只取决于「表内容 + 直连白名单」，跟内核状态无关 —— 按这两个的指纹缓存，
    # 表没变就直接复用，把一次全表扫描降成一次 md5sum。
    _ckey=$(md5sum "$ELEM" 2>/dev/null | cut -d' ' -f1)-$(printf '%s' "${DIRECT_DST:-}" | md5sum | cut -d' ' -f1)
    _ccache="${PL_RUNDIR:-/var/run/pbr-lite}/chk.$_ckey"
    _chk_cached=0

    if [ -s "$_ccache" ]; then
        cp -f "$_ccache" "$_chk"
        _chk_cached=1
    else
        in_cidr_multi "$ELEM" $_neg $_pos $_dir > "$_chk" 2>/dev/null
        # 只留最新一份缓存：表一更新指纹就变，旧的不清会一直攒在 /var/run 里
        mkdir -p "${PL_RUNDIR:-/var/run/pbr-lite}" 2>/dev/null
        if [ -s "$_chk" ] && cp -f "$_chk" "$_ccache" 2>/dev/null; then
            for _f in "${PL_RUNDIR:-/var/run/pbr-lite}"/chk.*; do
                [ -e "$_f" ] && [ "$_f" != "$_ccache" ] && rm -f "$_f"
            done
        fi
    fi
    # 命中缓存时把「省了哪一步」写在样本行里，别单开一条 —— 否则同类自检的
    # PASS 计数会在 57/58 之间来回跳，看历史对比时容易被当成异常。
    if [ "$_chk_cached" = '1' ]; then
        ok "地址表样本 $_cn 条（成员抽查命中缓存，跳过全表重扫）"
    else
        ok "地址表样本 $_cn 条"
    fi

    _bad=0
    while read -r ip f; do
        [ -n "$ip" ] || continue
        case " $_neg " in
            *" $ip "*) [ "$f" = '1' ] && no "$ip 被收进非 CN 列表（CN 站点会被送去旁路由）" || ok "$ip 未收录（CN 直连）"; continue ;;
        esac
        case " $_pos " in
            *" $ip "*) [ "$f" = '1' ] && ok "$ip 已收录（走旁路由）" || no "$ip 未收录（该走代理的站点会直连，暴露真实 IP）"; continue ;;
        esac
        [ "$f" = '1' ] && _bad=$((_bad + 1))
    done < "$_chk"
    rm -f "$_chk"
    if [ -n "${DIRECT_DST:-}" ]; then
        [ "$_bad" -eq 0 ] && ok "直连白名单的地址都已从集合中扣除" || no "$_bad 条直连白名单仍在集合里"
    fi
    if grep -qE '^(10\.|127\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.)' "$ELEM" 2>/dev/null; then
        no '集合里混入私网/回环段（排除表被改过？内网互访会来回弹）'
    else
        ok '未混入私网/回环段'
    fi
fi
[ "$_cleanup_elem" = '1' ] && rm -f "$ELEM"

# ---------------------------------------------------------------- 8. 状态文件
hdr '8. 状态文件'
if [ -f "$PL_STATE" ]; then
    if command -v jq >/dev/null 2>&1; then
        if jq -e . "$PL_STATE" >/dev/null 2>&1; then
            ok 'state.json 是合法 JSON'
            _se=$(jq -r '.last_run.result // "?"' "$PL_STATE" 2>/dev/null)
            _sn=$(jq -r '.dst_entries // 0' "$PL_STATE" 2>/dev/null)
            ok "最近一次结果：$_se，记录条目数 $_sn"
            [ "$_sn" = "$fe" ] && ok 'state.json 的条目数与文件一致' || warn "state.json 记 $_sn 条，文件 $fe 条（可能刚手工改过）"
        else
            no 'state.json 不是合法 JSON'
        fi
    else
        ok 'state.json 存在（无 jq，跳过校验）'
    fi
else
    warn 'state.json 不存在（还没成功跑过一次更新？）'
fi

# ---------------------------------------------------------------- 9. 环境
hdr '9. 环境'
ping -c1 -W1 "$NEXT_HOP" >/dev/null 2>&1 \
    && ok "$NEXT_HOP 可达" || no "$NEXT_HOP 不可达（旁路由关机或 IP 变了）"
_cr=$(crontab -l 2>/dev/null | grep -c 'pbr-lite-update')
[ "$_cr" -ge 1 ] && ok 'cron 已登记 pbr-lite-update' || warn 'cron 里没有 pbr-lite-update（列表会停在当前版本）'
_hfo=$(uci -q get firewall.@defaults[0].flow_offloading_hw)
_sfo=$(uci -q get firewall.@defaults[0].flow_offloading)
if [ "$_hfo" = '1' ]; then
    warn 'HFO 已开启：策略路由 + 同 LAN 下一跳在部分版本会有缓存错误目的 MAC 的问题'
elif [ "$_sfo" = '1' ]; then
    ok 'SFO 开启、HFO 关闭'
else
    ok '硬件加速未开启'
fi

# ---------------------------------------------------------------- 输出
TOTAL=$((PASS + WARN + FAIL))
if [ "$JSON" = '1' ]; then
    printf '{"summary":{"pass":%s,"warn":%s,"fail":%s,"total":%s,"ok":%s},"items":[' \
        "$PASS" "$WARN" "$FAIL" "$TOTAL" "$([ "$FAIL" -eq 0 ] && echo true || echo false)"

    # 整个 items 数组在 awk 里一次拼完。
    # 原来每条 item 都要 fork 三个 cut 加两次 pl_jesc（每次 pl_jesc 自己又是 1 个 sed + 4 个 tr），
    # 60 条合计 400 多个子进程 —— 在这颗 CPU 上光这一节就 1s 左右，比任何业务检查都贵。
    #
    # 转义按字符处理，不依赖 awk 的 \t / 八进制范围语法（busybox awk 在这块行为不稳）：
    # 只把 0x01~0x1f、反斜杠、双引号处理掉，其余原样输出。
    awk -F '\t' '
    function esc(s,  i, c, o, n) {
        o = ""; n = length(s)
        for (i = 1; i <= n; i++) {
            c = substr(s, i, 1)
            if (c == "\\")      o = o "\\\\"
            else if (c == "\"") o = o "\\\""
            else if (c >= "\001" && c <= "\037") o = o " "
            else o = o c
        }
        return o
    }
    {
        if (NR > 1) printf ","
        printf "\n  {\"status\":\"%s\",\"group\":\"%s\",\"msg\":\"%s\"}", $1, esc($2), esc($3)
    }
    END { printf "\n]}\n" }
    ' "$REC"
else
    printf '\n========== 总结：PASS=%s  WARN=%s  FAIL=%s ==========\n' "$PASS" "$WARN" "$FAIL"
    if [ "$FAIL" -eq 0 ]; then
        printf '路由器侧就绪。端到端验证请在有分流的机器上：\n'
        printf '  curl -s https://api.ipify.org   # 应为代理出口，不是宽带 IP\n'
        printf '  curl -s https://myip.ipip.net   # 访问 CN 站点应为国内 IP\n'
    fi
fi

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
