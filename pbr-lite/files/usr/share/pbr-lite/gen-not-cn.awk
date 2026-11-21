# gen-not-cn.awk -- 把「中国 IPv4 列表」转成「非中国公网 IPv4 补集」
#
# 调用方式（两趟，中间过一次 sort）：
#   awk -v pass=1 -v excludefile=E -v directfile=D -f gen-not-cn.awk /tmp/all_cn.txt \
#     | sort \
#     | awk -v pass=2 -f gen-not-cn.awk > not-cn.txt
#
#   pass=1: CIDR -> "start end" 区间（左补零到 10 位，普通字典序即数值序，
#           不依赖 busybox sort 对大整数的 -n 是否精确）
#           这一趟同时输出两类「强制直连」的区间：
#             excludefile = 内网/保留段（0.0.0.0/8、10/8、192.168/16 ...）
#             directfile  = 用户加的直连白名单
#           它们都从补集里扣掉，所以最终集合里只有「公网且非中国」。
#   pass=2: 已排序区间做一次扫描求补集，再把每个区间拆成最简 CIDR
#
# 为什么补集里必须扣掉内网段：
#   补集按 0.0.0.0/0 减去中国算，若不扣，192.168.0.0/16 会落进「非中国」集合，
#   内网互访就会被打标送去旁路由 → 旁路由判 private 放行 → 包原样回到路由器 →
#   源地址不变、目的地址仍在集合里 → 再次打标 → 来回弹到兜底 drop。
#   症状是「内网全超时、上外网正常」，极难归因。
#
# 排除段为什么不写死在本文件里：
#   它是安全边界，需要能被 audit、能展示给界面、能单独校验。放在 exclude.txt，
#   由这里读取，避免同一条规则存在两份拷贝而悄悄漂移。
#   文件缺失时退回内置的兜底列表（迁移期的保险）。

BEGIN {
	MAXV4 = 4294967295;

	# 兜底列表：必须与 exclude.txt 逐条一致（不能合并成 192.0.0.0/8 ——
	# 那会把 192.31.x / 192.52.x 这类真实公网段也当成内网直连）
	NEX = split("0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 " \
	            "172.16.0.0/12 192.0.0.0/24 192.0.2.0/24 192.168.0.0/16 " \
	            "198.18.0.0/15 198.51.100.0/24 203.0.113.0/24 " \
	            "224.0.0.0/4 240.0.0.0/4", EX, " ");

	if (pass == 1) {
		got = 0
		if (excludefile != "") {
			while ((getline ln < excludefile) > 0) {
				sub(/#.*/, "", ln); gsub(/[ \t\r]/, "", ln)
				if (ln == "") continue
				emit_range(ln); got++
			}
			close(excludefile)
		}
		if (got == 0) {
			print "[gen-not-cn] WARN: 读不到 " excludefile "，退回内置排除列表" > "/dev/stderr"
			for (i = 1; i <= NEX; i++) emit_range(EX[i])
		}

		if (directfile != "") {
			while ((getline ln < directfile) > 0) {
				sub(/#.*/, "", ln); gsub(/[ \t\r]/, "", ln)
				if (ln == "") continue
				if (index(ln, "/") == 0) ln = ln "/32"
				emit_range(ln)
			}
			close(directfile)
		}
	} else if (pass == 2) {
		cursor = 0;
	}
}

# ---------- pass 1 ----------
pass == 1 {
	line = $0;
	sub(/#.*/, "", line);
	gsub(/^[ \t\r]+/, "", line);
	gsub(/[ \t\r]+$/, "", line);
	if (line == "") next;
	if (index(line, "/") == 0) line = line "/32";
	if (line !~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\/[0-9]+$/) next;
	emit_range(line);
}

# ---------- pass 2 ----------
pass == 2 {
	s = $1 + 0;
	e = $2 + 0;
	if (s > cursor) block(cursor, s - 1);
	if (e + 1 > cursor) cursor = e + 1;
}

END {
	if (pass == 2 && cursor <= MAXV4) block(cursor, MAXV4);
}

# ---------- 函数 ----------
function toint(s,   o, n, i, r) {
	n = split(s, o, ".");
	if (n != 4) return -1;
	r = 0;
	for (i = 1; i <= n; i++) {
		if (o[i] !~ /^[0-9]+$/ || o[i] + 0 > 255) return -1;
		r = r * 256 + o[i];
	}
	return r;
}

function emit_range(cidr,   a, net, len, size) {
	if (split(cidr, a, "/") != 2) return;
	net = toint(a[1]);
	len = a[2] + 0;
	if (net < 0 || len < 0 || len > 32) return;
	size = 2 ^ (32 - len);
	printf "%010.0f %010.0f\n", net, net + size - 1;
}

function ipstr(n) {
	return sprintf("%d.%d.%d.%d", int(n / 16777216) % 256, int(n / 65536) % 256,
	               int(n / 256) % 256, n % 256);
}

# 把 [s,e] 拆成最简 CIDR：每次取「在 s 处对齐且不超出 e」的最大 2 的幂
function block(s, e,   size, k) {
	while (s <= e) {
		size = 1; k = 0;
		while (k < 32 && s % (size * 2) == 0 && s + size * 2 - 1 <= e) {
			size *= 2; k++;
		}
		printf "%s/%d\n", ipstr(s), 32 - k;
		s += size;
	}
}
