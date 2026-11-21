'use strict';
'require view';
'require form';
'require ui';
'require rpc';
'require pbr-lite.common as pb';

// /luci-static/resources/view/pbr-lite/settings.js
//
// 分流设置页（常规项）。流程骨架在 pbr-lite.common 的 settingsPage() 里，
// 这里只描述「本页有哪几个分节」。
//
// 与普通 LuCI 页面最大的不同：**不调用 map.save()**。
// map.save() 会自己把值写进 uci 并 commit，之后我们才知道改了什么，等于「先斩后奏」。
// 这里的顺序是「先算清楚再落盘」：
//   1. map.parse()  仅把 DOM 值收进本地对象（uci.js 的 set 只改内存，不发 RPC）
//   2. 前端算出生效半径，把「这次要等 10 秒还是 1 秒」提前告诉用户
//   3. 整体交给 apply_config：服务端校验 → 快照 → 写 uci → 起 job
//   4. 轮询 job：前端显示进度，失败时服务端已经自动回滚

var callDetect = rpc.declare({ object: 'pbr-lite', method: 'detect_peer', params: [ 'ip' ] });

function ipOrCidr(v) {
	var parts = String(v).split('/');

	if (parts.length > 2 || !/^[0-9]{1,3}(\.[0-9]{1,3}){3}$/.test(parts[0]))
		return false;

	var ok = true;

	parts[0].split('.').forEach(function(x) {
		if (+x > 255)
			ok = false;
	});

	if (!ok)
		return false;

	if (parts.length == 1)
		return true;

	return /^[0-9]{1,2}$/.test(parts[1]) && +parts[1] <= 32;
}

// 本页负责的分节。打标值 / 路由层 / nft 对象搬到「高级设置」页了。
var OWN = [ 'main', 'guard', 'lan', 'direct', 'dae' ];

return view.extend(pb.settingsPage({
	title: _('分流设置'),
	descr: _('改完点底部的「保存」。需要重建规则时会花 10 秒左右，期间页面会显示进度；') +
	       _('失败会自动回滚到改动前的配置。'),

	own: OWN,

	build: function(m, page) {
		var s, o;

		// ---------------- 总开关
		s = m.section(form.NamedSection, 'main', 'pbrlite', _('总开关'));
		s.description = _('关掉后 nft 里不再有引用地址集合的规则，所有流量按默认路由直连。') +
			_('规则文件不会删，重新打开立刻生效（不用重新下载列表）。');

		o = s.option(form.Flag, 'enabled', _('启用分流'));
		o.default = '1';
		o.rmempty = false;

		s = m.section(form.NamedSection, 'guard', 'guard', _('循环兜底'));
		s.description = _('旁路由把包原样转回来时（策略不命中又被送回网关），') +
			_('这条规则会丢弃它，避免两边来回弹到 TTL 耗尽。看到「兜底」计数持续增长，') +
			_('通常说明旁路由那边的分流规则和这里对不上。');

		o = s.option(form.Flag, 'enabled', _('启用循环兜底'));
		o.default = '1';
		o.rmempty = false;

		// ---------------- 生效范围
		s = m.section(form.NamedSection, 'lan', 'lan', _('生效地址'));
		s.description = _('只有源地址在下面列表里的设备才会被分流，其他设备一律直连。') +
			_('填单个 IP。删空表示「谁都不分流」。');

		o = s.option(form.DynamicList, 'src_addr', _('源地址'));
		o.placeholder = '192.168.0.2';
		o.rmempty = true;
		o.validate = function(section_id, value) {
			if (!value)
				return true;

			return /^[0-9]{1,3}(\.[0-9]{1,3}){3}$/.test(value) && ipOrCidr(value)
				? true : _('请填单个 IPv4 地址（不带掩码）');
		};

		// ---------------- 直连白名单
		s = m.section(form.NamedSection, 'direct', 'direct', _('直连白名单'));
		s.description = _('这里的地址/网段即使不在中国列表里，也不会走旁路由（保持直连）。') +
			_('典型用途：走旁路由会坏的国内 CDN、需要真实 IP 的内网服务。') +
			_('改这里只需要重建规则，不用重新下载列表。');

		o = s.option(form.DynamicList, 'dst', _('直连地址 / 网段'));
		o.placeholder = _('1.2.3.4 或 10.0.0.0/8');
		o.rmempty = true;
		o.validate = function(section_id, value) {
			if (!value)
				return true;

			return ipOrCidr(value) ? true : _('请填 IPv4 地址或 CIDR（例如 1.2.3.4/32）');
		};

		// ---------------- 旁路由
		s = m.section(form.NamedSection, 'dae', 'dae', _('旁路由'));
		s.description = _('打标流量会被送到这台机器上做二次决策。') +
			_('MAC 只用于「循环兜底」规则：它必须与旁路由网卡的真实 MAC 一致，') +
			_('换过网卡就要跟着改，自检里会核对。填好地址后可以点下面的「自动探测」直接读出来。');

		o = s.option(form.Value, 'next_hop', _('旁路由地址'));
		o.default = '192.168.0.253';
		o.rmempty = false;
		o.placeholder = '192.168.0.253';
		o.validate = function(section_id, value) {
			return ipOrCidr(value) && value.indexOf('/') < 0 ? true : _('请填 IPv4 地址');
		};

		o = s.option(form.Value, 'mac', _('旁路由 MAC'));
		o.rmempty = false;
		o.placeholder = 'aa:bb:cc:dd:ee:ff';
		o.validate = function(section_id, value) {
			return /^[0-9a-fA-F]{2}(:[0-9a-fA-F]{2}){5}$/.test(value)
				? true : _('格式应为 aa:bb:cc:dd:ee:ff');
		};

		o = s.option(form.Value, 'lan_dev', _('LAN 接口'));
		o.default = 'br-lan';
		o.rmempty = false;
		o.placeholder = 'br-lan';
		o.validate = function(section_id, value) {
			return /^[a-zA-Z0-9_.:@-]{1,15}$/.test(value) ? true : _('不是合法的接口名');
		};
	},

	// 表单渲染完之后，在「旁路由 MAC」那一行下面插一条探测行。
	// 用 input 的 id 定位（widget.cbid.<config>.<section>.<option>），
	// 这是 LuCI 里唯一稳定的锚点；name 是随机生成的。
	//
	// 必须从 wrap 里查，不能用 document.querySelector：
	// afterRender 是在 m.render().then(...) 里调的，此刻 wrap 还没被 LuCI
	// 挂进 #view，整个表单都不在 document 里 —— 用 document 查会一律返回 null，
	// 表现为「按钮根本没渲染」，而且不报任何错。
	afterRender: function(page, wrap) {
		var macEl = wrap.querySelector('[id="widget.cbid.pbr-lite.dae.mac"]');
		var devEl = wrap.querySelector('[id="widget.cbid.pbr-lite.dae.lan_dev"]');
		var hopEl = wrap.querySelector('[id="widget.cbid.pbr-lite.dae.next_hop"]');

		if (!macEl || !devEl || !hopEl)
			return;

		var msg = E('span', { 'style': 'font-size:92%;color:var(--text-color-medium,#666)' });
		var btn = E('button', {
			'type': 'button',
			'class': 'btn cbi-button',
			'style': 'padding:1px 10px;font-size:85%'
		}, _('自动探测'));

		btn.addEventListener('click', function() {
			var ip = (hopEl.value || '').trim();

			if (!/^[0-9]{1,3}(\.[0-9]{1,3}){3}$/.test(ip)) {
				msg.style.color = '#dc2626';
				msg.textContent = _('先把「旁路由地址」填对');
				return;
			}

			btn.disabled = true;
			msg.style.color = '';
			msg.textContent = _('正在探测 %s …').format(ip);

			callDetect(ip).then(function(r) {
				btn.disabled = false;

				if (!r || r.ok !== true) {
					msg.style.color = '#dc2626';
					msg.textContent = _('探测失败：%s').format((r && r.error) || _('未知错误'));
					return;
				}

				if (!r.mac) {
					msg.style.color = '#d97706';
					msg.textContent = _('%s 现在读不到 MAC（邻居表里没有，ping 也没回）').format(ip);
					return;
				}

				// 出口不是 LAN 接口时读到的 MAC 是网关的 —— 这种绝对不能往里填，
				// 填了兜底规则会去丢「网关」的包，比不填危险得多。
				if (r.on_lan === 0) {
					msg.style.color = '#dc2626';
					msg.textContent = r.note || _('这个地址不在 LAN 接口上，读到的 MAC 不可用');
					return;
				}

				var oldMac = macEl.value;

				macEl.value = r.mac;

				if (r.dev)
					devEl.value = r.dev;

				// 改完要让表单重算提示区（值变了，可能要重建规则）
				macEl.dispatchEvent(new Event('change', { bubbles: true }));

				var parts = [ _('已填入 %s').format(r.mac) ];

				if (r.dev)
					parts.push(_('接口 %s').format(r.dev));

				if (r.state)
					parts.push(r.state);

				if (oldMac && oldMac.toLowerCase() != r.mac.toLowerCase())
					parts.push(_('（原来是 %s）').format(oldMac));

				msg.style.color = '#16a34a';
				msg.textContent = parts.join(' · ') + _('  —— 记得点底部的「保存」');
			}).catch(function(e) {
				btn.disabled = false;
				msg.style.color = '#dc2626';
				msg.textContent = _('探测失败：%s').format(e && e.message ? e.message : e);
			});
		});

		// 放进 MAC 输入框所属的 .cbi-value-field 里，而不是另起一行：
		// 主题在窄屏会把「标签 / 输入框」上下堆叠，按 .cbi-value 外面插会对不齐。
		var row = E('div', {
			'style': 'display:flex;align-items:center;flex-wrap:wrap;' +
			         'gap:.3em .45em;margin-top:.45em;font-size:92%'
		}, [ btn, msg ]);

		var field = macEl.closest('.cbi-value-field');
		var host  = macEl.closest('.cbi-value') || macEl.parentNode;

		if (field)
			field.appendChild(row);
		else if (host && host.parentNode)
			host.parentNode.insertBefore(row, host.nextSibling);
	}
}));
