'use strict';
'require view';
'require form';
'require ui';
'require rpc';
'require pbr-lite.common as pb';

// /luci-static/resources/view/pbr-lite/advanced.js
//
// 高级设置页：打标值、路由层、nft 对象。
//
// 为什么单独一页：这三组正常用不到（默认值就是对的），混在日常开关里
// 一是页面太长、二是改错代价大 —— 打标值改错会让打标流量从主表出去，
// 集合名改错会让旧集合残留。分开之后「分流设置」只留日常能碰的东西。
//
// 流程骨架与分流设置完全一样（pb.settingsPage），这里只描述分节。

var OWN = [ 'mark', 'route', 'nft' ];

return view.extend(pb.settingsPage({
	title: _('高级设置'),
	descr: _('这些是数据面的「约定值」。默认值对绝大多数场景都是对的，') +
	       _('改之前请确认你知道它跟旁路由那边是怎么对上的；改错会导致分流静默失效。'),

	own: OWN,

	// 打标值与保留掩码的位不能重叠 —— 语义校验在 common 里做
	markCheck: true,
	// 改 mark.* 要手打 CONFIRM 才继续
	confirmMark: true,

	build: function(m, page) {
		var s, o;

		// ---------------- 打标
		s = m.section(form.NamedSection, 'mark', 'mark', _('打标值'));
		s.description = _('被分流的包会打上 mark，再由 ip rule 按 mark 送去路由表。') +
			_('「保留掩码」里为 1 的位会被保留，为 0 的位被清空后写入打标值 —— ') +
			_('所以打标值不能占用保留掩码里的位，否则一打标就被自己抹掉。') +
			_('默认 0x010000 / 0xff00ffff 是给 dae 用的约定值，除非你清楚在做什么，不要改。');

		o = s.option(form.Value, 'value', _('打标值'));
		o.default = '0x010000';
		o.rmempty = false;
		o.placeholder = '0x010000';
		o.validate = function(section_id, value) {
			return /^0x[0-9a-fA-F]{1,8}$/.test(value) ? true : _('必须形如 0x010000');
		};

		o = s.option(form.Value, 'keep_mask', _('保留掩码'));
		o.default = '0xff00ffff';
		o.rmempty = false;
		o.placeholder = '0xff00ffff';
		o.validate = function(section_id, value) {
			return /^0x[0-9a-fA-F]{1,8}$/.test(value) ? true : _('必须形如 0xff00ffff');
		};

		// ---------------- 路由层
		s = m.section(form.NamedSection, 'route', 'route', _('路由层'));
		s.description = _('打标流量按 ip rule 送进独立路由表，表里有一条指向旁路由的默认路由。') +
			_('改这三项只会重装 ip rule 与路由表，1 秒内完成，不碰 nft。') +
			_('优先级固定在 28000 附近是为了压过系统默认规则（32766/32767），') +
			_('又给 OpenVPN/mwan 之类留出空档。');

		o = s.option(form.Value, 'table_id', _('路由表号'));
		o.default = '250';
		o.rmempty = false;
		o.datatype = 'range(1,252)';

		o = s.option(form.Value, 'table_name', _('路由表名'));
		o.default = 'pbrlite';
		o.rmempty = false;
		o.validate = function(section_id, value) {
			// 与后端 RNAME 一致：数字开头会被 ip 当成表号直接解析
			return /^[a-zA-Z_][a-zA-Z0-9_]{0,31}$/.test(value)
				? true : _('必须字母或下划线开头，只含字母数字下划线，≤32 字符');
		};

		o = s.option(form.Value, 'pref', _('规则优先级'));
		o.default = '28000';
		o.rmempty = false;
		o.datatype = 'range(1,32765)';

		// ---------------- nft 对象
		s = m.section(form.NamedSection, 'nft', 'nft', _('nft 对象'));
		s.description = _('集合名与 include 路径。改名后旧集合不会自动消失（fw4 reload 只复位链和规则，') +
			_('不清 set 对象），这里会在应用成功后顺手清掉旧名字，删不掉会在进度日志里说明。') +
			_('include 必须落在 fw4 的 ruleset-post 目录里，那里面的 *.nft 才会被装载。');

		o = s.option(form.Value, 'set_src', _('源集合名'));
		o.default = 'pbrlite_src';
		o.rmempty = false;
		o.validate = function(section_id, value) {
			return /^[a-zA-Z0-9_]{1,32}$/.test(value) ? true : _('只能字母数字下划线，≤32 字符');
		};

		o = s.option(form.Value, 'set_dst', _('目标集合名'));
		o.default = 'pbrlite_notcn';
		o.rmempty = false;
		o.validate = function(section_id, value) {
			return /^[a-zA-Z0-9_]{1,32}$/.test(value) ? true : _('只能字母数字下划线，≤32 字符');
		};

		o = s.option(form.Value, 'include', _('include 路径'));
		o.default = '/usr/share/nftables.d/ruleset-post/30-pbr-lite.nft';
		o.rmempty = false;
		o.validate = function(section_id, value) {
			return /^\/usr\/share\/nftables\.d\/ruleset-post\/[A-Za-z0-9_.-]{1,80}\.nft$/.test(value)
				? true : _('必须在 /usr/share/nftables.d/ruleset-post/ 下且以 .nft 结尾');
		};
	}
}));
