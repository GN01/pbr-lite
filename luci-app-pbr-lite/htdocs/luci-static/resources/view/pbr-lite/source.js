'use strict';
'require view';
'require form';
'require ui';
'require rpc';
'require pbr-lite.common as pb';

// /luci-static/resources/view/pbr-lite/source.js
//
// 规则源页：列表从哪来、什么时候更新、更新出问题时怎么退回去。
//
// 三个「立即操作」按钮都不是同步请求：它们只起一个后台 job，
// 页面靠轮询 job_status 显示进度（一次更新 8~12 秒，同步等会撞超时）。

var callStatus   = rpc.declare({ object: 'pbr-lite', method: 'status' });
var callUpdate   = rpc.declare({ object: 'pbr-lite', method: 'update', params: [ 'no_fetch' ] });
var callRollback = rpc.declare({ object: 'pbr-lite', method: 'rollback', params: [ 'slot' ] });

return view.extend({
	load: function() {
		return callStatus();
	},

	render: function(st) {
		var self = this;

		this.status = st || {};
		this.panel = pb.jobPanel();

		var m = new form.Map('pbr-lite', _('规则源'),
			_('分流用的是「中国 IPv4 列表的补集」。列表每天定时拉一次，') +
			_('拉完会做条目下限、漂移、正反抽查三道校验，任何一道不过就保留旧数据。'));
		this.map = m;

		var s, o;

		s = m.section(form.NamedSection, 'source', 'source', _('列表来源'));
		s.description = _('默认源 https://ispip.clang.cn/all_cn.txt 每天更新，格式是一行一条 CIDR。') +
			_('换源要求格式一致（一行一条 a.b.c.d/nn），否则会被「非法行过多」挡下来。');

		o = s.option(form.Value, 'url', _('列表地址'));
		o.default = 'https://ispip.clang.cn/all_cn.txt';
		o.rmempty = false;
		o.placeholder = 'https://ispip.clang.cn/all_cn.txt';
		o.validate = function(section_id, value) {
			return /^https?:\/\/[^\s"'`<>]+$/.test(value) ? true : '必须是 http(s):// 开头的地址';
		};

		o = s.option(form.Value, 'min_entries', _('补集条目下限'));
		o.default = '5000';
		o.rmempty = false;
		o.datatype = 'range(100,1000000)';
		o.description = _('算出来的补集少于这个条数就判失败（防止上游给了半截数据还照装）。');

		o = s.option(form.Value, 'max_drift', _('漂移阈值（%）'));
		o.default = '40';
		o.rmempty = false;
		o.datatype = 'range(1,100)';
		o.description = _('与上一次相比条目数变化超过这个百分比就停下等人工确认') +
			_('（确认无误可以用命令行 --force 跳过）。');

		this.statusBody = E('div', {});
		var statusCard = pb.card(_('当前状态'), this.statusBody);

		this.backupBody = E('div', {});
		var backupCard = pb.card(_('备份与回滚'), this.backupBody);

		var btnUpdate = E('button', {
			'class': 'btn cbi-button cbi-button-apply',
			'click': ui.createHandlerFn(this, function() { return self.runJob('update'); })
		}, _('立即更新（下载列表）'));

		var btnRebuild = E('button', {
			'class': 'btn cbi-button',
			'style': 'margin-left:.5em',
			'click': ui.createHandlerFn(this, function() { return self.runJob('rebuild'); })
		}, _('只重建规则（不下载）'));

		var actionCard = pb.card(_('立即操作'), [
			E('p', { 'style': 'margin:0 0 .6em;font-size:92%;color:var(--text-color-medium,#666)' },
				_('「只重建」用上一次缓存的 CN 列表重新算补集，适合改过白名单或想强制刷新规则时用，') +
				_('不依赖上游能不能连上。')),
			E('div', {}, [ btnUpdate, btnRebuild ])
		]);

		return m.render().then(function(node) {
			// 底部留白：主题的 cbi-page-actions 是固定条，页面到底时会把保存按钮压在下面
			var wrap = E('div', { 'class': 'pbrlite', 'style': 'padding-bottom:5em' },
				[ statusCard, node, actionCard, backupCard, self.panel.node ]);

			self.renderStatus();
			self.renderBackups();

			if (self.status.job && (self.status.job.state || self.status.job.active))
				self.panel.render(self.status.job);

			return wrap;
		});
	},

	// ---------------------------------------------------------------- 状态卡
	renderStatus: function() {
		var self = this;
		var st = this.status || {};
		var rt = st.runtime || {};
		var cfg = st.config || {};
		var last = (st.state && st.state.last_run) ? st.state.last_run : null;
		var body = this.statusBody;

		var rows = [];

		rows.push([ _('地址集合条目'),
			_('%s 条（文件 %s / 内核 %s）%s').format(
				(rt.file_entries || 0).toLocaleString(), (rt.file_entries || 0).toLocaleString(),
				(rt.kernel_entries || 0).toLocaleString(),
				rt.consistent == 1 ? '' : _('  ⚠ 不一致')) ]);

		rows.push([ _('include 文件'),
			rt.include_exists
				? _('%s / %s 行').format(pb.fmtBytes(rt.include_bytes), rt.include_lines)
				: _('不存在（还没生成过）') ]);

		rows.push([ _('直连白名单'), _('%s 条').format(cfg.direct_entries || 0) ]);

		rows.push([ _('定时更新'),
			st.cron && st.cron.installed
				? E('code', {}, st.cron.line)
				: E('span', { 'style': 'color:#d97706' }, _('未安装（列表不会自动更新）')) ]);

		rows.push([ _('最近一次更新'),
			last
				? _('%s（%s，%ss）').format(pb.fmtTime(last.ts), pb.resultText(last.result), last.duration_s || 0)
				: _('还没有记录') ]);

		if (st.state && st.state.dst_entries != null)
			rows.push([ _('state 记录'), _('%s 条').format((st.state.dst_entries || 0).toLocaleString()) ]);

		body.textContent = '';

		if (!st || st.ok === false) {
			body.appendChild(E('div', { 'style': 'color:#dc2626' },
				_('读不到状态：%s').format((st && st.error) || _('status.sh 没有返回'))));
			return;
		}

		// 刷新按钮浮在卡片标题行右端（.pb-card-tool 是绝对定位）：
		// 它作用于整张表，放表格下方会让人以为只作用于最后一行；
		// 放标题和表格之间则会撑出一条空白。
		body.appendChild(E('button', {
			'class': 'btn cbi-button pb-ghost pb-card-tool',
			'click': ui.createHandlerFn(this, function() { return self.refresh(); })
		}, _('刷新')));

		body.appendChild(pb.kv(rows));
	},

	// ---------------------------------------------------------------- 备份卡
	renderBackups: function() {
		var self = this;
		var list = (this.status && this.status.backups) ? this.status.backups : [];
		var body = this.backupBody;

		body.textContent = '';

		if (!list.length) {
			body.appendChild(E('div', { 'style': 'color:var(--text-color-medium,#666)' },
				_('还没有备份。每次成功重建规则时会把上一版 include 存下来，最多留 5 份。')));
			return;
		}

		body.appendChild(E('p', { 'style': 'margin:0 0 .5em;font-size:92%;color:var(--text-color-medium,#666)' },
			_('回滚只换 include 文件并 reload fw4，不动配置。第 1 份是最新的。')));

		var tb = E('table', { 'class': 'table' });

		tb.appendChild(E('tr', { 'class': 'tr table-titles' }, [
			E('th', { 'class': 'th' }, _('序号')),
			E('th', { 'class': 'th' }, _('时间')),
			E('th', { 'class': 'th' }, _('大小')),
			E('th', { 'class': 'th' }, '')
		]));

		list.forEach(function(b, i) {
			tb.appendChild(E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td' }, i == 0 ? _('1（最新）') : String(i + 1)),
				E('td', { 'class': 'td' }, pb.fmtTime(b.mtime)),
				E('td', { 'class': 'td' }, pb.fmtBytes(b.bytes)),
				E('td', { 'class': 'td' }, E('button', {
					'class': 'btn cbi-button cbi-button-negative',
					'click': ui.createHandlerFn(self, function() {
						return self.runJob('rollback', i + 1);
					})
				}, _('回滚到这一版')))
			]));
		});

		body.appendChild(tb);
	},

	// ---------------------------------------------------------------- 起任务
	runJob: function(kind, slot) {
		var self = this;

		var call = (kind == 'rebuild') ? callUpdate(1)
			: (kind == 'update') ? callUpdate(0)
			: callRollback(slot || 1);

		return call.then(function(res) {
			if (!res || res.ok !== true) {
				pb.showError(_('启动失败'), (res && res.error) || _('未知错误'));
				return;
			}

			self.panel.render(res.job || {});

			return pb.watchJob(function(job) {
				self.panel.render(job);
			}, function(job) {
				if (job.active)
					return;

				// 任务结束（成功或失败）都要重新读一次真实状态：
				// 失败时 include 可能已经被 update 自己回滚了
				return self.refresh();
			});
		});
	},

	refresh: function() {
		var self = this;

		return callStatus().then(function(st) {
			self.status = st || {};
			self.renderStatus();
			self.renderBackups();
		});
	},

	// 配置项（地址/下限/阈值）走和设置页一样的「算半径 → 提交 → 轮询」流程
	handleSave: function() {
		return this.saveSource();
	},

	handleSaveApply: function() {
		return this.saveSource();
	},

	saveSource: function() {
		var self = this;
		var m = this.map;

		return pb.callExport().then(function(e) {
			var live = pb.parseExport((e && e.ok) ? e.text : '');

			return m.parse().then(function() {
				var values = {};

				pb.FIELDS.forEach(function(f) {
					if (f.sect != 'source')
						return;

					var v = m.data.get('pbr-lite', f.sect, f.opt);

					if (Array.isArray(v))
						values[f.key] = v.filter(function(x) { return x != ''; });
					else
						values[f.key] = (v == null) ? '' : String(v);
				});

				return pb.applyFlow({
					values: values,
					live: live,
					panel: self.panel,
					onDone: function(job) {
						if (job.state == 'done' || job.state == 'warn')
							return self.refresh();
					}
				});
			});
		});
	}
});
