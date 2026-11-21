'use strict';
'require baseclass';
'require dom';
'require form';
'require rpc';

// /luci-static/resources/pbr-lite/common.js
//
// 三个页面（概览 / 分流设置 / 规则源）共用的零碎：卡片外壳、格式化、以及
// 「生效半径」的计算规则。
//
// 半径规则为什么要放在前端算一份：
//   后端 job.sh 会自己再算一遍（那份才是权威，因为它跟前端传什么无关）；
//   这里算只是为了让用户在点保存之前就知道「这次要等 10 秒还是 1 秒」。
//   两边规则必须一致，所以 RADIUS 表在两边都写了注释指向对方。

var callJob    = rpc.declare({ object: 'pbr-lite', method: 'job_status' });
var callApply  = rpc.declare({ object: 'pbr-lite', method: 'apply_config', params: [ 'values' ] });
var callExport = rpc.declare({ object: 'pbr-lite', method: 'export_conf' });
var callStatus = rpc.declare({ object: 'pbr-lite', method: 'status' });

// ---------------------------------------------------------------- 视觉规范
// 作用域限定在 .pbrlite 内：不碰主题、不影响 LuCI 其它页面。
//
// 为什么需要它（美化前实测的三个突兀点）：
//   1. 概览顶部用 alert-message success 当横幅 —— 那是一整条实心绿，太吵；
//   2. QWRT 主题的 .table 会把值列带成右对齐，概览自己写了 td left 而
//      source 页用 pb.kv 没写，于是两页键值表一个左一个右；
//   3. 卡片/徽章/内联 code 各写各的内联样式，深浅色主题下不统一。
// 现在结构只负责 class，长什么样集中在这里改。
var CSS = [
	'/* ---- 主题适配层：不猜变量名，只用主题确实定义过的那几个（QWRT design 主题）----',
	'   --sectionbg_color: 浅 #fff / 暗 #1c1c1e（主题自己的 .cbi-section 就用它）',
	'   --cbiline_color:   本身就是完整的 "1px solid <色>" 简写',
	'   缺了就退回中性半透明，深浅色下都成立，绝不再 fallback 到 #fff ---- */',
	'.pbrlite{',
	'  --pb-card-bg:var(--sectionbg_color,rgba(127,127,127,.06));',
	'  --pb-line:var(--cbiline_color,1px solid rgba(127,127,127,.14));',
	'  --pb-muted:rgba(0,0,0,.52)}',
	'@media (prefers-color-scheme:dark){',
	'  .pbrlite{--pb-muted:rgba(255,255,255,.60)}}',
	'/* ---- 卡片：pb.card() 与 form.Map 的分节共用同一套外观 ---- */',
	'.pbrlite .pb-card,',
	'.pbrlite .cbi-map>.cbi-section:not(.pb-card){',
	'  position:relative;background:var(--pb-card-bg);',
	'  border:1px solid rgba(127,127,127,.16);border-radius:8px;',
	'  padding:16px 18px;margin:0 0 14px;box-shadow:0 1px 2px rgba(0,0,0,.03)}',
	'/* 投影在深色底上没有意义，反而像脏边 */',
	'@media (prefers-color-scheme:dark){',
	'  .pbrlite .pb-card,',
	'  .pbrlite .cbi-map>.cbi-section:not(.pb-card){box-shadow:none}}',
	'.pbrlite .pb-card>h3,',
	'.pbrlite .cbi-map>.cbi-section:not(.pb-card)>h3{',
	'  margin:0 0 12px;padding:0 0 10px;',
	'  font-size:14px;font-weight:600;line-height:1.4;text-transform:none;',
	'  color:inherit;border-bottom:var(--pb-line)}',
	'/* 卡片工具（如「刷新」）：浮在标题行右端，不占流，避免标题与内容之间出现空白 */',
	'.pbrlite .pb-card-tool{position:absolute;top:12px;right:16px;z-index:1}',
	'/* 分节描述：和标题拉开一点，别贴着表单 */',
	'.pbrlite .cbi-section-descr{margin:0 0 12px;font-size:12.5px;',
	'  color:var(--pb-muted);line-height:1.7}',
	'/* ---- 表单行：标签列与键值表对齐 ---- */',
	'.pbrlite .cbi-value{padding:7px 0;align-items:flex-start}',
	'.pbrlite .cbi-value-title{width:190px;min-width:150px;padding-top:6px;',
	'  font-size:13px;color:var(--pb-muted);font-weight:400;flex:none}',
	'.pbrlite .cbi-value-field{font-size:13px}',
	'@media (max-width:640px){',
	'  .pbrlite .cbi-value-title{width:auto;display:block;padding-bottom:2px}}',
	'/* ---- 键值表（概览/规则源/诊断共用） ---- */',
	'.pbrlite table.pb-kv{width:100%;border-collapse:collapse;margin:0}',
	'.pbrlite table.pb-kv td{padding:7px 0;text-align:left;vertical-align:top;',
	'  border-bottom:1px solid rgba(127,127,127,.08);font-size:13px;line-height:1.65}',
	'.pbrlite table.pb-kv tr:last-child td{border-bottom:0}',
	'.pbrlite table.pb-kv td.pb-k{width:190px;min-width:150px;padding-right:16px;',
	'  color:var(--pb-muted)}',
	'@media (max-width:640px){',
	'  .pbrlite table.pb-kv td{display:block;width:auto !important;border-bottom:0;padding:2px 0}',
	'  .pbrlite table.pb-kv tr{display:block;padding:6px 0;border-bottom:1px solid rgba(127,127,127,.08)}}',
	'/* ---- 徽章：语义色由 --pb-c 传入（JS 只写变量，不写死颜色），',
	'   这样暗色下能用 color-mix 统一提亮，不必为每个语义色维护两套值 ---- */',
	'.pbrlite .pb-badge{display:inline-block;padding:1px 8px;border-radius:999px;',
	'  font-size:11px;font-weight:500;line-height:1.7;white-space:nowrap;vertical-align:baseline;',
	'  color:var(--pb-c,#3b82f6);background:rgba(127,127,127,.10);',
	'  border:1px solid rgba(127,127,127,.22)}',
	'/* ---- 顶部状态条：左侧色条 + 圆点，替代实心横幅 ---- */',
	'.pbrlite .pb-banner{display:flex;align-items:center;gap:10px;',
	'  padding:11px 14px;margin:0 0 14px;border:1px solid rgba(127,127,127,.16);',
	'  border-left:3px solid var(--pb-c,#607d8b);border-radius:8px;',
	'  font-size:13px;line-height:1.6;background:rgba(127,127,127,.05)}',
	'.pbrlite .pb-dot{width:7px;height:7px;border-radius:50%;flex:none;',
	'  background:var(--pb-c,#607d8b)}',
	'/* 支持 color-mix 时用语义色做真正的浅底；暗色下把色相往白里混，',
	'   否则 #2e7d32 这种深绿落在 #1c1c1e 上几乎看不见 ---- */',
	'@supports (color:color-mix(in srgb,red 50%,white)){',
	'  .pbrlite .pb-badge{',
	'    background:color-mix(in srgb,var(--pb-c,#3b82f6) 12%,transparent);',
	'    border-color:color-mix(in srgb,var(--pb-c,#3b82f6) 30%,transparent)}',
	'  .pbrlite .pb-banner{',
	'    background:color-mix(in srgb,var(--pb-c,#607d8b) 7%,transparent);',
	'    border-color:color-mix(in srgb,var(--pb-c,#607d8b) 22%,transparent)}',
	'  @media (prefers-color-scheme:dark){',
	'    .pbrlite .pb-badge{',
	'      color:color-mix(in srgb,var(--pb-c,#3b82f6) 55%,#fff);',
	'      background:color-mix(in srgb,var(--pb-c,#3b82f6) 20%,transparent);',
	'      border-color:color-mix(in srgb,var(--pb-c,#3b82f6) 42%,transparent)}',
	'    .pbrlite .pb-banner{',
	'      background:color-mix(in srgb,var(--pb-c,#607d8b) 15%,transparent);',
	'      border-color:color-mix(in srgb,var(--pb-c,#607d8b) 28%,transparent);',
	'      border-left-color:color-mix(in srgb,var(--pb-c,#607d8b) 55%,#fff)}',
	'    .pbrlite .pb-dot{background:color-mix(in srgb,var(--pb-c,#607d8b) 60%,#fff)}}}',
	'/* ---- 内联 code ---- */',
	'.pbrlite code{font-family:var(--font-mono,ui-monospace,Menlo,Consolas,monospace);',
	'  font-size:12px;font-style:normal;background:rgba(127,127,127,.09);',
	'  border:1px solid rgba(127,127,127,.12);border-radius:4px;padding:1px 5px;',
	'  word-break:break-all}',
	'/* ---- 按钮：只收拾本 app 自己的按钮，主题控件（动态列表的红×/蓝+）不动 ---- */',
	'.pbrlite .pb-ghost{background:transparent !important;',
	'  border:1px solid rgba(127,127,127,.28) !important;',
	'  color:var(--pb-muted) !important;box-shadow:none !important;',
	'  font-size:12px !important;padding:1px 10px !important}',
	'/* ---- 自检：告警块与折叠组 ---- */',
	'.pbrlite .pb-warnbox{background:rgba(239,108,0,.06);',
	'  border:1px solid rgba(239,108,0,.2);border-radius:6px;',
	'  padding:8px 12px;margin:0 0 10px;font-size:13px}',
	'.pbrlite details{border:1px solid rgba(127,127,127,.12);border-radius:6px;',
	'  padding:6px 10px;margin:4px 0;font-size:13px}',
	'.pbrlite details>summary{cursor:pointer;font-weight:500;outline:none}',
	'.pbrlite details[open]{background:rgba(127,127,127,.03)}',
	'.pbrlite details ul{margin:6px 0 2px;padding-left:18px}',
	'.pbrlite details li{padding:2px 0;font-size:12px;line-height:1.6}',
	'/* ---- 杂项 ---- */',
	'.pbrlite .pb-muted{color:var(--pb-muted)}',
	'/* 语义文字色：浅色用深色值；暗色必须提亮 —— #dc2626 落在 #1c1c1e 上约 3.4:1，',
	'   读起来费劲，换成 #ff8a80 有 7.6:1。所以状态文字一律走这三个类，不写内联色 ---- */',
	'.pbrlite .pb-ok{color:#2e7d32}',
	'.pbrlite .pb-warn{color:#b45309}',
	'.pbrlite .pb-err{color:#c62828}',
	'@media (prefers-color-scheme:dark){',
	'  .pbrlite .pb-ok{color:#81c995}',
	'  .pbrlite .pb-warn{color:#ffb74d}',
	'  .pbrlite .pb-err{color:#ff8a80}}',
	'.pbrlite .pb-actions{display:flex;align-items:center;gap:10px;flex-wrap:wrap}'
].join('\n');

function ensureStyle() {
	if (document.getElementById('pbr-lite-style'))
		return;

	var st = document.createElement('style');

	st.id = 'pbr-lite-style';
	st.textContent = CSS;
	document.head.appendChild(st);
}

ensureStyle();

// 配置项 → 导出变量 → 影响哪一层。
//   include = 要重新生成 nft include（7~12 秒，含 fw4 reload）
//   rule    = 只需重装 ip rule / 路由表（约 1 秒）
//   both    = 两层都要（打标值变了）
//   none    = 只影响下次更新时的判据，数据面不动
// def 是 conf-export.sh 里的默认值，配置没写这个 option 时按它算，
// 否则「没设置」和「设成默认值」会被误判成有改动。
var FIELDS = [
	{ key: 'main.enabled',       sect: 'main',   opt: 'enabled',      exp: 'ENABLED',     def: '1',              r: 'include', label: '启用分流' },
	{ key: 'guard.enabled',      sect: 'guard',  opt: 'enabled',      exp: 'GUARD',       def: '1',              r: 'include', label: '循环兜底' },
	{ key: 'lan.src_addr',       sect: 'lan',    opt: 'src_addr',     exp: 'SRC_ADDRS',   def: '',               r: 'include', label: '生效地址', list: true },
	{ key: 'direct.dst',         sect: 'direct', opt: 'dst',          exp: 'DIRECT_DST',  def: '',               r: 'include', label: '直连白名单', list: true },
	{ key: 'dae.mac',            sect: 'dae',    opt: 'mac',          exp: 'DAE_MAC',     def: '',               r: 'include', label: '旁路由 MAC' },
	{ key: 'dae.next_hop',       sect: 'dae',    opt: 'next_hop',     exp: 'NEXT_HOP',    def: '192.168.0.253',  r: 'rule',    label: '旁路由地址' },
	{ key: 'dae.lan_dev',        sect: 'dae',    opt: 'lan_dev',      exp: 'LAN_DEV',     def: 'br-lan',         r: 'rule',    label: 'LAN 接口' },
	{ key: 'mark.value',         sect: 'mark',   opt: 'value',        exp: 'MARK_VALUE',  def: '0x010000',       r: 'both',    label: '打标值' },
	{ key: 'mark.keep_mask',     sect: 'mark',   opt: 'keep_mask',    exp: 'MARK_MASK',   def: '0xff00ffff',     r: 'both',    label: '保留掩码' },
	{ key: 'source.url',         sect: 'source', opt: 'url',          exp: 'SRC_URL',     def: 'https://ispip.clang.cn/all_cn.txt', r: 'include', label: '列表地址' },
	{ key: 'source.min_entries',  sect: 'source', opt: 'min_entries', exp: 'MIN_ENTRIES', def: '5000',           r: 'none',    label: '条目下限' },
	{ key: 'source.max_drift',    sect: 'source', opt: 'max_drift',   exp: 'MAX_DRIFT',   def: '40',             r: 'none',    label: '漂移阈值' },
	{ key: 'nft.set_src',        sect: 'nft',    opt: 'set_src',      exp: 'SET_SRC',     def: 'pbrlite_src',    r: 'include', label: '源集合名' },
	{ key: 'nft.set_dst',        sect: 'nft',    opt: 'set_dst',      exp: 'SET_DST',     def: 'pbrlite_notcn',  r: 'include', label: '目标集合名' },
	{ key: 'nft.include',        sect: 'nft',    opt: 'include',      exp: 'INCLUDE',     def: '/usr/share/nftables.d/ruleset-post/30-pbr-lite.nft', r: 'include', label: 'include 路径' },
	{ key: 'route.table_id',     sect: 'route',  opt: 'table_id',     exp: 'TABLE_ID',    def: '250',            r: 'rule',    label: '路由表号' },
	{ key: 'route.table_name',   sect: 'route',  opt: 'table_name',   exp: 'TABLE_NAME',  def: 'pbrlite',        r: 'rule',    label: '路由表名' },
	{ key: 'route.pref',         sect: 'route',  opt: 'pref',         exp: 'PREF',        def: '28000',          r: 'rule',    label: '规则优先级' }
];

// ---------------------------------------------------------------- 卡片
// 两个坑（都实测踩过，别改回去）：
//   1. 部分主题（QWRT）把 fieldset 的 legend 设成 display:none，用它当标题会整块看不见
//   2. E() 底层是 L.dom.append()，不递归嵌套数组 —— [a, [b, c]] 会把内层数组
//      String() 成 "[object HTMLDivElement]"，所以这里手工拍平
function card(title, body) {
	var kids = [ E('h3', {}, title) ];

	if (Array.isArray(body))
		kids = kids.concat(body);
	else if (body != null)
		kids.push(body);

	return E('div', { 'class': 'cbi-section pb-card' }, kids);
}

// 键值两列。值可以是字符串或已构造好的节点。
// 对齐/分隔线全部交给 CSS：主题的 .table 会把值列带成右对齐，
// 在这里写内联样式会导致「概览左对齐、规则源右对齐」这种两页不一致。
function kv(rows) {
	var tb = E('table', { 'class': 'table pb-kv' });

	rows.forEach(function(r) {
		if (r == null)
			return;

		tb.appendChild(E('tr', { 'class': 'tr' }, [
			E('td', { 'class': 'td pb-k' }, r[0]),
			E('td', { 'class': 'td pb-v' }, r[1])
		]));
	});

	return tb;
}

// 语义色只以 --pb-c 的形式交给 CSS，不在这里拼 rgba。
// 原因：拼成内联 style 就写死了，暗色主题下没法统一提亮（#2e7d32 的深绿
// 落在 #1c1c1e 上几乎看不见），而 CSS 里能按 prefers-color-scheme 用
// color-mix 把色相往白里混。浅色下不吃 color-mix 也有中性灰底兜着。
function tag(text, color) {
	return E('span', {
		'class': 'pb-badge',
		'style': '--pb-c:' + (color || '#3b82f6')
	}, text);
}

// 顶部状态条：kind = ok / warn / err / idle。
// 用「左侧色条 + 圆点 + 浅底」表达状态，不再用 alert-message 的实心大色块。
function banner(kind, text) {
	var COLORS = { ok: '#2e7d32', warn: '#ef6c00', err: '#c62828', idle: '#607d8b' };

	return E('div', {
		'class': 'pb-banner',
		'style': '--pb-c:' + (COLORS[kind] || COLORS.idle)
	}, [
		E('span', { 'class': 'pb-dot' }),
		E('span', {}, text)
	]);
}

// ---------------------------------------------------------------- 格式化
function fmtBytes(n) {
	n = +n || 0;

	if (n > 1048576)
		return '%.1f MB'.format(n / 1048576);
	if (n > 1024)
		return '%.1f KB'.format(n / 1024);

	return '%d B'.format(n);
}

function fmtTime(epoch) {
	epoch = +epoch || 0;

	if (!epoch)
		return '—';

	var d = new Date(epoch * 1000);

	function p(x) { return (x < 10 ? '0' : '') + x; }

	return '%s-%s-%s %s:%s:%s'.format(d.getFullYear(), p(d.getMonth() + 1), p(d.getDate()),
		p(d.getHours()), p(d.getMinutes()), p(d.getSeconds()));
}

function fmtDur(sec) {
	sec = +sec || 0;

	if (sec < 60)
		return '%d 秒'.format(sec);

	return '%d 分 %d 秒'.format(Math.floor(sec / 60), sec % 60);
}

// 更新的结果值在后端是英文（state.json 里就是这么写的），
// 但界面是中文的，直接当徽章文字会出现「nochange」这种混搭。
var RESULT_TEXT = {
	ok:          '成功',
	nochange:    '无变化',
	rolled_back: '已回滚',
	failed:      '失败'
};

function resultText(r) {
	return RESULT_TEXT[r] || r || '?';
}

// ---------------------------------------------------------------- 导出解析
// /var/run/pbr-lite.conf 是 `KEY='value'` 一行一条，值里不会有单引号
// （conf-export.sh 写完会用 sh -n 自检，带引号的配置在那里就过不去）
function parseExport(text) {
	var out = {};

	(text || '').split('\n').forEach(function(line) {
		var m = line.match(/^([A-Z_][A-Z0-9_]*)=(.*)$/);

		if (!m)
			return;

		var v = m[2];

		if (v.length >= 2 && v.charAt(0) == "'" && v.charAt(v.length - 1) == "'")
			v = v.substring(1, v.length - 1);

		out[m[1]] = v;
	});

	return out;
}

function normValue(f, v) {
	if (v == null)
		return f.def || '';

	if (Array.isArray(v)) {
		var a = v.map(function(x) { return String(x).trim(); }).filter(function(x) { return x != ''; });
		return a.sort().join(' ');
	}

	return String(v).trim();
}

// 返回「改了哪些项」（FIELDS 的子集）
function diffFields(values, live) {
	return FIELDS.filter(function(f) {
		// 只比较「本页收集到的键」。设置页拆成两页后，另一页的分节不在 values 里，
		// 若照常比下去会被 normValue 当成「没设置 → 用默认值」，于是永远报
		// 「生效地址、旁路由 MAC 被改动」这种假改动（高级页实测踩过）。
		if (!(f.key in values))
			return false;

		var nv = normValue(f, values[f.key]);
		var lv = live[f.exp];

		if (lv == null)
			lv = f.def || '';

		lv = String(lv).trim();

		if (f.list) {
			var parts = lv.split(/\s+/).filter(function(x) { return x != ''; });
			lv = parts.sort().join(' ');
		}

		return nv != lv;
	});
}

// 把改动项折算成「要动哪几层」
function radiusOf(changed) {
	var r = { include: false, rule: false, none: false };

	changed.forEach(function(f) {
		if (f.r == 'both')
			r.include = r.rule = true;
		else if (f.r == 'include')
			r.include = true;
		else if (f.r == 'rule')
			r.rule = true;
		else
			r.none = true;
	});

	return r;
}

function radiusText(r) {
	if (r.include && r.rule)
		return '会重建 nft 规则并重装路由表（约 10~15 秒）';
	if (r.include)
		return '会重建 nft 规则并 reload fw4（约 8~12 秒）';
	if (r.rule)
		return '只需重装 ip rule / 路由表（约 1 秒）';
	if (r.none)
		return '只影响下次更新的判据，本次立即完成';

	return '没有检测到改动';
}

function radiusColor(r) {
	if (r.include && r.rule)
		return '#dc2626';
	if (r.include)
		return '#d97706';
	if (r.rule)
		return '#2563eb';

	return '#16a34a';
}

// ---------------------------------------------------------------- 走错走对
function hexnum(s) {
	return /^0x[0-9a-fA-F]{1,8}$/.test(s) ? parseInt(s, 16) : NaN;
}

// mark 与保留掩码的交叉校验（后端 job.sh 也会再查一遍）
function checkMark(value, keepMask) {
	var v = hexnum(value), m = hexnum(keepMask);

	if (isNaN(v))
		return '打标值必须是 0x 开头的十六进制';
	if (isNaN(m))
		return '保留掩码必须是 0x 开头的十六进制';
	if (m == 0)
		return '保留掩码不能是 0';
	if ((v & m) != 0)
		return '保留掩码 %s 会清掉打标值 %s 自身的位，这样打标永远不生效'.format(keepMask, value);
	if (((~m) >>> 0) == 0)
		return '保留掩码不能是 0xffffffff（推导出的匹配掩码是 0，规则会匹配一切）';

	return null;
}

// ---------------------------------------------------------------- 代码块 / 复制
// 等宽、可滚、深浅主题都能看的文本块。
function codeStyle(height) {
	return 'margin:0;max-height:' + (height || '20em') + ';overflow:auto;' +
	       'font-size:90%;line-height:1.45;' +
	       'font-family:var(--font-mono,ui-monospace,Menlo,Consolas,monospace);' +
	       'background:rgba(127,127,127,.10);border:1px solid rgba(127,127,127,.18);' +
	       'padding:.5em .7em;border-radius:4px;' +
	       'white-space:pre-wrap;overflow-wrap:anywhere';
}

function copyText(txt) {
	// LuCI 走 http，不是安全上下文 → navigator.clipboard 不存在，只能用
	// textarea + execCommand。两者都失败就静默（不值得为复制弹错误框）。
	if (navigator.clipboard && navigator.clipboard.writeText)
		return navigator.clipboard.writeText(txt).catch(function() { legacyCopy(txt); });

	legacyCopy(txt);

	function legacyCopy(t) {
		var ta = E('textarea', { 'style': 'position:fixed;top:-1000px;left:-1000px;opacity:0' });
		ta.value = t;
		document.body.appendChild(ta);
		ta.select();
		try { document.execCommand('copy'); } catch (e) { /* ignore */ }
		document.body.removeChild(ta);
		var sel = window.getSelection && window.getSelection();
		if (sel && sel.removeAllRanges)
			sel.removeAllRanges();
	}
}

// getText 是函数而不是字符串：日志面板的内容每轮都在变。
function copyButton(getText, label) {
	label = label || _('复制');

	var btn = E('button', {
		'type': 'button',
		'class': 'btn cbi-button pb-ghost'
	}, label);

	btn.addEventListener('click', function() {
		copyText(getText() || '');
		btn.textContent = _('已复制');
		setTimeout(function() { btn.textContent = label; }, 1500);
	});

	return btn;
}

// 带复制按钮的只读代码块。返回 { node, set }，set 用来换内容。
function codeBlock(text, height) {
	var pre = E('pre', { 'style': codeStyle(height) }, text || '');
	var btn = copyButton(function() { return pre.textContent || ''; }, _('复制'));

	return {
		pre: pre,
		node: E('div', {}, [
			pre,
			E('div', { 'style': 'display:flex;justify-content:flex-end;margin-top:.35em' }, btn)
		]),
		set: function(t) { pre.textContent = t || ''; }
	};
}

// ---------------------------------------------------------------- 任务面板
// 一个能被反复 render 的日志面板。job 的形态见 rpcd 插件里的 job_state()。
function jobPanel() {
	var head = E('div', { 'style': 'margin-bottom:.4em' });
	var log = E('pre', { 'style': codeStyle('16em') });
	var copyBtn = copyButton(function() { return log.textContent || ''; }, _('复制日志'));
	var footRow = E('div', { 'style': 'display:flex;justify-content:flex-end;margin-top:.35em' }, copyBtn);

	// 复制按钮挂在 head 外面、不参与每轮重建，否则「已复制」的状态会被冲掉。

	var box = card('任务进度', [ head, log, footRow ]);

	box.style.display = 'none';

	function stateTag(job) {
		if (job.starting)
			return tag('启动中', '#6b7280');
		if (job.state == 'running')
			return tag('执行中', '#2563eb');
		if (job.state == 'done')
			return tag('完成', '#16a34a');
		if (job.state == 'warn')
			return tag('完成但有告警', '#d97706');
		if (job.state == 'failed')
			return tag('失败', '#dc2626');

		return tag(job.state || '空闲', '#6b7280');
	}

	// 日志用「原地改同一个文本节点」的方式更新，不用 textContent =。
	// 后者会把文本节点整个换掉：一旦用户拖选过日志（想复制），选区锚点失效后
	// 浏览器会把选区扩张到整个 <pre>，看起来就像「整段日志都被选中了」，
	// 而轮询每秒跑一次，等于每帧都在加剧这个现象。
	var lastLog = null;

	function setLog(text) {
		if (text === lastLog)
			return;

		lastLog = text;

		var first = log.firstChild;

		if (first && first.nodeType === 3 && log.childNodes.length === 1)
			first.nodeValue = text;
		else
			log.textContent = text;

		log.scrollTop = log.scrollHeight;
	}

	return {
		node: box,

		render: function(job) {
			job = job || {};
			box.style.display = '';

			// 刚起任务的那一瞬间，job 文件里可能还是上一轮的 kind/result/日志
			// （job.sh 是一个字段一个字段写的）。这时只报「启动中」，
			// 别把上一轮的结论挂在新任务名下 —— 看到过「刷新列表 … 应用完成」这种混搭。
			if (job.starting) {
				var hd = E('div', {}, [ E('strong', {}, '任务 '), ' ', stateTag(job) ]);
				while (head.firstChild)
					head.removeChild(head.firstChild);
				dom.append(head, [ hd, E('div', { 'style': 'margin-top:.3em;color:var(--pb-muted)' },
					'正在启动后台任务…') ]);
				setLog('');
				return;
			}

			var title = (job.kind == 'apply') ? '应用配置'
				: (job.kind == 'update') ? '刷新列表'
				: (job.kind == 'rollback') ? '回滚备份'
				: '任务';

			var line = [ E('strong', {}, title + ' '), ' ', stateTag(job) ];

			if (job.step && (job.starting || job.state == 'running'))
				line.push(' ', E('span', { 'style': 'color:var(--pb-muted)' },
					'· ' + job.step + '…'));

			if (job.elapsed)
				line.push(' ', E('span', { 'style': 'color:var(--pb-muted)' },
					'· 已用 ' + fmtDur(job.elapsed)));

			if (job.result)
				line.push(E('div', { 'style': 'margin-top:.3em' }, job.result));

			if (job.state == 'failed')
				line.push(E('div', { 'style': 'margin-top:.35em;font-size:92%', 'class': 'pb-err' },
					'失败时配置已自动退回上一份。表单里显示的还是你刚才填的值，' +
					'刷新页面即可看到当前真正的配置。'));

			if (job.stale)
				line.push(E('div', { 'style': 'margin-top:.3em', 'class': 'pb-warn' },
					'任务超过 5 分钟仍显示执行中，可能已经卡住（看下面的日志和系统日志）'));

			while (head.firstChild)
				head.removeChild(head.firstChild);

			dom.append(head, line);

			// 日志只留尾部：pw 一次刷几百行没有意义，反而把页面顶长
			var lines = (job.log || '').replace(/\s+$/, '').split('\n');

			if (lines.length > 24)
				lines = lines.slice(lines.length - 24);

			setLog(lines.join('\n'));
		}
	};
}

// 轮询到任务结束为止；每次拿到状态都回调 render
function watchJob(render, done) {
	var stopped = false;

	function tick() {
		if (stopped)
			return;

		return callJob().then(function(r) {
			var job = (r && r.job) ? r.job : {};

			render(job);

			if (job.active)
				window.setTimeout(tick, 1000);
			else if (done)
				done(job);
		}).catch(function(e) {
			if (done)
				done({ state: 'failed', result: '读取任务状态失败：' + e });
		});
	}

	tick();

	return { stop: function() { stopped = true; } };
}

// ---------------------------------------------------------------- 弹层
// 自己画 overlay，不用 ui.showModal：实测那套弹窗里 E() 挂的 click 监听不生效
// （按钮渲染出来了，点了没反应），而且它的遮罩会一直拦住后面的点击。
// 这里一律 addEventListener，不依赖主题/框架的弹窗实现。
function mkBtn(label, cls, fn) {
	var b = document.createElement('button');

	b.className = cls || 'btn';
	b.textContent = label;
	b.style.marginLeft = '.5em';
	b.addEventListener('click', fn);

	return b;
}

function overlay(title, bodyNodes, buttons) {
	var panel = document.createElement('div');

	panel.style.cssText =
		'background:var(--sectionbg_color,#fff);color:inherit;' +
		'max-width:560px;width:94%;max-height:86vh;overflow:auto;border-radius:8px;' +
		'box-shadow:0 10px 40px rgba(0,0,0,.35);padding:1.1em 1.3em;text-align:left';

	var h = document.createElement('h4');

	h.textContent = title;
	h.style.cssText = 'margin:0 0 .7em;font-size:105%;font-weight:600';
	panel.appendChild(h);

	(bodyNodes || []).forEach(function(n) { panel.appendChild(n); });

	var bar = document.createElement('div');

	bar.style.cssText = 'margin-top:1.1em;text-align:right';

	var wrap = document.createElement('div');

	wrap.style.cssText =
		'position:fixed;inset:0;z-index:10000;background:rgba(0,0,0,.45);' +
		'display:flex;align-items:center;justify-content:center;padding:1em';

	function close() {
		if (wrap.parentNode)
			wrap.parentNode.removeChild(wrap);
	}

	(buttons || []).forEach(function(b) {
		bar.appendChild(mkBtn(b.label, b.cls, function() {
			if (b.fn)
				b.fn();
			if (!b.keepOpen)
				close();
		}));
	});

	panel.appendChild(bar);
	wrap.appendChild(panel);
	document.body.appendChild(wrap);

	return { close: close, panel: panel };
}

// 让用户手打 CONFIRM 才继续。用于打标值这类「改错了会丢流量」的项。
function confirmTyped(msg) {
	return new Promise(function(resolve) {
		var input = document.createElement('input');

		input.className = 'cbi-input-text';
		input.type = 'text';
		input.autocomplete = 'off';
		input.placeholder = 'CONFIRM';
		input.style.cssText = 'width:100%;margin-top:.6em;box-sizing:border-box;padding:.35em .5em';

		var hint = E('p', { 'style': 'margin:.5em 0 0;font-size:90%', 'class': 'pb-warn' },
			'确认无误请在下面输入 CONFIRM（全大写）再点「确认应用」。');

		overlay('危险操作确认', [ E('p', { 'style': 'margin:0;line-height:1.6' }, msg), input, hint ], [
			{ label: '取消', cls: 'btn', fn: function() { resolve(false); } },
			{ label: '确认应用', cls: 'btn cbi-button-negative important',
			  fn: function() { resolve(input.value.trim() == 'CONFIRM'); } }
		]);

		input.focus();
	});
}

function showError(title, msg) {
	overlay(title, [ E('p', { 'style': 'margin:0;white-space:pre-wrap;line-height:1.6' }, msg) ], [
		{ label: '知道了', cls: 'btn' }
	]);
}

// 提交一次配置改动：算半径 →（可选）确认 → apply_config → 轮询到结束
// opts = { values, live, panel, confirm(changed, radius)->bool|Promise, onProgress, onDone }
function applyFlow(opts) {
	var changed = diffFields(opts.values, opts.live);
	var r = radiusOf(changed);

	var go = function() {
		return callApply(opts.values).then(function(res) {
			if (!res || res.ok !== true) {
				showError('保存失败', (res && res.error) || '未知错误');
				return null;
			}

			if (opts.panel)
				opts.panel.render(res.job || {});

			watchJob(function(job) {
				if (opts.panel)
					opts.panel.render(job);
				if (opts.onProgress)
					opts.onProgress(job);
			}, function(job) {
				if (opts.onDone)
					opts.onDone(job, changed, r);
			});

			return res;
		});
	};

	if (opts.confirm && changed.length)
		return Promise.resolve(opts.confirm(changed, r)).then(function(ok) {
			return ok ? go() : null;
		});

	return go();
}

// ---------------------------------------------------------------- 设置页骨架
// 「分流设置」和「高级设置」是同一套流程的两张皮：都是
// 「收集本页字段 → 算生效半径 → 提交 → 轮询」，差别只在于渲染哪些分节。
// 所以逻辑放这里，两个 view 只负责描述自己的分节。
//
// opts = { title, descr, own: [分节名], build(m, page), markCheck, confirmMark }
function settingsPage(opts) {
	var own = opts.own || [];

	return {
		load: function() {
			return Promise.all([ callExport(), callStatus() ]);
		},

		render: function(data) {
			var self = this;

			this.live = parseExport((data[0] && data[0].ok) ? data[0].text : '');
			this.status = data[1] || {};
			this.panel = jobPanel();

			var m = new form.Map('pbr-lite', opts.title, opts.descr);
			this.map = m;

			opts.build(m, this);

			// 让 uci 数据始终跟着表单走。
			//
			// LuCI 的 CBIAbstractValue.parse 里是这么写的：
			//     else if (this.forcewrite || !isEqual(cval, fval)) write(sid, fval)
			// cval 是「加载时读到的配置值」。于是「把值改回原样」这一步 fval == cval，
			// **不会写**，而且上一次记下的 change 也不会被清掉。
			// 后果不是显示不准那么轻：collect() 读的是 data，用户改了又改回去，
			// 读到的还是中间那个值，点保存就把中间值落盘了（实测：MAC 改成 …df 再改回 …de，
			// 保存下去的是 …df，因为数据面用的就是这个 MAC，下一次会去丢错误的包）。
			// 打开 forcewrite 后每轮都写，data 与表单一致。
			m.children.forEach(function(sec) {
				(sec.children || []).forEach(function(opt) {
					opt.forcewrite = true;
				});
			});

			this.hintBody = E('div', {});
			var hintCard = card(_('保存后会发生什么'), this.hintBody);

			return m.render().then(function(node) {
				// padding-bottom：主题把「保存 / 复位」放在底部固定条里（cbi-page-actions），
				// 页面到底时按钮正好压在条下面，滚也滚不开。
				var wrap = E('div', { 'class': 'pbrlite', 'style': 'padding-bottom:5em' }, [ node, hintCard, self.panel.node ]);

				// collect() 要用它当查询根：这里 wrap 还没挂进 #view，
				// document.querySelector 查不到表单里的任何控件。
				self.root = wrap;

				var timer = null;
				var bump = function() {
					if (timer)
						window.clearTimeout(timer);
					timer = window.setTimeout(function() { self.refreshHint(); }, 250);
				};

				wrap.addEventListener('input', bump);
				wrap.addEventListener('change', bump);
				wrap.addEventListener('click', bump);

				self.refreshHint();

				if (self.status.job && (self.status.job.state || self.status.job.active))
					self.panel.render(self.status.job);

				if (opts.afterRender)
					opts.afterRender(self, wrap);

				return wrap;
			});
		},

		// 从表单收集「值 → 配置文件里的样子」。
		// 只提交本页渲染的分节 —— 别的分节读出来是空的，一起提交等于清空。
		collect: function() {
			var m = this.map, out = {};
			var root = this.root || document;

			return m.parse().then(function() {
				FIELDS.forEach(function(f) {
					if (own.indexOf(f.sect) < 0)
						return;

					// Flag 有个坑：不勾选时 LuCI 的 write() 是 unset，读回来是 null，
					// 和「没配置过、用默认值」分不开。而这两个开关的默认值都是开，
					// 所以只能直接看 DOM 里的勾选状态。
					if (f.key == 'main.enabled' || f.key == 'guard.enabled') {
						// 控件 id 是 widget.cbid.<config>.<section>.<option>
						// （name 是随机生成的 cbXXXXXXXX，认不出来）
						var el = root.querySelector('[id="widget.cbid.pbr-lite.%s.%s"]'.format(f.sect, f.opt));

						out[f.key] = el ? (el.checked ? '1' : '0')
							: ((m.data.get('pbr-lite', f.sect, f.opt) == '1') ? '1' : '0');

						return;
					}

					var v = m.data.get('pbr-lite', f.sect, f.opt);

					if (Array.isArray(v))
						out[f.key] = v.filter(function(x) { return x != ''; });
					else
						out[f.key] = (v == null) ? '' : String(v);
				});

				return out;
			});
		},

		refreshHint: function() {
			var self = this;

			return this.collect().then(function(values) {
				var changed = diffFields(values, self.live);
				var r = radiusOf(changed);
				var kids = [];

				if (!changed.length) {
					kids.push(E('span', { 'class': 'pb-ok' },
						_('表单值与当前生效值一致，无需应用')));
				}
				else {
					kids.push(E('div', { 'style': 'margin-bottom:.4em' },
						E('strong', { 'style': 'color:' + radiusColor(r) }, radiusText(r))));

					kids.push(E('div', { 'style': 'font-size:92%' }, _('改动项：') +
						changed.map(function(f) { return f.label; }).join(_('、'))));

					if (r.include) {
						kids.push(E('div', { 'style': 'margin-top:.4em;font-size:92%;color:var(--pb-muted)' },
							_('重建时会用上一次缓存的 CN 列表，不会再下载一遍（除非你改了列表地址）。')));
					}

					if (r.rule && !r.include) {
						kids.push(E('div', { 'style': 'margin-top:.4em;font-size:92%;color:var(--pb-muted)' },
							_('路由表重装是幂等的：先删旧 ip rule 再装新的，中间不 flush 表，') +
							_('打标流量不会掉回主表。')));
					}
				}

				self.hintBody.textContent = '';
				kids.forEach(function(k) { self.hintBody.appendChild(k); });
			}).catch(function() {});
		},

		doApply: function() {
			var self = this;

			return this.collect().then(function(values) {
				// 语义校验：打标值与保留掩码的位不能重叠。
				// 后端 job.sh 还会再查一次，但在这里挡住能少等一次「10 秒后失败再回滚」。
				if (opts.markCheck) {
					var mk = checkMark(values['mark.value'], values['mark.keep_mask']);

					if (mk) {
						showError(_('配置有问题'), mk);
						return;
					}
				}

				return applyFlow({
					values: values,
					live: self.live,
					panel: self.panel,

					confirm: function(changed) {
						var risky = opts.confirmMark && changed.some(function(f) {
							return f.key.indexOf('mark.') == 0;
						});

						if (!risky)
							return true;

						return confirmTyped(
							_('你改动了打标值或保留掩码。这一步会同时改 nft 规则与 ip rule，') +
							_('改错的典型后果是「打标了但规则认不出」，流量会从主表出去。') +
							_('程序会先加一条临时规则顶住切换窗口，但请确认你算过掩码。'));
					},

					onDone: function(job) {
						if (job.state != 'done' && job.state != 'warn')
							return;

						// 应用成功：把「已生效快照」换成新的，否则提示区会一直报同样的改动
						return callExport().then(function(e) {
							if (e && e.ok)
								self.live = parseExport(e.text);

							return self.refreshHint();
						});
					}
				});
			});
		},

		handleSave: function() {
			return this.doApply();
		},

		handleSaveApply: function() {
			return this.doApply();
		},

		handleReset: null
	};
}

// LuCI 的 require 只接受「构造函数」，返回普通对象会直接抛
// "factory yields invalid constructor"，所以这里必须走 baseclass.extend。
//
// 另一个坑：不同版本的 require 到底返回「类」还是「实例」并不一致（实测本机
// 返回的那个对象上拿不到构造函数上的静态成员）。所以每个函数都同时挂到
// 类上和 prototype 上 —— 两种情况都能取到，代价只是多一行赋值。
var API = {
	FIELDS:       FIELDS,
	card:         card,
	kv:           kv,
	tag:          tag,
	banner:       banner,
	fmtBytes:     fmtBytes,
	fmtTime:      fmtTime,
	fmtDur:       fmtDur,
	resultText:   resultText,
	parseExport:  parseExport,
	diffFields:   diffFields,
	radiusOf:     radiusOf,
	radiusText:   radiusText,
	radiusColor:  radiusColor,
	checkMark:    checkMark,
	applyFlow:    applyFlow,
	settingsPage: settingsPage,
	callExport:   callExport,
	callStatus:   callStatus,
	jobPanel:     jobPanel,
	watchJob:     watchJob,
	confirmTyped: confirmTyped,
	showError:    showError,
	codeStyle:    codeStyle,
	codeBlock:    codeBlock,
	copyButton:   copyButton,
	copyText:     copyText
};

var Common = baseclass.extend({ __name__: 'PBRLiteCommon' });

for (var _k in API) {
	Common[_k] = API[_k];
	Common.prototype[_k] = API[_k];
}

return Common;
