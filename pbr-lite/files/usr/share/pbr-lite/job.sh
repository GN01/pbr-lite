#!/bin/sh
# job.sh -- 长任务执行器（供 LuCI 异步调用，也可直接在命令行跑）
#
# 为什么要有它：
#   rpcd 的 ubus 方法调用是同步的，而「应用配置」要跑 7~12 秒。让浏览器干等会撞上
#   超时，界面也会僵住。所以 ubus 那边只做「校验 + 落配置 + 起任务」然后立刻返回，
#   真正的活在这里跑，进度写进 /var/run/pbr-lite/job.*，前端轮询读。
#
# 为什么状态是几个小文件而不是一个 JSON：
#   shell 里拼 JSON 是引号地狱，而 ucode 侧组装 JSON 本来就顺手。分工：这里只管
#   写「纯文本状态」，JSON 由 rpcd 插件合成。每个状态都用「写 .tmp 再 mv」落盘，
#   读的一方永远看不到写了一半的值。
#
# 生效半径（这是本文件的核心）：
#   不是「改了配置就全量重来」，而是先跟「正在生效的那份导出」
#   （/var/run/pbr-lite.conf）逐项比对，再决定要动哪一层：
#     集合/include 相关 -> 必须重建 include（7 秒级）
#     仅路由层相关     -> 只需重装 ip rule / 路由表（1 秒级）
#     只影响下次校验   -> 什么都不用做
#   比的是「导出文件」而不是前端传来的改动列表：前端漏报多报都会让半径算错，
#   而那份导出就是数据面的现状，不会骗人。
#
# 用法：
#   job.sh apply                 应用已提交的 UCI 配置
#   job.sh update [--no-fetch]   刷新列表（--no-fetch 用缓存的 CN 列表重建）
#   job.sh rollback [N]          回滚 include 到第 N 新的备份
#
# 退出码：0 成功  1 失败  2 参数错误  3 已有任务在跑
set -u

SHARE_DIR=/usr/share/pbr-lite
. "$SHARE_DIR/lib.sh"

UPDATE='/usr/sbin/pbr-lite-update'
INITD='/etc/init.d/pbr-lite'
LOGF="$PL_RUNDIR/job.log"
PENDING="$PL_RUNDIR/job.pending"
PREV="$PL_RUNDIR/config.prev"
CAND="$PL_RUNDIR/pbr-lite.candidate"

mkdir -p "$PL_RUNDIR" 2>/dev/null

# ---------------------------------------------------------------- 状态文件
_jput() {  # $1=字段 $2=值
	printf '%s' "$2" > "$PL_RUNDIR/job.$1.tmp" 2>/dev/null &&
		mv -f "$PL_RUNDIR/job.$1.tmp" "$PL_RUNDIR/job.$1" 2>/dev/null
}

_jlog() {
	printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*" >> "$LOGF" 2>/dev/null
	logger -t pbr-lite-job "$*" 2>/dev/null
}

_jfin() {  # $1=state(done|failed|warn)  $2=结论
	_jput result "$(printf '%s' "$2" | tr -d '\n' | cut -c1-300)"
	_jput state "$1"
	_jput ended "$(pl_now)"
	_jlog "结束（$1）：$2"
}

# ---------------------------------------------------------------- 参数
KIND="${1:-}"
[ -n "$KIND" ] || { echo 'usage: job.sh apply|update|rollback [args]' >&2; exit 2; }
shift || true

case "$KIND" in
	apply|update|rollback) ;;
	*) echo "unknown kind: $KIND" >&2; exit 2 ;;
esac

# ---------------------------------------------------------------- 单例
# 同时跑两个 job 会互相踩 include / nft，宁可拒绝也不排队。
exec 9>"$PL_RUNDIR/job.lock" || exit 1
if ! flock -n 9; then
	rm -f "$PENDING" 2>/dev/null
	echo 'another job is running' >&2
	exit 3
fi

# 拿到锁了：先把「启动中」标记摘掉，再写 running，前端就不会卡在启动态
rm -f "$PENDING" 2>/dev/null
: > "$LOGF" 2>/dev/null
# 先占 state=running，再填其它字段：读的一方以 state 为准，
# 反过来的话会有几十毫秒的窗口看到「state 还是上一轮的 done，kind 已经是新的」，
# 界面就会把旧结论挂在新任务名下。
_jput state running
_jput id "$(date '+%Y%m%d-%H%M%S')"
_jput kind "$KIND"
_jput started "$(pl_now)"
_jput ended 0
_jput step '准备'
_jput result ''

_jlog "任务开始：$KIND $*"

# ---------------------------------------------------------------- 临时并存规则
# mark 变了的时候用：include 换掉的那一刻新 mark 开始生效，而 ip rule 还是旧的，
# 中间那一秒打标流量没有规则认，会掉回主表走真实出口。先在另一个 pref 上补一条
# 指向同一张表的规则，等 init.d 装好正式规则再撤掉，窗口就没了。
_tp=''
_cleanup_tmp_rule() {
	[ -n "$_tp" ] || return 0
	ip -4 rule del pref "$_tp" 2>/dev/null && _jlog "已撤掉临时并存规则 pref $_tp"
	_tp=''
}
trap '_cleanup_tmp_rule' EXIT INT TERM

# ---------------------------------------------------------------- 工具
_cand_val() {  # 从候选导出里取一个变量
	( . "$CAND" 2>/dev/null; eval "printf '%s' \"\${$1-}\"" )
}
_live_val() {
	( . "$PL_CONF" 2>/dev/null; eval "printf '%s' \"\${$1-}\"" )
}
_pk_same() {  # $1=key  -> 0 表示候选与生效值相同
	[ "$(_live_val "$1")" = "$(_cand_val "$1")" ]
}

# 结论行取「调用方脚本自己打的最后一行」，要跳过本文件打的 [HH:MM:SS] 日志
# （两者都以 [ 开头，只能按 HH:MM:SS 的形状排掉，否则会把自己的开场白当成结论）
_last_log_line() {
	tail -n 30 "$LOGF" 2>/dev/null \
		| grep -v '^\[[0-9][0-9]:[0-9][0-9]:[0-9][0-9]\]' \
		| grep -v '^[[:space:]]*$' \
		| tail -n 1 | sed 's/^\[[a-zA-Z-]*\] //'
}

# ---------------------------------------------------------------- 生效半径
_need_update=0   # 要重建 include（含 fw4 reload）
_need_restart=0  # 要重装 ip rule / 路由表
_need_fetch=1    # 重建时是否真去下载 CN 列表
_changed=''

_plan() {
	# 集合/include 相关：任何一个变了都得重新生成 include
	for _k in ENABLED GUARD SRC_ADDRS DAE_MAC MARK_VALUE MARK_MASK \
	          SET_SRC SET_DST INCLUDE DIRECT_DST; do
		_pk_same "$_k" || { _need_update=1; _changed="$_changed $_k"; }
	done
	# 路由层相关：只影响 ip rule 与表 250，不需要碰 nft
	for _k in NEXT_HOP LAN_DEV TABLE_ID TABLE_NAME PREF MATCH_VALUE MATCH_MASK; do
		_pk_same "$_k" || { _need_restart=1; _changed="$_changed $_k"; }
	done
	# 列表来源：只有下次下载才用到，但它变了就说明用户想换源，顺手拉一次
	_pk_same SRC_URL || { _need_update=1; _need_fetch=1; _changed="$_changed SRC_URL"; }

	# 条目下限/漂移阈值只影响「下次更新时的判据」，不改变现在的数据面
	for _k in MIN_ENTRIES MAX_DRIFT; do
		_pk_same "$_k" || _jlog "注意：$_k 变了，只影响下次更新的判据，本次无需动作"
	done

	# 重建时能用缓存就别下载：CN 列表没变，不该让上游的一次 5xx 把这次编辑弄失败
	_pk_same SRC_URL && _need_fetch=0

	[ -n "$_changed" ] || _changed='（无）'
}

# ---------------------------------------------------------------- 回滚
_recover() {
	[ -f "$PREV" ] || { _jlog '没有配置快照，无法自动回滚，请手工检查'; return 1; }
	_jput step '回滚'
	_jlog '恢复上一份配置…'
	if ! cp -f "$PREV" /etc/config/pbr-lite; then
		_jlog '恢复配置文件失败（/etc/config/pbr-lite）'
		return 1
	fi
	uci -q commit pbr-lite 2>/dev/null || _jlog 'uci commit 失败'
	"$SHARE_DIR/conf-export.sh" >/dev/null 2>&1 || _jlog 'conf-export 失败'
	# 配置回去了，include 与路由也要跟着回到同一版，否则三层不一致
	"$UPDATE" --no-fetch >> "$LOGF" 2>&1 || _jlog '回滚时重建 include 失败'
	"$INITD" restart >> "$LOGF" 2>&1 || _jlog '回滚时重装路由失败'
	_jlog '回滚完成：配置、include、路由都已回到上一版'
	return 0
}

# ---------------------------------------------------------------- apply
do_apply() {
	_jput step '提交配置'
	uci -q commit pbr-lite || { _jfin failed 'uci commit 失败'; return 1; }

	_jput step '校验配置'
	rm -f "$CAND"
	if ! "$SHARE_DIR/conf-export.sh" "$CAND" >/dev/null 2>&1; then
		_jlog 'conf-export 失败：配置里有非法取值'
		_recover
		_jfin failed '配置导出失败（取值非法），已回滚'
		return 1
	fi
	[ -s "$CAND" ] || { _recover; _jfin failed '导出文件为空，已回滚'; return 1; }

	# mark 与保留掩码的交叉校验必须在动 nft 之前做：
	#   1. 保留掩码会清掉自己置的位 -> 打标永远不生效
	#   2. 匹配掩码（保留掩码取反）为 0 -> ip rule 匹配一切
	_mv=$(_cand_val MARK_VALUE); _mm=$(_cand_val MARK_MASK)
	if [ "$(band "$(hex2dec "$_mv")" "$(hex2dec "$_mm")")" != '0' ]; then
		_jlog "校验失败：保留掩码 $_mm 会清掉打标值 $_mv 自身的位"
		_recover
		_jfin failed "保留掩码 $_mm 会清掉打标值 $_mv 的位，已回滚"
		return 1
	fi
	_mm2=$(pl_match_mask "$_mm" 2>/dev/null)
	if [ -z "$_mm2" ] || [ "$(hex2dec "$_mm2")" = '0' ]; then
		_jlog "校验失败：由 $_mm 推出的匹配掩码是 0"
		_recover
		_jfin failed "保留掩码 $_mm 推出匹配掩码 0，已回滚"
		return 1
	fi

	_jput step '算生效半径'
	if [ ! -f "$PL_CONF" ]; then
		_jlog '没有正在生效的导出，按全量处理'
		_need_update=1; _need_restart=1; _need_fetch=0; _changed='（首次应用）'
	else
		_plan
	fi
	_jlog "变动项：$_changed"
	_jlog "需要重建 include=$_need_update（下载=$_need_fetch）  重装路由=$_need_restart"

	if [ "$_need_update" = '0' ] && [ "$_need_restart" = '0' ]; then
		_jfin done '配置已保存，数据面无需变动'
		return 0
	fi

	# 旧集合名/旧 include 路径的残留：改名之后 fw4 仍会把老文件装进来，
	# 结果是两套规则同时生效 + 两个空壳集合。必须在换新之前把旧名记下来。
	_old_set_src=$(_live_val SET_SRC)
	_old_set_dst=$(_live_val SET_DST)
	_old_include=$(_live_val INCLUDE)

	if [ "$_need_restart" = '1' ] && [ "$_need_update" = '1' ]; then
		_nv=$(_cand_val MATCH_VALUE); _nm=$(_cand_val MATCH_MASK)
		_np=$(_cand_val PREF); _nt=$(_cand_val TABLE_ID)
		if [ -n "$_nv" ] && [ -n "$_nm" ] && [ -n "$_np" ] && [ -n "$_nt" ]; then
			_tp=$((_np + 100))
			[ "$_tp" -gt 32765 ] && _tp=$((_np - 100))
			if ip -4 rule add fwmark "$_nv/$_nm" lookup "$_nt" pref "$_tp" 2>/dev/null; then
				_jlog "已加临时并存规则：pref $_tp  fwmark $_nv/$_nm -> table $_nt"
			else
				_tp=''
				_jlog '临时并存规则没加成（继续，最坏情况是切换瞬间有一秒空窗）'
			fi
		fi
	fi

	if [ "$_need_update" = '1' ]; then
		_jput step '重建 include'
		if [ "$_need_fetch" = '1' ]; then
			_jlog '重建 include（联网下载 CN 列表）'
			"$UPDATE" >> "$LOGF" 2>&1
		else
			_jlog '重建 include（用缓存的 CN 列表，不下载）'
			"$UPDATE" --no-fetch >> "$LOGF" 2>&1
		fi
		_rc=$?
		if [ "$_rc" != '0' ]; then
			_jlog "pbr-lite-update 失败，退出码 $_rc"
			_cleanup_tmp_rule
			_recover
			_jfin failed '重建 include 失败，已回滚到上一份配置'
			return 1
		fi
	fi

	if [ "$_need_restart" = '1' ]; then
		_jput step '重装路由'
		"$INITD" restart >> "$LOGF" 2>&1
		_rc=$?
		if [ "$_rc" != '0' ]; then
			_jlog "init.d restart 失败，退出码 $_rc"
			_cleanup_tmp_rule
			_recover
			_jfin failed '重装 ip rule / 路由表失败，已回滚'
			return 1
		fi
	fi

	_cleanup_tmp_rule

	# 清理改名残留：先删旧 include 文件（否则 fw4 会把两套规则都装上），
	# 再删旧集合（fw4 reload 不清 set 对象，改名后旧集合会一直躺在内核里）
	if [ "$_need_update" = '1' ]; then
		_new_include=$(_cand_val INCLUDE)
		if [ -n "$_old_include" ] && [ "$_old_include" != "$_new_include" ] \
		   && [ -f "$_old_include" ]; then
			rm -f "$_old_include" && _jlog "已删除旧 include：$_old_include"
		fi
		for _s in "$_old_set_src" "$_old_set_dst"; do
			[ -n "$_s" ] || continue
			[ "$_s" = "$(_cand_val SET_SRC)" ] && continue
			[ "$_s" = "$(_cand_val SET_DST)" ] && continue
			if nft list set inet fw4 "$_s" >/dev/null 2>&1; then
				nft delete set inet fw4 "$_s" 2>/dev/null \
					&& _jlog "已清理旧集合：$_s" \
					|| _jlog "旧集合 $_s 仍被引用，删不掉（fw4 reload 后再试）"
			fi
		done
	fi

	# 收尾自检：只认 FAIL，WARN 不算失败（HFO 那条警告是常态）
	_jput step '自检'
	if command -v jq >/dev/null 2>&1; then
		_v=$("$SHARE_DIR/verify.sh" --json --fast 2>/dev/null)
		_f=$(printf '%s' "$_v" | jq -r '.summary.fail // 0' 2>/dev/null)
		_p=$(printf '%s' "$_v" | jq -r '.summary.pass // 0' 2>/dev/null)
		if [ "${_f:-0}" != '0' ]; then
			_jlog "自检有 ${_f} 项失败"
			printf '%s' "$_v" | jq -r '.items[] | select(.status=="fail") | "自检失败：" + .msg' \
				>> "$LOGF" 2>/dev/null
			_jfin warn "已应用，但自检 ${_f} 项失败（未自动回滚，请看自检页）"
			return 0
		fi
		_jfin done "应用完成（自检 ${_p:-?} 项通过）"
	else
		_jfin done '应用完成（无 jq，跳过收尾自检）'
	fi
	return 0
}

# ---------------------------------------------------------------- update
do_update() {
	_flag="${1:-}"
	_jput step '刷新列表'
	if [ "$_flag" = '--no-fetch' ]; then
		_jlog '刷新列表（不下载，用缓存 CN 列表）'
	else
		_jlog '刷新列表（下载 CN 列表）'
	fi
	"$UPDATE" $_flag >> "$LOGF" 2>&1
	_rc=$?
	if [ "$_rc" = '0' ]; then
		_jfin done "$(_last_log_line)"
	else
		_jfin failed "更新失败（退出码 $_rc）：$(_last_log_line)"
	fi
	[ "$_rc" = '0' ] && return 0 || return 1
}

# ---------------------------------------------------------------- rollback
do_rollback() {
	_n="${1:-1}"
	case "$_n" in
		''|*[!0-9]*) _jfin failed '备份序号必须是数字'; return 1 ;;
	esac
	_jput step "回滚到备份 $_n"
	_jlog "回滚 include 到第 $_n 新的备份"
	"$UPDATE" --rollback "$_n" >> "$LOGF" 2>&1
	_rc=$?
	if [ "$_rc" = '0' ]; then
		_jfin done "已回滚到备份 $_n"
	else
		_jfin failed "回滚失败（退出码 $_rc）：$(_last_log_line)"
	fi
	[ "$_rc" = '0' ] && return 0 || return 1
}

# ---------------------------------------------------------------- 分发
case "$KIND" in
	apply)    do_apply ;;
	update)   do_update "${1:-}" ;;
	rollback) do_rollback "${1:-1}" ;;
esac
exit $?
