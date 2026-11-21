#!/bin/sh
# lib.sh -- pbr-lite 公共函数（被 update / verify / lookup 引用）
#
# 设计约束：这个文件里不允许出现任何「处理大列表」的循环。
# 1.1 万条 CIDR 的遍历只发生在 awk 里（见 gen-not-cn.awk）。

PL_TAG='pbr-lite'
PL_VERSION='1.0.0'
PL_UCI='pbr-lite'

PL_CONFDIR='/usr/share/pbr-lite'
PL_CONF='/var/run/pbr-lite.conf'
PL_DIRECT='/var/run/pbr-lite-direct.txt'
PL_INCLUDE='/usr/share/nftables.d/ruleset-post/30-pbr-lite.nft'
PL_BAKDIR='/usr/share/pbr-lite/backup'
PL_STATE='/usr/share/pbr-lite/state.json'
PL_HISTORY='/usr/share/pbr-lite/history.tsv'
PL_NOTCN='/usr/share/pbr-lite/not-cn.txt'
# 上一次下载的原始 CN 列表。--no-fetch 时用它替代下载：
# 改个源地址 / 白名单时 CN 列表根本没变，不该被上游的一次 5xx 拖成失败。
# （顺带也省 0.3s 下载；真正的耗时在算补集，不是它。）
PL_CNCACHE='/usr/share/pbr-lite/cn.txt'
PL_RUNDIR='/var/run/pbr-lite'
PL_EXCLUDE='/usr/share/pbr-lite/exclude.txt'
PL_AWK='/usr/share/pbr-lite/gen-not-cn.awk'

# PL_QUIET=1 时只写 syslog，不往 stdout 吐（--json 模式用）
PL_QUIET=${PL_QUIET:-0}

pl_log() {
    logger -t "$PL_TAG" "$*" 2>/dev/null
    [ "$PL_QUIET" = '1' ] || echo "[$PL_TAG] $*"
}

pl_die() {
    PL_ERRMSG="$*"
    pl_log "放弃：$*"
    exit 1
}

# 转义成 JSON 字符串内容（值、反斜杠、换行、tab、ESC）
#
# tab 和 ESC 必须一起处理：`ip rule` 的输出里字段之间就是制表符，直接塞进 JSON
# 会得到非法字符串（jq 报 "control characters must be escaped"）。ucode 的解析器
# 更宽容，所以这个 bug 在 P1 阶段一直没暴露，直到 job.sh 里用 jq 读自检结果才现形。
pl_jesc() {
    printf '%s' "$1" \
        | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' \
        | tr -d '\r' | tr -d '\033' | tr '\t' ' ' | tr '\n' ' '
}

# 多行文本转 JSON 字符串：换行保留成 \n 转义（pl_jesc 会把它压成空格）。
# 用于 include 头部、规则原文、日志这类「要按行看」的内容。
# 转义按字符走一遍，不依赖 sed 的 N/ba 跨行语法（busybox sed 上不稳）。
pl_jesc_ml() {
    printf '%s' "$1" | awk '
    function esc(s,  i, c, o, n) {
        o = ""; n = length(s)
        for (i = 1; i <= n; i++) {
            c = substr(s, i, 1)
            if (c == "\\")       o = o "\\\\"
            else if (c == "\"")  o = o "\\\""
            else if (c == "\t")  o = o " "
            else if (c == "\015") o = o ""
            else if (c >= "\001" && c <= "\037") o = o ""
            else o = o c
        }
        return o
    }
    { if (NR > 1) out = out "\\n"; out = out esc($0) }
    END { printf "%s", out }'
}

# ---------------------------------------------------------------- 进制
# busybox 的 $(( )) 对 >2^31 的字面量行为不稳，全部走 awk
hex2dec() {
    awk -v h="$1" 'BEGIN {
        sub(/^0[xX]/, "", h); h = tolower(h); n = 0
        if (h == "" || length(h) > 8) { print "ERR"; exit 1 }
        for (i = 1; i <= length(h); i++) {
            d = index("0123456789abcdef", substr(h, i, 1)) - 1
            if (d < 0) { print "ERR"; exit 1 }
            n = n * 16 + d
        }
        printf "%.0f\n", n
    }'
}

# 不用 %x：busybox awk 对超过 2^31 的 %x 行为不一致，手工拆半字节
dec2hex() {
    awk -v n="$1" 'BEGIN {
        s = ""
        for (i = 7; i >= 0; i--) {
            d = int(n / (16 ^ i)) % 16
            s = s substr("0123456789abcdef", d + 1, 1)
        }
        sub(/^0+/, "", s)
        if (s == "") s = "0"
        printf "0x%s\n", s
    }'
}

# 位与：band <v> <m> -> v & m（十进制输出）
band() {
    awk -v v="$1" -v m="$2" 'BEGIN {
        r = 0
        for (i = 0; i < 32; i++)
            if (int(m / 2^i) % 2 == 1 && int(v / 2^i) % 2 == 1) r += 2^i
        printf "%.0f\n", r
    }'
}

# 由「保留掩码」推出 ip rule 需要的「匹配掩码」：
#   MARK_MASK 是 mark & mask | value 里的 mask（置 1 的位保留）
#   ip rule 的 mask 是要匹配的位，正好是它的按位取反
pl_match_mask() {  # $1 = 保留掩码(hex)
    _mm=$(hex2dec "$1") || return 1
    [ "$_mm" = 'ERR' ] && return 1
    dec2hex "$(awk -v m="$_mm" 'BEGIN { printf "%.0f", 4294967295 - m }')"
}

# ---------------------------------------------------------------- 地址判断
# in_cidr_file <ip> <file> -> 0 表示命中
# 注意：不能拿 grep '^114.114.' 判归属，补集里存在 114.114.0.0/18 这种兄弟段
in_cidr_file() {
    awk -v ip="$1" '
    function toint(s,  o,n,i,r){ n = split(s,o,"."); r = 0; for (i=1;i<=n;i++) r = r*256 + o[i]; return r }
    BEGIN { ipn = toint(ip); found = 0 }
    {
        sub(/#.*/, ""); gsub(/[ \t\r]/, "");
        if ($0 == "") next;
        p = index($0, "/"); if (!p) next;
        net = toint(substr($0, 1, p-1));
        len = substr($0, p+1) + 0;
        if (len < 0 || len > 32) next;
        blk = 2 ^ (32 - len);
        if (int(ipn / blk) == int(net / blk)) { found = 1; exit }
    }
    END { exit(found ? 0 : 1) }
    ' "$2"
}

# in_cidr_multi <file> <ip>... -> 每行输出 "<ip> 1|0"（1=命中）
# 一次扫描判多个地址。in_cidr_file 每调一次都要重读整个文件，
# 抽查 6 个地址就是扫 6 遍 1.1 万行（本机实测 5s，占一次更新的一半），故有批量版。
# 关键是把「拆点分十进制→整数」提到循环外，每个 CIDR 行只解析一次。
in_cidr_multi() {
    _icm_f="$1"; shift
    awk -v ips="$*" '
    function toint(s,  o,n,i,r){ n = split(s,o,"."); r = 0; for (i=1;i<=n;i++) r = r*256 + o[i]; return r }
    BEGIN {
        na = split(ips, A, " ")
        for (i = 1; i <= na; i++) { V[i] = toint(A[i]); F[i] = 0 }
    }
    {
        sub(/#.*/, ""); gsub(/[ \t\r]/, "");
        if ($0 == "") next;
        p = index($0, "/"); if (!p) next;
        net = toint(substr($0, 1, p-1));
        len = substr($0, p+1) + 0;
        if (len < 0 || len > 32) next;
        blk = 2 ^ (32 - len);
        nb = int(net / blk);
        all = 1;
        for (i = 1; i <= na; i++) {
            if (!F[i] && int(V[i] / blk) == nb) F[i] = 1;
            if (!F[i]) all = 0;
        }
        if (all) exit;      # 全命中就不必再往下扫
    }
    END { for (i = 1; i <= na; i++) print A[i], F[i] }
    ' "$_icm_f"
}

# is_ipv4 <ip>
is_ipv4() {
    awk -v ip="$1" 'BEGIN {
        if (split(ip, o, ".") != 4) exit 1
        for (i = 1; i <= 4; i++) {
            if (o[i] !~ /^[0-9]+$/ || o[i] + 0 > 255) exit 1
        }
        exit 0
    }'
}

pl_now()     { date +%s; }
pl_now_iso() { date '+%Y-%m-%dT%H:%M:%S%z'; }
pl_human()   { date '+%Y-%m-%d %H:%M:%S'; }

# 从导出配置里取变量，未定义时给默认值（配合 set -u 用）
pl_get() {  # $1=变量名 $2=默认值
    eval "_v=\${$1:-}"
    [ -n "$_v" ] || _v="$2"
    printf '%s' "$_v"
}
