'use strict';
'require view';
'require rpc';
'require ui';
'require pbr-lite.common as pb';

// /luci-static/resources/view/pbr-lite/diagnostics.js
//
// 诊断页：出问题时不 SSH 也能定位。
//
// 三条原则：
//   1. 只读。这里没有任何写操作，随时点随时安全。
//   2. 不灌数据。include 只给头部若干行看结构，集合内容走单点查询。
//   3. 结论要能贴出去。「下载诊断包」生成的是纯文本，直接贴 issue 就行。

var callDiag   = rpc.declare({ object: 'pbr-lite', method: 'diag' });
var callLookup = rpc.declare({ object: 'pbr-lite', method: 'lookup_ip', params: [ 'ip' ] });
var callBundle = rpc.declare({ object: 'pbr-lite', method: 'diag_bundle' });

var VERDICT = {
	proxy:            { text: '走旁路由', color: '#2563eb' },
	direct_whitelist: { text: '直连（直连白名单）', color: '#16a34a' },
	direct_reserved:  { text: '直连（内网/保留段）', color: '#16a34a' },
	cn_unknown:       { text: '直连（推定 CN）', color: '#16a34a' }
};

return view.extend({
	load: function() {
		return callDiag();
	},

	render: function(d) {
		d = d || {};

		this.refs = {};

		var warn = null;

		if (d.ok === false)
			warn = E('div', { 'class': 'alert-message error' }, [
				E('p', {}, _('读不到诊断信息：%s').format(d.error || _('未知错误')))
			]);

		return E('div', { 'class': 'cbi-map pbrlite', 'style': 'padding-bottom:5em' }, [
			E('h2', {}, _('诊断')),
			E('div', { 'class': 'cbi-map-descr' },
				_('这一页只读：所有内容都是现场读出来的，不会改配置、不会 reload。')),
			warn || '',
			this.cardLookup(),
			this.cardInclude(d),
			this.cardRules(d),
			this.cardLog(d),
			this.cardBundle(d)
		]);
	},

	/* ---------------------------------------------------------- IP 归属查询 */
	cardLookup: function() {
		var self = this;

		var input = E('input', {
			'type': 'text',
			'class': 'cbi-input-text',
			'style': 'width:14em;font-family:var(--font-mono,monospace)',
			'placeholder': '8.8.8.8',
			'spellcheck': 'false',
			'keydown': function(ev) {
				if (ev.key === 'Enter') {
					ev.preventDefault();
					self.handleLookup();
				}
			}
		});

		var btn = E('button', {
			'type': 'button',
			'class': 'btn cbi-button cbi-button-action',
			'click': ui.createHandlerFn(this, 'handleLookup')
		}, _('查询'));

		this.refs.ipInput = input;
		this.refs.lookupBox = E('div', { 'style': 'margin-top:.7em' },
			E('div', { 'style': 'color:var(--pb-muted);font-size:92%' },
				_('输入一个公网地址，看它会走代理还是直连、命中哪条 CIDR、最终落到哪条路由。')));

		return pb.card(_('单个地址归属'), [
			E('p', { 'style': 'margin:0 0 .5em;font-size:92%;color:var(--pb-muted)' },
				_('判定顺序与数据面一致：直连白名单 → 内网保留段 → 非 CN 集合 → 其余按 CN 直连。')),
			E('div', { 'class': 'pb-actions' }, [ input, btn ]),
			this.refs.lookupBox
		]);
	},

	handleLookup: function() {
		var self = this;
		var box = this.refs.lookupBox;
		var ip = (this.refs.ipInput.value || '').trim();

		if (!/^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$/.test(ip)) {
			box.textContent = '';
			box.appendChild(E('div', { 'class': 'pb-err' }, _('请填一个 IPv4 地址')));
			return;
		}

		box.textContent = '';
		box.appendChild(E('em', {}, _('查询中…')));

		return callLookup(ip).then(function(r) {
			box.textContent = '';

			if (!r || r.ok === false) {
				box.appendChild(E('div', { 'class': 'pb-err' },
					_('查询失败：%s').format((r && r.error) || _('未知错误'))));
				return;
			}

			var v = VERDICT[r.verdict] || { text: r.verdict || '?', color: '#6b7280' };
			var rows = [];

			rows.push([ _('结论'), pb.tag(v.text, v.color) ]);
			rows.push([ _('说明'), r.reason || '-' ]);

			if (r.cidr)
				rows.push([ _('命中 CIDR'), E('code', {}, r.cidr) ]);

			rows.push([ _('实际去向'), r.route
				? E('code', { 'style': 'word-break:break-all' }, r.route)
				: E('span', { 'class': 'pb-warn' }, _('取不到（ip rule 或路由表可能没装）')) ]);

			box.appendChild(pb.kv(rows));
			return;
		}).catch(function(e) {
			box.textContent = '';
			box.appendChild(E('div', { 'class': 'pb-err' },
				_('查询失败：%s').format(e && e.message ? e.message : e)));
		});
	},

	/* ---------------------------------------------------------- include 预览 */
	cardInclude: function(d) {
		var inc = d.include || {};
		var cb = pb.codeBlock(inc.head || _('（include 还没生成）'), '20em');

		return pb.card(_('生成的 include'), [
			E('p', { 'style': 'margin:0 0 .5em;font-size:92%;color:var(--pb-muted)' },
				_('这里只看头部结构（add set 声明与开头几条元素）。全文件 %s 行 / %s，' +
				  '整表内容不会送到浏览器 —— 需要查单个地址请用上面的归属查询。').format(
					(inc.lines || 0).toLocaleString(), pb.fmtBytes(inc.bytes || 0))),
			E('p', { 'style': 'margin:0 0 .5em;font-size:92%' }, [
				E('code', { 'style': 'word-break:break-all' }, inc.path || '-'),
				inc.exists ? '' : E('span', { 'class': 'pb-err' }, _('  ⚠ 文件不存在'))
			]),
			cb.node
		]);
	},

	/* ---------------------------------------------------------- 规则原文 */
	cardRules: function(d) {
		var cb = pb.codeBlock(d.rules || _('（内核里没有引用集合的规则）'), '12em');

		return pb.card(_('内核规则原文'), [
			E('p', { 'style': 'margin:0 0 .5em;font-size:92%;color:var(--pb-muted)' },
				_('mangle_prerouting 里引用目标集合的规则。第一行是循环兜底 drop，第二行是打标。' +
				  '看计数器就知道命中情况：counters 不动就是没流量走过这条规则。')),
			cb.node
		]);
	},

	/* ---------------------------------------------------------- 日志 */
	cardLog: function(d) {
		var cb = pb.codeBlock(d.logread || _('（最近没有相关日志）'), '20em');

		return pb.card(_('系统日志'), [
			E('p', { 'style': 'margin:0 0 .5em;font-size:92%;color:var(--pb-muted)' },
				_('最近 60 条含 pbr-lite / fw4 / nft 的日志。要更全的在 SSH 里用 logread。')),
			cb.node
		]);
	},

	/* ---------------------------------------------------------- 诊断包 */
	cardBundle: function(d) {
		var self = this;

		this.refs.bundleMsg = E('span', { 'style': 'font-size:92%;color:var(--pb-muted)' });

		return pb.card(_('诊断包'), [
			E('p', { 'style': 'margin:0 0 .5em;font-size:92%;color:var(--pb-muted)' },
				_('把环境、UCI 配置、导出变量、include 头部、规则原文、路由表、自检结果和日志' +
				  '打成一个纯文本文件下载下来。不含那 1.1 万条 CIDR，可以直接贴出来。')),
			E('div', { 'class': 'pb-actions' }, [
				E('button', {
					'type': 'button',
					'class': 'btn cbi-button cbi-button-action',
					'click': ui.createHandlerFn(this, 'handleBundle')
				}, _('下载诊断包')),
				this.refs.bundleMsg
			])
		]);
	},

	handleBundle: function() {
		var msg = this.refs.bundleMsg;

		// 不要自己管按钮的 disabled / spinning：用 createHandlerFn 绑的按钮，
		// 框架在你进入这里**之前**就已经 disabled=true 并加了 spinning，
		// 处理完才在 finally 里恢复。所以这里写 `if (btn.disabled) return`
		// 会变成「永远提前返回」—— 点下去毫无反应、也没有任何报错。
		msg.textContent = _('正在收集…');

		return callBundle().then(function(r) {
			if (!r || r.ok !== true) {
				msg.textContent = _('失败：%s').format((r && r.error) || _('未知错误'));
				return;
			}

			var blob = new Blob([ r.text ], { type: 'text/plain;charset=utf-8' });
			var url = URL.createObjectURL(blob);
			var a = E('a', { 'href': url, 'download': r.name });
			document.body.appendChild(a);
			a.click();
			document.body.removeChild(a);
			setTimeout(function() { URL.revokeObjectURL(url); }, 10000);

			msg.textContent = _('已下载 %s（%s）').format(r.name, pb.fmtBytes(r.bytes || 0));
		}).catch(function(e) {
			msg.textContent = _('失败：%s').format(e && e.message ? e.message : e);
		});
	},

	// 本页没有可保存的东西，但 LuCI 会按「有没有这几个处理函数」决定要不要在
	// 底栏画「保存 / 复位」。不显式写成 null 的话两者都会出现，点了没任何反应
	//（诊断页实测有这两个僵尸按钮）。
	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
