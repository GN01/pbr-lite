'use strict';
'require view';
'require poll';
'require rpc';
'require ui';
'require pbr-lite.common as pb';

/*
 * PBR Lite 概览（只读）
 *
 * 约束（来自设计稿 C1）：界面里只出现「计数」，绝不渲染那 1.1 万条 CIDR。
 * 需要看单条归属时走 lookup_ip，一次一个 IP。
 *
 * 所有数据来自 ubus 对象 pbr-lite，不在这里拼任何 shell 命令。
 */

var callStatus = rpc.declare({
	object: 'pbr-lite',
	method: 'status',
	expect: { }
});

var callVerify = rpc.declare({
	object: 'pbr-lite',
	method: 'verify',
	params: { fast: 1 },
	nobatch: true,
	expect: { }
});

var COLORS = {
	ok:   '#2e7d32',
	warn: '#ef6c00',
	err:  '#c62828',
	idle: '#607d8b'
};

function badge(text, kind) {
	// 样式统一走 pb.tag（浅底徽章），这里只保留「语义 → 颜色」的映射
	return pb.tag(text, COLORS[kind] || COLORS.idle);
}

function fmtNum(n) {
	n = +n || 0;
	return String(n).replace(/\B(?=(\d{3})+(?!\d))/g, ',');
}

function fmtBytes(n) {
	n = +n || 0;
	if (n >= 1048576)
		return '%.1f MiB'.format(n / 1048576);
	if (n >= 1024)
		return '%.1f KiB'.format(n / 1024);
	return '%d B'.format(n);
}

function fmtTime(ts) {
	if (!ts)
		return '-';

	var d = new Date(ts * 1000);

	return '%04d-%02d-%02d %02d:%02d:%02d'.format(
		d.getFullYear(), d.getMonth() + 1, d.getDate(),
		d.getHours(), d.getMinutes(), d.getSeconds());
}

function sinceText(ts) {
	if (!ts)
		return '-';

	var s = Math.max(0, Math.floor(Date.now() / 1000) - ts);

	if (s < 60)
		return _('%d 秒前').format(s);
	if (s < 3600)
		return _('%d 分钟前').format(Math.floor(s / 60));
	if (s < 86400)
		return _('%d 小时前').format(Math.floor(s / 3600));

	return _('%d 天前').format(Math.floor(s / 86400));
}

// 键值表的结构与 pb.kv 完全一致（class 决定样式，见 common.js 的 CSS），
// 这里保留 row/table 两个函数只是因为调用点太多，不值得为改名动它们。
function row(label, value) {
	return E('tr', { 'class': 'tr' }, [
		E('td', { 'class': 'td pb-k' }, label),
		E('td', { 'class': 'td pb-v' }, value)
	]);
}

function table(rows) {
	return E('table', { 'class': 'table pb-kv' }, [
		E('tbody', {}, rows)
	]);
}

function card(title, body) {
	// 两个坑（都实测踩过）：
	//   1. 部分主题（例如 QWRT）把 fieldset 的 legend 设成 display:none，
	//      用它当标题会整块「看不见」，所以标题用 h3，不依赖主题。
	//   2. LuCI 的 E() 不递归嵌套数组，pb.card 内部已手工拍平。
	return pb.card(title, body);
}

return view.extend({
	load: function() {
		// 只等 status（实测 0.65s）。自检要 1~3s，而且是纯诊断信息，
		// 不该挡首屏 —— 早先这里 Promise.all 把两者一起等，页面打开硬生生 4 秒多。
		// 现在渲染完再异步跑自检，自检卡自己填内容。
		return callStatus();
	},

	/* ------------------------------------------------------------ 渲染 */
	render: function(st) {
		st = st || {};
		var cfg = st.config || {};
		var rt = st.runtime || {};
		var ctr = st.counters || {};
		var nb = st.neigh || {};
		var cron = st.cron || {};
		var last = (st.state && st.state.last_run) || {};

		this.refs = {};

		if (st.ok === false) {
			return E('div', { 'class': 'cbi-map pbrlite' }, [
				E('h2', {}, _('PBR Lite')),
				E('div', { 'class': 'alert-message error' }, [
					E('p', {}, _('无法读取状态：%s').format(st.error || _('未知错误')))
				])
			]);
		}

		this.refs.banner = E('div', { 'id': 'pl-banner' });

		/* ---- 运行状态 ---- */
		var updateCell = E('span');
		this.refs.updateCell = updateCell;

		var stateCard = card(_('运行状态'), table([
			row(_('分流开关'), [
				E('span', { 'id': 'pl-enabled' },
					cfg.enabled == 1 ? badge(_('已启用'), 'ok') : badge(_('已停用'), 'idle')),
				E('span', { 'class': 'pb-muted', 'style': 'margin-left:8px' },
					_('兜底：%s').format(cfg.guard == 1 ? _('开') : _('关')))
			]),
			row(_('上次更新结果'), updateCell),
			row(_('非中国地址条目'), [
				E('strong', { 'id': 'pl-file' }, fmtNum(rt.file_entries)),
				E('span', { 'class': 'pb-muted' }, _(' 条，生成的 include 不会每天变'))
			]),
			row(_('规则源'), E('code', { 'style': 'word-break:break-all' }, cfg.src_url || '-')),
			row(_('走代理的源地址'), E('code', { 'style': 'word-break:break-all' },
				(cfg.src_addrs || '-').split(' ').join(', '))),
			row(_('旁路由'), [
				E('code', {}, cfg.next_hop || '-'),
				E('span', { 'class': 'pb-muted' }, ' / ' + (cfg.dae_mac || '-')),
				E('span', { 'class': 'pb-muted' }, ' via ' + (cfg.lan_dev || '-'))
			]),
			row(_('定时更新'), cron.installed == 1
				? E('code', {}, cron.line)
				: badge(_('未安装'), 'warn')),
			row(_('开机自启'), cron.service_enabled == 1
				? badge(_('已启用'), 'ok')
				: badge(_('未启用'), 'warn'))
		]));

		this.refs.updateCell = updateCell;
		this._applyLastRun(updateCell, last);

		/* ---- 数据一致性 ---- */
		this.refs.consistent = E('span');
		this.refs.kernel = E('span');
		this.refs.consistIcon = E('span');

		var consistCard = card(_('数据一致性'), table([
			row(_('文件 vs 内核'), [
				this.refs.consistIcon,
				E('span', { 'style': 'margin-left:8px' },
					_('生成文件 ')),
				E('strong', { 'id': 'pl-fe' }, fmtNum(rt.file_entries)),
				E('span', {}, _(' 条 / 内核 ')),
				E('strong', { 'id': 'pl-kc' }, fmtNum(rt.kernel_entries)),
				E('span', {}, _(' 条'))
			]),
			row(_('include 文件'), [
				E('code', {}, (rt.include_exists == 1) ? _('存在') : _('不存在')),
				E('span', { 'class': 'pb-muted' }, ' / %s / %s'.format(
					fmtBytes(rt.include_bytes), _('%d 行').format(rt.include_lines || 0)))
			]),
			row(_('nft 集合'), [
				E('code', {}, cfg.set_dst || '-'),
				E('span', { 'class': 'pb-muted' },
					rt.set_loaded == 1 ? _(' 已装载') : _(' 未装载'))
			]),
			row(_('规则引用'), [
				E('span', { 'id': 'pl-rules' }, fmtNum(rt.rules)),
				E('span', { 'class': 'pb-muted' },
					_(' 条（期望 ≥ 2：一条打标、一条循环兜底）')),
				rt.rules >= 2 ? badge(_('正常'), 'ok') : badge(_('异常'), 'err')
			])
		]));

		/* ---- 计数与旁路由健康 ---- */
		this.refs.markPk = E('span');
		this.refs.guardPk = E('span');
		this.refs.guardHint = E('span');

		var counterCard = card(_('计数与旁路由健康'), table([
			row(_('打标命中'), [
				E('strong', { 'id': 'pl-mpk' }, fmtNum(ctr.mark_packets)),
				E('span', { 'class': 'pb-muted' }, ' ' + _('包 / %s').format(fmtBytes(ctr.mark_bytes)))
			]),
			row(_('循环兜底丢弃'), [
				E('strong', { 'id': 'pl-gpk' }, fmtNum(ctr.guard_packets)),
				E('span', { 'class': 'pb-muted' }, ' ' + _('包')),
				this.refs.guardHint
			]),
			row(_('旁路由邻居'), [
				E('code', {}, nb.mac || _('无 ARP 表项')),
				E('span', { 'class': 'pb-muted' }, ' ' + (nb.state || '')),
				' ',
				nb.match == 1 ? badge(_('与配置一致'), 'ok') : badge(_('与配置不一致'), 'warn')
			]),
			row(_('路由层'), [
				E('span', { 'class': 'pb-muted' }, _('ip rule ')),
				E('code', { 'style': 'word-break:break-all' },
					(rt.rule_ok == 1) ? (st.route && st.route.rule) || '-' : _('缺失（pref %s）').format(cfg.pref)),
				E('br'),
				E('span', { 'class': 'pb-muted' }, _('表 %s：').format(cfg.table_id)),
				E('code', { 'style': 'word-break:break-all' }, (st.route && st.route['default']) || '-')
			])
		]));

		/* ---- 自检 ---- */
		// 先放占位，页面立刻可见；真正的自检在 return 之前挂一个异步调用
		this.refs.verifyBox = E('div', {}, E('em', {},
			_('正在自检…（只读检查，不影响分流）')));

		var verifyCard = card(_('自检'), [
			E('div', { 'class': 'pb-actions', 'style': 'margin-bottom:10px' }, [
				E('button', {
					'type': 'button',
					'class': 'btn cbi-button cbi-button-action',
					'click': L.bind(this.handleVerify, this)
				}, _('重新自检')),
				E('span', { 'class': 'pb-muted', 'style': 'font-size:12px' },
					_('共 9 组检查项；FAIL 会置顶显示'))
			]),
			this.refs.verifyBox
		]);

		/* ---- 底部说明 ---- */
		var footer = E('div', { 'class': 'cbi-section' }, [
			E('p', { 'class': 'pb-muted', 'style': 'font-size:12px' }, [
				_('本页只读。分流逻辑全部在 '),
				E('code', {}, '/usr/share/pbr-lite/'),
				_(' 下的脚本里，脱离 LuCI 也能独立工作；界面只是它的一个视图。')
			])
		]);

		this.applyStatus(st);

		/* 5 秒轮询：只改数字，不重绘整页，避免输入焦点丢失 */
		poll.add(L.bind(function() {
			return callStatus().then(L.bind(this.applyStatus, this))
				.catch(function() { /* fw4 reload 期间可能短暂失败，容忍一次 */ });
		}, this), 15);

		/* 自检异步跑：不 await，页面先出来，结果到了再填卡片。
		   放在 setTimeout 里是为了让首次 paint 先发生（否则这里同步发起 RPC，
		   虽然也不阻塞渲染，但会和页面初始化的其它请求抢一个连接）。 */
		setTimeout(L.bind(function() {
			this.handleVerify(null).catch(function() { /* handleVerify 自己会渲染错误 */ });
		}, this), 0);

		return E('div', { 'class': 'cbi-map pbrlite' }, [
			E('h2', {}, _('PBR Lite 策略路由')),
			E('div', { 'class': 'cbi-map-descr' },
				_('命中的源地址访问非中国 IP 时打标送旁路由，其余流量直连。')),
			this.refs.banner,
			stateCard,
			consistCard,
			counterCard,
			verifyCard,
			footer
		]);
	},

	/* ------------------------------------------------------------ 局部刷新 */
	_applyLastRun: function(node, last) {
		node.textContent = '';

		if (!last || !last.ts) {
			node.appendChild(badge(_('从未运行'), 'idle'));
			return;
		}

		var kind = (last.result == 'ok' || last.result == 'nochange') ? 'ok' :
		           (last.result == 'rolled_back') ? 'warn' : 'err';

		node.appendChild(badge(pb.resultText(last.result), kind));
		node.appendChild(E('span', { 'class': 'pb-muted', 'style': 'margin-left:8px' },
			'%s（%s，耗时 %ss）'.format(fmtTime(last.ts), sinceText(last.ts), last.duration_s || 0)));

		// 后端已经用 message 说明了本次做了什么（例如「内容无变化」），
		// 这里别再补一句同样的话 —— 之前两处并列，看着像重复渲染。
		if (last.message)
			node.appendChild(E('div', { 'class': 'pb-muted', 'style': 'font-size:12px' }, last.message));
	},

	applyStatus: function(st) {
		if (!st || st.ok === false)
			return;

		var cfg = st.config || {};
		var rt = st.runtime || {};
		var ctr = st.counters || {};

		/* 顶部横幅 */
		var b = this.refs.banner;
		if (b) {
			b.textContent = '';

			var kind, msg;

			if (cfg.enabled != 1) {
				kind = 'idle'; msg = _('分流已停用：规则没有下发，所有流量直连。');
			}
			else if (rt.include_exists != 1) {
				kind = 'err'; msg = _('生成的 include 不存在：还没跑过更新，当前没有任何分流规则。');
			}
			else if (rt.consistent != 1) {
				kind = 'err'; msg = _('文件与内核不一致：内核 %s 条，文件 %s 条。规则可能没装载成功，点下方「重新自检」定位。')
					.format(fmtNum(rt.kernel_entries), fmtNum(rt.file_entries));
			}
			else if (rt.rules < 2) {
				kind = 'warn'; msg = _('打标规则不完整（只有 %s 条引用集合）：循环兜底可能丢失。').format(rt.rules);
			}
			else {
				kind = 'ok'; msg = _('运行中：%s 条非中国地址正在生效，命中后送 %s。')
					.format(fmtNum(rt.kernel_entries), cfg.next_hop || '');
			}

			b.appendChild(pb.banner(kind, msg));
		}

		var setText = function(ref, txt) {
			if (ref)
				ref.textContent = txt;
		};

		setText(this.refs.kernel, fmtNum(rt.kernel_entries));
		setText(this.refs.markPk, fmtNum(ctr.mark_packets));
		setText(this.refs.guardPk, fmtNum(ctr.guard_packets));

		var fe = document.getElementById('pl-fe');
		var kc = document.getElementById('pl-kc');
		var mp = document.getElementById('pl-mpk');
		var gp = document.getElementById('pl-gpk');
		var rl = document.getElementById('pl-rules');

		if (fe) fe.textContent = fmtNum(rt.file_entries);
		if (kc) kc.textContent = fmtNum(rt.kernel_entries);
		if (mp) mp.textContent = fmtNum(ctr.mark_packets);
		if (gp) gp.textContent = fmtNum(ctr.guard_packets);
		if (rl) rl.textContent = fmtNum(rt.rules);

		if (this.refs.consistIcon) {
			this.refs.consistIcon.textContent = '';
			this.refs.consistIcon.appendChild(
				rt.consistent == 1 ? badge(_('一致'), 'ok') : badge(_('不一致'), 'err'));
		}

		if (this.refs.guardHint) {
			this.refs.guardHint.textContent = '';

			if (+ctr.guard_packets > 0)
				this.refs.guardHint.appendChild(E('span', { 'class': 'pb-muted', 'style': 'margin-left:8px' },
					_('（非零说明旁路由把包原样转回来了）')));
		}
	},

	/* ------------------------------------------------------------ 自检结果 */
	renderVerify: function(vf) {
		var s = vf.summary || {};
		var items = vf.items || [];
		var groups = {};
		var order = [];

		for (var i = 0; i < items.length; i++) {
			var g = items[i].group || _('其他');

			if (!groups[g]) {
				groups[g] = [];
				order.push(g);
			}

			groups[g].push(items[i]);
		}

		var head = E('div', { 'class': 'pb-actions', 'style': 'margin-bottom:10px' }, [
			badge(_('通过 %d').format(s.pass || 0), 'ok'),
			(s.warn > 0) ? badge(_('警告 %d').format(s.warn), 'warn') : '',
			(s.fail > 0) ? badge(_('失败 %d').format(s.fail), 'err') : badge(_('失败 0'), 'ok')
		]);

		if (s.ok === true)
			head.appendChild(E('span', { 'style': 'margin-left:10px', 'class': 'pb-ok' },
				_('全部通过')));

		var problems = items.filter(function(it) {
			return it.status == 'fail' || it.status == 'warn';
		});

		var box = E('div', {}, [ head ]);

		if (problems.length) {
			var list = E('ul', { 'style': 'margin:0;padding-left:20px' });

			for (var j = 0; j < problems.length && j < 30; j++) {
				list.appendChild(E('li', {
					'class': problems[j].status == 'fail' ? 'pb-err' : 'pb-warn'
				}, '[%s] %s'.format(problems[j].group || '', problems[j].msg)));
			}

			box.appendChild(E('div', { 'class': 'pb-warnbox' }, [
				E('strong', {}, _('需要关注')), list
			]));
		}

		for (var k = 0; k < order.length; k++) {
			var name = order[k];
			var list2 = groups[name];
			var okCount = list2.filter(function(x) { return x.status == 'pass'; }).length;

			var det = E('details', {}, [
				E('summary', {},
					'%s（%d/%d）'.format(name, okCount, list2.length)),
				E('ul', {},
					list2.map(function(x) {
						return E('li', {
							'class': x.status == 'pass' ? 'pb-ok' :
							         (x.status == 'warn' ? 'pb-warn' : 'pb-err')
						}, x.msg);
					}))
			]);

			box.appendChild(det);
		}

		return box;
	},

	handleVerify: function(ev) {
		var box = this.refs.verifyBox;

		// 按钮的 disabled / spinning 由 createHandlerFn 负责：它在调用本函数**之前**
		// 就已经把按钮置灰了，返回后才恢复。这里再写 `if (btn.disabled) return`
		// 会让点击永远提前返回（点了没反应，也不报错）。
		box.textContent = '';
		box.appendChild(E('em', {}, _('正在自检…（约 1~2 秒）')));

		var fail = L.bind(function(err) {
			box.textContent = '';
			box.appendChild(E('div', { 'class': 'alert-message error' }, [
				E('p', {}, _('自检调用失败：%s').format(err && err.message ? err.message : err))
			]));
		}, this);

		return callVerify().then(L.bind(function(vf) {
			var node;

			try {
				node = this.renderVerify(vf || {});
			}
			catch (e) {
				fail(e);
				return;
			}

			box.textContent = '';
			box.appendChild(node);
		}, this)).catch(fail);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
