# 设计说明与踩坑记录

这份文档记录「为什么这么写」。改代码前建议先看一遍，里面每一条都对应一次真实故障。

## 1. 产物与调用链

```
/etc/config/pbr-lite                UCI，唯一事实来源
      │  conf-export.sh
      ▼
/var/run/pbr-lite.conf              shell 变量（tmpfs，不磨损 flash）
/var/run/pbr-lite-direct.txt        直连白名单（一行一个 CIDR）
      │  pbr-lite-update
      ▼
/usr/share/nftables.d/ruleset-post/30-pbr-lite.nft    ← 数据面，nft 装载的就是它
/usr/share/pbr-lite/not-cn.txt                        ← 同内容的纯文本镜像（查询用）
/usr/share/pbr-lite/state.json                        ← 上一次更新的结果
/usr/share/pbr-lite/backup/30-pbr-lite.nft.<ts>       ← 最近 5 份

/etc/init.d/pbr-lite        ip rule 28000 + 路由表 250（只管路由，不碰 nft）
```

界面层的调用链（P2 起有写操作）：

```
LuCI 视图（overview / settings / source / diagnostics.js）
      │  ubus: pbr-lite.<method>
      ▼
/usr/share/rpcd/ucode/pbr-lite        校验参数 + 写 UCI + 起任务（立刻返回）
      │  popen 后台                      │
      ▼                                  ├─ status.sh / verify.sh / diag.sh   （只读，同步返回）
/usr/share/pbr-lite/job.sh            按生效半径干活，进度写 /var/run/pbr-lite/job.*
      │
      ├─ pbr-lite-update [--no-fetch]      重建 include（可失败自动回滚）
      ├─ init.d/pbr-lite restart           重装 ip rule / 路由表
      └─ verify.sh --fast                  收尾自检（只认 FAIL）
```

诊断页走的是**完全独立**的一条只读链路：`diag` → `diag.sh --json`，
`diag_bundle` → `diag.sh --bundle`（纯文本，前端拼成 Blob 下载）。
它跟 job 模型不共享任何状态，所以任务跑到一半也能打开看。

为什么要有「镜像」`not-cn.txt`：`lookup-ip.sh` 与 `verify.sh` 要按 CIDR 算归属，
如果每次都去 parse 190KB 的 include 太贵；而镜像和 include 同源，`verify.sh` 会检查
两者的 md5 一致。

**踩过的坑**：`--rollback` 早期只换 include、不重抽镜像，于是数据面回滚了、
`lookup-ip` 还报新版本的结论（8.8.8.8 被报成 `cn_unknown`）。现在回滚路径与
「内容无变化」路径都会同步一次镜像。

## 2. 六条硬约束

### C1. 一万条 CIDR 绝不进 ucode / 前端

列表只在 awk 里流转。界面只拿计数，需要看单条归属就走 `lookup_ip` 一次查一个。
任何「把集合渲染成表格」的实现都会让页面卡死。

### C2. 界面不做 apply，只做 trigger

`fw4 reload` 是全局操作，中途断电/失败会影响所有流量。所以「改配置」和「装载」是两件事：
先 `uci commit`，再由用户显式触发一次更新。

### C3. 任何变更都不能有「集合为空」的窗口

先算好新文件 → `nft -c` 预检 → 备份 → `cp` 换文件 → `fw4 reload`。
`fw4` 生成完整 ruleset 后 `nft -f` 一次性提交，中间没有「旧规则已删、新规则未装」的时刻。

对比 pbr：它的 restart 是「先 stop（删掉 nft 文件）→ 再花几十秒重建」，
那几十秒里所有流量都不打标，是实打实的泄漏窗口。

### C4. `add` 是幂等的，`flush table` 不清 set

这是本模块最容易踩的一个坑，单独强调：

```nft
add set inet fw4 pbrlite_notcn { type ipv4_addr; flags interval; }   # 已存在 → no-op
flush set inet fw4 pbrlite_notcn                                      # 必须显式清元素
add element inet fw4 pbrlite_notcn { ... }                            # 再灌
```

只写 `add set { elements = {...} }` 的表现是：**文件更新了、reload 成功、日志显示通过、
内核还是旧数据，零报错**。因为 `flush table` 只复位链和规则，set 对象连同元素原样保留，
而 `add set` 对已存在的集合直接跳过整块。

同样的道理适用于命名 counter：`flush table` 也不会清它。

### C5. 掩码语义不能想当然

两个掩码的语义正好相反：

| 变量 | 写法 | 含义 |
|---|---|---|
| `mark.keep_mask` | `meta mark & 0xff00ffff \| 0x010000` | **保留**掩码：这些位保持原值 |
| `ip rule` 的 mask | `fwmark 0x10000/0xff0000` | **匹配**掩码：这些位参与比较 |

匹配掩码 = 保留掩码按位取反。配置里只存一个（保留掩码），另一个由 `pl_match_mask()` 推出，
避免改一处忘另一处。校验不能比字符串，要比数值——`ip rule` 打印时还会去掉前导零
（`0x010000` 显示成 `0x10000`），字符串比较必然失败。

### C6. 内置保留段不可改；需求用直连白名单满足

14 个内网/保留段写死在 `exclude.txt`，不提供编辑入口。误删 `192.168.0.0/16` 的后果是：
内网访问被当境外流量打标 → 送旁路由 → 旁路由按 `geoip:private` 放行但不终结 →
包原样回来、源地址不变、目的仍在集合里 → 再次打标 → 来回弹到 TTL 耗尽 →
兜底规则开始大量丢包。症状是「内网服务全超时、上外网正常」，极难归因。

真实需求（公司 OA、固定出口 IP 想直连）用 `pbr-lite.direct.dst` 表达：
只增不减，只从补集里扣，覆盖不到内置段。

## 3. 其他实现细节

- **`nft -c` 预检必须用「改掉集合名」的副本**：`nft -c -f` 是对当前规则集做检查，
  集合已存在会报 `File exists`，直接拿真文件预检必然失败。
- **条目数校验必须精确**：内核元素数 == 文件元素数。用 `>= 1000` 这种阈值的话，
  即使集合压根没刷新、还是昨天的旧数据也会判通过（实测踩到过：更新跑了一整夜，内核没变）。
- **直连白名单会拆分 CIDR**：扣掉 `8.8.8.0/24` 会把原本覆盖它的整块 CIDR 拆成多块，
  条目数从 11193 涨到 11204 是正常的，不是重复。
- **成员抽查要跳过被白名单/保留段覆盖的 IP**：否则把 `8.8.0.0/12` 加进白名单后，
  抽查 `8.8.8.8` 必然失败。
- **busybox 的坑**：没有 `base64`（用 `xxd -r -p`）、没有 `diff`/`comm`（用 `md5sum`/`cmp`）；
  `tr` 不支持 `[:blank:]` 这类字符类，写了会静默不删任何字符（本项目因此把 11193 条算成 12592 条）。
  `date +%s%N` 也不支持，计时用 shell 内建 `time`。

## 4. 界面层

- 后端是 rpcd 的 ucode 插件 `/usr/share/rpcd/ucode/pbr-lite`，暴露一个 ubus 对象，
  **方法白名单**：`status` / `verify` / `lookup_ip` / `peer_info`→`detect_peer` / `export_conf` /
  `job_status` / `diag` / `diag_bundle` / `apply_config` / `update` / `rollback`。不提供通用 `exec`——这是安全底线。
- 业务逻辑一律留在 shell（可脱离 LuCI 单独跑、单独测），ucode 只做
  「校验参数 + 调脚本 + 转 JSON」。`apply_config` 收到的是一张 `section.option` 扁平表，
  按 `SPEC` 白名单逐项校验格式，不认识的名字直接拒绝（不做「尽力而为」）。
- LuCI 的 `E()` 底层是 `L.dom.append()`，**不递归嵌套数组**：
  `[节点, [节点, 节点]]` 会把内层数组整体 `String()` 成 `[object HTMLDivElement]`。
- 部分主题（如 QWRT）把 `fieldset > legend` 设成 `display:none`，用 legend 当标题会整块看不见，
  所以卡片标题用 `h3` 自带样式。
- `status.sh` 会被界面轮询，必须便宜：文件条目数读镜像而不是每次 sed 19 万行的 include。
  实测一次 `status` 在 aarch64 上约 0.65s，轮询间隔设 15s。

### 4.1 异步任务模型（P2）

重建规则要 7~12 秒，ubus 调用同步跑会撞 rc 超时、页面也会僵住。所以：

```
apply_config  →  校验 → 快照 /etc/config/pbr-lite 到 config.prev
                  → 写 UCI（ucode 的 uci cursor 只改内存，commit 才落盘）
                  → popen('job.sh apply &') 立刻返回
job.sh        →  flock 单例 → 按「生效半径」跑 → 把进度写进 /var/run/pbr-lite/job.*
前端          →  每秒轮询 job_status，直到 state 不是 running
```

状态用几个纯文本文件（`job.state` / `job.step` / `job.result` / `job.log` / `job.started`），
不用单个 JSON：shell 里拼 JSON 是引号地狱，而 ucode 侧组装 JSON 本来就顺手。
每个字段都是「写 .tmp 再 mv」，读的一方永远看不到写了一半的值。

**写入顺序有讲究**：先写 `state=running` 再写其它字段。反过来的话会有几十毫秒的窗口
看到「state 还是上一轮的 done，kind 已经是新的」，界面就会把旧结论挂在新任务名下
（实测出现过「刷新列表 … 应用完成（自检 57 项通过）」这种混搭）。

**`job.pending` 只认 30 秒内的**：它是启动前的占位标记，正常毫秒级就被摘掉。
留太久说明那个 job 根本没起来（脚本没了、权限不对），当成「启动中」会一直挡住下一次保存。

### 4.2 生效半径

改一个字段不等于要全量重来。`job.sh apply` 的做法是：把新配置导出一份到
`/var/run/pbr-lite.candidate`，跟**正在生效的那份** `/var/run/pbr-lite.conf`
逐项比对，再决定动哪一层：

| 改了什么 | 要做什么 | 耗时 |
|---|---|---|
| `enabled` / `guard` / `src_addr` / `dae.mac` / `mark.*` / `set_*` / `include` / `direct.dst` | 重建 include + fw4 reload | 7~12s |
| `next_hop` / `lan_dev` / `table_id` / `table_name` / `pref` | 只重装 ip rule 与路由表 | ~1s |
| `min_entries` / `max_drift` | 只影响下次更新的判据，不动数据面 | 0 |
| `mark.*` | 上面两者都要 | 10~15s |

比的是「导出文件」而不是前端传来的改动列表：前端漏报多报都会让半径算错，
而那份导出就是数据面的现状，不会骗人。

**打标值变更的切换窗口**：include 换掉的那一刻新 mark 开始生效，而 `ip rule` 还是旧的，
中间那一秒打标流量没有规则认，会掉回主表走真实出口。所以 mark 变更时先在 `pref+100`
上补一条指向同一张表的规则顶住，等 `init.d restart` 装好正式规则再撤掉。

**改名残留**：改 `nft.set_*` / `nft.include` 之后，旧 include 文件与旧集合都不会自己消失
（fw4 reload 只 `flush table`，不清 set 对象；而 `ruleset-post/*.nft` 是整目录装载的，
旧文件留着=两套规则同时生效）。job 会在应用成功后删掉旧文件、`nft delete set` 旧名字，
删不掉（仍被引用）会在进度日志里说明。

### 4.3 失败即整体回滚

任何一步失败都走 `_recover`：恢复 `config.prev` → `uci commit` → `conf-export` →
`pbr-lite-update --no-fetch` → `init.d restart`。三层（配置/include/路由）必须一起退，
只退一层会得到「配置是新的、规则是旧的」这种更难查的状态。

### 4.4 P2 阶段踩到的坑

- **ucode 正则量词上限 255**：`{4,300}` 直接抛 `Invalid contents of {}`，
  而且是**加载期语法错误** —— 整个 rpcd 插件连一条方法都注册不上，`ubus list` 里啥都看不到，
  日志也只有一句 `Command failed: Not found`。排查时先用
  `/usr/bin/ucode /usr/share/rpcd/ucode/pbr-lite` 直接跑一遍。
- **LuCI 的 `require` 只接受构造函数**：模块 `return` 一个普通对象会抛
  `factory yields invalid constructor`。而返回 `baseclass.extend({...})` 后，
  取到的对象上又拿不到构造函数上的静态成员。稳妥做法是每个导出**同时挂到类上和 prototype 上**。
- **`ui.showModal()` 的内容里 `E()` 挂的 click 监听不生效**：按钮渲染出来了，点了没反应，
  遮罩还会一直拦住后面的点击。改成自绘 overlay + `addEventListener` 才可靠。
- **表单必须只提交「本页渲染的分节」**：设置页没有 `source` 分节，`m.data.get()` 读出来是空，
  一起提交等于把列表地址清空（被后端 URL 校验拦下来才发现）。
- **`form.Flag` 的「未勾选」和「没配置过」都读成 null**，而这两个开关默认都是开。
  只能直接看 DOM 里的勾选状态，且控件的 `name` 是随机生成的 `cbXXXXXXXX`，
  要用 `id="widget.cbid.<config>.<section>.<option>"` 定位。
- **JSON 里的控制字符**：`ip rule` 输出字段之间是制表符，`pl_jesc` 只处理了换行，
  于是 `verify.sh --json` 产出的 JSON 非法。ucode 的解析器宽容（所以 P1 一直没暴露），
  jq 直接报 `control characters must be escaped`。现在 tab / ESC / CR 都清掉。
- **ucode 字符类里不能写 `\[\]`**：不报错，但**整个字符类变成永不匹配**。表现为
  「明明合法的 URL 被报格式错」。这比量词超限更阴——那好歹是加载期直接失败，这个静默失效。
  正确写法是把 `]` 摆在 `[` 后面第一位：`[]A-Za-z0-9._~:/?#[@!$&'()*+,;=%-]`。
  这类问题**只有喂一个真值才暴露**，所以每个 `kind` 都要有一条「合法值应该通过」的测试，
  不能只测非法值（P2 当时只测了 6 个非法值，`source.url` 恰好是唯一没走过真值的字段）。
- **`route.table_name` 不能数字开头**：名字会被写进 `/etc/iproute2/rt_tables` 再被
  `ip rule ... lookup <name>` 引用，数字开头（尤其纯数字）会被 `ip` 当成表号直接解析、
  绕过名字映射。实测 `9x` 能跑通（init 脚本会写映射），但那是运气，校验层直接按
  `^[a-zA-Z_][a-zA-Z0-9_]{0,31}$` 拦掉。

### 4.5 设置页拆两页，与「自动探测」的时机坑

原来一页放 8 个分节（开关 + 打标值 + 路由层 + nft 对象 + 旁路由 …），日常要碰的其实
只有前四组。把 `mark` / `route` / `nft` 拆到「高级设置」后，两页共用同一套流程骨架
`pb.settingsPage(opts)`：`load`/`render`/`collect`/`refreshHint`/`doApply` 都在骨架里，
各页只声明 `own: [分节名]` 和 `build(m, page)`。

关键约束：**`collect()` 只提交 `own` 里的分节**。表单里别的分节没渲染，`m.data.get()`
读出来是空，一起提交等于把那些项清空（见 4.4）。

两处必须用「查询根」而不是 `document`：

- `collect()` 里读 `form.Flag` 的勾选状态 —— 用 `this.root`（settingsPage 存的 wrap）；
- `afterRender(page, wrap)` 里插自定义控件 —— 用 `wrap.querySelector(...)`。

原因是 `afterRender` 在 `m.render().then(...)` 里、`return wrap` 之前被调用，
此刻 wrap 还没被 LuCI 挂进 `#view`，**整个表单都不在 document 里**。
用 `document.querySelector` 一律返回 null，表现为「按钮根本没渲染」，而且不报任何错
（`if (!el) return;` 把它咽掉了）。这类「onload 时机 + 全局查询」的组合是静默失败的常见来源。

**还有一个更贵的坑：`m.parse()` 不会把「改回原值」写进去。**
`CBIAbstractValue.prototype.parse` 的关键一句是

```js
else if (this.forcewrite || !isEqual(cval, fval))
    return Promise.resolve(this.write(section_id, fval));
```

`cval` 是**加载时**读到的配置值。于是「把某个字段改掉、再改回原样」时 `fval == cval`，
这一步直接跳过 write —— 同时**上一次记下的 change 也不会被清掉**（`uci.set` 只在
value 非空时覆盖 `state.changes`，没有「撤销本次改动」的语义）。
`collect()` 读的是 `data`，于是读到的是中间那个值。

后果比「提示不准」严重得多：用户把 `dae.mac` 改成 `…df` 又改回 `…de`，点保存，
落盘的是 `…df` —— 数据面从此按一个错误的 MAC 做循环兜底，下次它就丢真正的包了。
（实测确认：DOM 是 `…de`，`state.changes` 还是 `…df`，连手动 `map.parse()` 也刷不掉。）

修法：建完表单后给每个 option 打开 `forcewrite`，让它每轮都写一遍：

```js
m.children.forEach(function(sec) {
    (sec.children || []).forEach(function(opt) { opt.forcewrite = true; });
});
```

因为本包从不调用 `map.save()`（配置走 `apply_config` 落盘），`forcewrite` 不带来任何副作用。

顺带：`diffFields()` 只比较**本页收集到的键**（`if (!(f.key in values)) return false`）。
拆页后另一页的分节不在 `values` 里，照常比下去会被 `normValue` 当成「没设置 → 用默认值」，
于是高级页永远在提示「生效地址、旁路由 MAC 被改动」。

**「旁路由 MAC 自动探测」**（`peer-info.sh`）做三件事，顺序不能换：

1. `ip route get <ip>` 拿出口设备 —— 这决定了「这个地址到底在不在 LAN 上」；
2. 读 `ip neigh` 拿 MAC；读不到就 `ping -c1 -W1` 一次再读（邻居表冷启动时是空的）；
3. `EXPECT_DEV` 与出口设备不一致时**拒绝填入**并说明原因。

第 3 步不是洁癖：出口不是 LAN 接口时，邻居表里那条记录是**下一跳网关**的 MAC，
填进 `dae.mac` 等于让循环兜底规则去丢网关发回来的包，比不填危险得多
（和「开机时拿 neigh 表当下一跳存活门禁」是同一类错误：把「能查到」当成「是对的」）。

最后一条与功能无关的噪音：浏览器控制台里会有一条
`POST /cgi-bin/cgi-exec 403 Exec permission denied`，请求体是
`nft --terse --json list ruleset`。这是 QWRT 主题的 `menu-design.js` 在决定
「防火墙菜单要不要指向 iptables 变体」，本包的 ACL 理应不给 `file.exec nft` 权限，
拿不到就 fallback，功能无影响 —— 不要为了消掉它去放宽 ACL。

### 4.6 视觉统一：一套 CSS 管五个页面

初版每个页面各写各的内联样式，结果是同一类信息在两页长得不一样（最刺眼的是
「概览的键值表左对齐、规则源的值右对齐」）。现在结构只负责 class，外观集中在
`common.js` 的 `CSS` 常量里，注入成 `<style id="pbr-lite-style">`，作用域 `.pbrlite`。

四类东西共用一套定义：`.pb-card`（卡片）、`table.pb-kv`（键值表）、`.pb-badge`（徽章）、
`.pb-banner`（顶部状态条）。`form.Map` 渲染出来的分节也被同一套选择器接管
（`.cbi-map > .cbi-section:not(.pb-card)`），所以「表单页」和「只读页」看起来是一个风格。

主题覆盖踩到的四处（都是实测，改之前先看这里）：

| 现象 | 原因 | 处理 |
|---|---|---|
| 值列莫名右对齐 | 主题 `.table` 给单元格设了 `text-align:right` | `.pbrlite table.pb-kv td` 显式 `left` |
| 「nft 对象」显示成「Nft 对象」 | 主题给 `h3` 加了 `text-transform:capitalize` | 标题显式 `text-transform:none` |
| 「源地址」标签垂直居中在一长列输入框中间 | `.cbi-value` 是 `flex; align-items:center` | 改 `flex-start` + label 加 `padding-top` |
| 顶部状态条太吵 | 用 `alert-message success`，那是一整条实心绿 | 换成 `.pb-banner`：浅底 + 左侧色条 + 圆点 |

**不要动主题的自绘控件。** 动态列表（`DynamicList`）的红色 × 是 `.item::after` 伪元素、
蓝色 + 是 `.cbi-button-add`，它们和 DHCP 静态租约等系统页面是同一个样式。
只为「好看」把它们改掉，本页面反而成了全站唯一的异类。同理，卡片里的工具按钮
（如「刷新」）用 `.pb-card-tool` 绝对定位浮在标题行右端，不占流 —— 放标题和表格之间
会凭空多出一条 50px 的空白，比放在表格下方更难看。

## 5. 性能：一次更新到底花在哪
实测（aarch64 AN7581，1.1 万条补集）：

| 阶段 | 耗时 | 说明 |
|---|---|---|
| 下载 CN 列表 | 0.3s | 上游很快，**不是瓶颈**（早期以为是，加 `--no-fetch` 只省了 0.3s） |
| 算补集 | 3.9s | busybox awk 逐行解析，pass1 0.85s + sort 0.01s + pass2 3.1s |
| 成员抽查 | 2.0s | 原来 6 个 IP 各扫一遍 1.1 万行（5s），改成一次 awk 判完（2s） |
| 生成 include | 1.0s | awk 拼 19 万字符 |
| `nft -c` 预检 | 1.0s | |
| 合计 | **7.6s** | 改之前 11s |

`verify.sh` 从 9.7s 降到 6.0s：6 个抽查 IP 合并成一次扫描，集合内容只 dump 一次
（原来「判存在」和「数条目」各 dump 一遍，nft 格式化 1.1 万元素单次约 1s）。
注意它其中 3 秒是**故意的**：兜底规则要采样 3 秒看丢包数，`--fast` 会跳过。

`busybox awk` 在这颗 CPU 上解析一行约 180µs，所以「多扫几遍」这种事必须合并成一遍。

### 5.1 概览页打开慢：两处一起改（P3 之后）

现象：概览页要 4 秒多才出来。拆开看是两件事叠在一起。

**其一，首屏被自检挡着。** `load()` 原来是 `Promise.all([status, verify])`，
页面要等最慢的那个。`status` 0.65s、`verify --fast` 4.3s，于是首屏 4.3s。
改成 `load()` 只等 `status`，渲染完再异步发起自检、结果到了填卡片 —— 首屏 **1.1s**。

**其二，自检自己也不便宜。** 再往里拆（给每个 `hdr` 打时间戳）：

| 环节 | 耗时 | 处理 |
|---|---|---|
| 7. 地址表抽查（成员比对） | 2.36s | 按「表内容 + 直连白名单」的 md5 缓存，命中就跳过全表重扫 |
| 4. 内核装载（nft dump） | 0.63s | 已是最小值：`nft list set` 本身 0.38s，绕不开 |
| JSON 输出循环 | ~1.0s | 每条 item 三个 `cut` + 两次 `pl_jesc`（各 5 个 fork），60 条约 400 次 fork → 改成一次 awk |
| 其余 | ~0.3s | |

`--fast` 从 4.3s 降到 **1.13s**（冷启动 3.4s，第一次要真扫一遍）。

两个「不要做的事」：

- **别想靠微调 awk 提速**：实测预算 BLK 表只省 10%（2.39s→2.16s），改用「33 个候选前缀 +
  `grep -F -x -f` 精确匹配」反而更慢 —— busybox grep 的多模式匹配是 O(n×m)，
  198 条模式 0.82s，而单条模式只要 0.04s。瓶颈是 awk 的逐行开销本身，换算法维度才行。
- **别用 `navigator.clipboard` 做复制**：LuCI 走 http，不是安全上下文，
  `navigator.clipboard` 直接是 `undefined`，只能退回 textarea + `execCommand`。

### 5.2 一个「点了没反应」的坑（`createHandlerFn`）

LuCI 的 `ui.createHandlerFn(ctx, fn)` 会在调用处理函数**之前**就把按钮 `disabled = true`
并加上 `spinning`，返回后才在 `finally` 里恢复：

```js
return L.bind(function() {
    const t = arguments[args.length].currentTarget;
    t.classList.add('spinning'); t.disabled = true; ...
    Promise.resolve(fn.apply(ctx, arguments)).finally(() => { ...恢复... });
});
```

所以处理函数里写 `if (btn.disabled) return;`（本意是防重复点击）会变成**永远提前返回**：
按钮点了毫无反应、控制台也没有任何报错。诊断页的「下载诊断包」和概览页的「重新自检」
都栽在这上面。用 `createHandlerFn` 就别自己管按钮状态；用 `addEventListener` 才需要。

## 6. 还没做的

- **IPv6**：schema 已预留 `family` 字段，但集合、补集算法、ip rule 都是 v4-only。
- **英文语料**：`po/templates/luci-app-pbr-lite.pot` 已经能提取 220 条，
  但只写了 `po/zh_Hans`（恒等映射）；`po/en` 欢迎 PR。

