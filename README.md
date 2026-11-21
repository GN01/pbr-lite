# pbr-lite

> 精简版策略路由：把「指定内网设备访问境外 IP」的流量打上 firewall mark，
> 交给一条 `ip rule` 送进独立路由表，走旁路由（dae / clash / 透明代理机器）。
> 国内 IP 与内网保留段直连，不经过旁路由。

面向的场景：主路由跑 OpenWrt，另有一台机器做代理（旁路由），只想让**部分设备**走代理。
一万多条「非中国 IP」的 CIDR 由脚本每天自动维护，界面只做展示。

```
                        ┌──────────────────────────────┐
  192.168.0.2 ──┐       │  OpenWrt (本包)               │
  192.168.0.20 ─┼──►    │                              │
  其他设备 ─────┘       │  nft: 源命中 && 目的非CN      │
                        │        └─► meta mark 0x010000 │
                        │                              │
                        │  ip rule 28000: fwmark ──────┼──► table 250 ──► 旁路由 192.168.0.253
                        │  其余流量 ───────────────────┼──► 主表 ──► WAN 直连
                        └──────────────────────────────┘
```

## 为什么不用 pbr

[pbr](https://github.com/openwrt/packages/tree/master/net/pbr) 很好用，但它的数据面是
「把 CIDR 列表逐行拼成 nft 规则」。列表上到一万条后：

| | pbr 1.2.2 | pbr 1.2.4 (ucode) | **pbr-lite** |
|---|---|---|---|
| 1.1 万条装载耗时 | ~90s（reboot 时拖死 fw4） | 210s（195s 卡在一条嵌套量词正则上） | **< 1s** |
| reload 期间有无「不打标」窗口 | 有（先 stop 删文件再重建） | 有 | **无（单事务换文件）** |
| 日常维护 | 每次重启都要重算 | 同左 | 内容不变就完全不 reload |

差别在于**产物形态**：pbr-lite 生成的是一个包含 `nft set` 的 fw4 include 文件，
`fw4 reload` 时由 `nft -f` 一次性装载；一万条对 nft 来说只是一次批量插入。

## 特性

- **无窗口切换**：先算好新文件 → `nft -c` 预检 → 备份 → 换文件 → `fw4 reload`（单事务）→ 精确校验，失败自动回滚。
- **精确校验**：内核里的元素数必须等于文件里的元素数。不用「大于 1000」这种阈值——
  那样即使集合压根没刷新、还是昨天的数据，也会被判成通过。
- **上游异常保护**：条目数下限 + 漂移阈值（默认 40%），列表被截断时宁可不动。
- **直连白名单**：某些公网地址（公司 OA、固定出口 IP）想直连，加进 UCI 即可，从补集里扣。
  内网保留段（14 段）写死只读，不提供编辑入口——误删就是断网。
- **循环兜底**：旁路由把包原样转回来时（源 MAC 是旁路由网卡且仍命中条件）直接丢弃，
  避免在路由器和旁路由之间弹到 TTL 耗尽。
- **零第三方包**：纯 shell + awk + nft，不依赖 ucode/uci 以外的东西（LuCI 界面除外）。

不做的事（明确的能力边界）：

- 只做 **IPv4**；
- 只按**源地址**分流，不做域名分流（那是 dae/clash 的活）；
- 不做 DNS 劫持、不做透明代理本身。

## 前置条件

- OpenWrt 22.03+ / 23.05+ / 24.10+（fw4 + nftables），已在 QWRT 25.12.3 (aarch64) 实测；
- 一台同 LAN 的旁路由，且它能处理「源 IP 不是自己」的转发流量（dae 需要额外加 SNAT 或使用 tproxy 模式）；
- 依赖包：`nftables`、`curl`、`ca-bundle`、`firewall4`、`ip-tiny`（`ip rule` 需要 iproute2，busybox 的 ip 不够用）。

## 安装

### 方式一：编进固件 / 用 SDK 打包

把本仓库放进 OpenWrt 的 `package/` 或任意 feed 目录：

```sh
cd openwrt
git clone https://github.com/<you>/pbr-lite package/pbr-lite
make menuconfig      # Network → pbr-lite；LuCI → Applications → luci-app-pbr-lite
make package/pbr-lite/compile V=s
```

### 方式二：直接把文件铺上去（不编译）

仓库自带一个安装脚本，按 `files/` 的目录结构把文件复制到 `/`：

```sh
scp -r pbr-lite root@192.168.0.1:/tmp/pbr-lite-src
ssh root@192.168.0.1 'sh /tmp/pbr-lite-src/tools/install.sh'
```

卸载：

```sh
ssh root@192.168.0.1 'sh /tmp/pbr-lite-src/tools/install.sh --uninstall'
```

## 快速开始

装完只需要改三样东西：**哪些源地址走代理**、**旁路由的 MAC 和 IP**、**是否启用**。

```sh
uci set pbr-lite.main.enabled='1'
uci add_list pbr-lite.lan.src_addr='192.168.0.2'
uci add_list pbr-lite.lan.src_addr='192.168.0.20'
uci set pbr-lite.dae.next_hop='192.168.0.253'
uci set pbr-lite.dae.mac='a4:ae:12:77:5d:de'
uci commit pbr-lite

/usr/share/pbr-lite/conf-export.sh    # UCI → /var/run/pbr-lite.conf
/usr/sbin/pbr-lite-update --force     # 下载列表、算补集、生成 include、reload
/usr/share/pbr-lite/verify.sh         # 9 组自检
```

`dae.mac` 必须是旁路由**在 LAN 侧那块网卡**的 MAC，用来自动识别「旁路由把包转回来了」。
填错不会断网，但循环兜底会失效。不想手抄就装 LuCI 界面，在「分流设置 → 旁路由」
点「自动探测」，它会连 IP 一起把 MAC 和出口接口填好（或直接跑
`/usr/share/pbr-lite/peer-info.sh 192.168.0.253`）。

配好之后加一条 cron（UCI 里不存 cron，避免两处真相）：

```sh
echo '17 4 * * * /usr/sbin/pbr-lite-update' >> /etc/crontabs/root
/etc/init.d/cron restart
```

## 命令行

| 命令 | 用途 |
|---|---|
| `pbr-lite-update` | 日常更新。内容没变就不 reload |
| `pbr-lite-update --force` | 强制重装并 reload |
| `pbr-lite-update --dry-run` | 只算不落地，看条目数变化 |
| `pbr-lite-update --json` | 机器可读输出 |
| `pbr-lite-update --rollback [N]` | 回滚到第 N 新的备份（默认最新） |
| `pbr-lite-update --no-reload` | 只写文件，不动运行中的规则 |
| `pbr-lite-update --no-fetch` | 不下载，用上次缓存的 CN 列表重建（改白名单/mark 时用） |
| `verify.sh [--json] [--fast]` | 9 组只读自检 |
| `status.sh [--json]` | 只读状态汇总（内核事实） |
| `lookup-ip.sh <ip> [--json]` | 单个 IP 会被代理还是直连，以及命中的 CIDR |
| `peer-info.sh <ip> [--json]` | 这个地址从哪个接口出去、MAC 是多少（界面「自动探测」调它） |
| `conf-export.sh` | UCI → `/var/run/pbr-lite.conf` |
| `job.sh apply / update / rollback` | 长任务执行器（LuCI 异步调用它，也可手跑） |

## 工作原理（三件事）

1. **打标**：`/usr/share/nftables.d/ruleset-post/30-pbr-lite.nft` 由 `pbr-lite-update` 生成，
   在 `mangle_prerouting` 里加两条规则——一条打标，一条循环兜底 drop。
2. **选路**：`/etc/init.d/pbr-lite` 装 `ip rule pref 28000` 与路由表 250（`default via 旁路由`）。
   两边共用同一组 mark 值，匹配掩码由保留掩码自动取反推出，不手写第二份。
3. **数据**：每天下载中国 IP 列表，算 `0.0.0.0/0` 的补集（减去中国、减去 14 个保留段、
   减去直连白名单），结果既是 nft 集合的元素，也是 `not-cn.txt` 镜像。

### 两个必须知道的 nft 陷阱

生成 include 用的是 `add set` → `flush set` → `add element` **三段式**，不能只写
`add set { elements = ... }`：

- `fw4 reload` 只执行 `flush table`，而 nft 的 `flush table` **不清 set 对象**；
- `add set` 对已存在的集合是**幂等 no-op**，整个 `elements` 块会被静默跳过。

结果就是「文件更新了、reload 成功、日志显示通过、内核还是旧数据」，且零报错。
（本项目实测踩过：更新跑了一整夜，内核条目一条没变。）

## LuCI 界面

菜单在 **服务 → PBR Lite**（`admin/services/pbr-lite`），五个页签：

| 页签 | 内容 |
|---|---|
| 概览 | 运行状态、文件与内核的数据一致性、打标/兜底计数、旁路由 ARP 健康、9 组自检 |
| 分流设置 | 开关、生效地址、直连白名单、旁路由（MAC/接口可一键探测） |
| 高级设置 | 打标值与保留掩码、路由表号/表名/优先级、nft 集合名与 include 路径 |
| 规则源 | 列表地址、条目下限/漂移阈值、立即更新、备份回滚 |
| 诊断 | 单个 IP 归属查询、include 头部、两条规则原文、日志尾巴、一键诊断包 |

「高级设置」单独一页是有意的：那七八项正常用不到（默认值就是对的），混在日常开关里
一是页面太长、二是改错代价大——打标值改错会让打标流量从主表出去，集合名改错会让旧集合残留。
分开之后日常页只留「会经常碰」的东西，高级页的改动还会要求手打 `CONFIRM`。

三个值得知道的设计：

**改之前就告诉你要等多久。** 保存前会算「生效半径」——跟正在生效的那份导出逐项比对，
告诉你这次是只重装 ip rule（约 1 秒）还是要重建 nft 规则（约 10 秒）。
改了打标值这类会动手改路由的项，还要手打 `CONFIRM` 才继续。

**旁路由 MAC 不用手抄。** 「分流设置 → 旁路由」里的「自动探测」会用 `ip route get` 定位
这个地址从哪个接口出去、再读邻居表拿 MAC（邻居表是空的就先 ping 一下）。
出口不是配的 LAN 接口时**拒绝填入**——那种情况下读到的是网关的 MAC，填进去等于让兜底规则去丢网关的包。
后端是 `peer-info.sh`，命令行也能单独跑。

**长任务不在请求里跑。** 重建规则要 10 秒，同步等会撞超时、界面也会僵住。
所以 ubus 只做「校验 + 落配置 + 起任务」，页面轮询进度；失败时配置自动退回上一份，
并把配置、include、路由三层一起拉回同一版。

**首屏不等自检。** 概览页只用 `status`（约 0.6 秒）渲染，自检在页面出来后异步跑、
结果到了再填卡片。自检本身也从 4.3 秒压到 1.1 秒：1.1 万行的成员抽查按「表内容指纹」缓存，
JSON 拼装从 400 多次 fork 改成一次 awk。（这两处改动的来龙去脉见 `docs/architecture.md` 第 5 节。）

界面只是一个视图：卸载 `luci-app-pbr-lite`，分流管线照常工作。

**样式只有一套。** 卡片、键值表、徽章、状态条、代码块都定义在 `common.js` 的 `CSS`
常量里，作用域限定在 `.pbrlite`，五个页面共用。所以不会出现「概览的值左对齐、
规则源的值右对齐」这种不一致，也不用改主题 —— 卸载界面包，系统其它页面一个像素都不变。

**诊断页**是最值得先试的一页：输入一个 IP，它会告诉你这个地址走代理还是直连、命中哪条
CIDR、以及打标后实际落到哪条路由——不用 SSH 就能回答「为什么这个站点没走代理」。

## 界面语言

界面文案用 LuCI 的 `_()` 包裹，msgid 就是简体中文，所以**不装任何翻译也是中文**。
`po/templates/luci-app-pbr-lite.pot` 是提取好的模板（220 条），
`po/zh_Hans/` 是恒等映射的语料。要加英文：复制成 `po/en/luci-app-pbr-lite.po`、把 `msgstr`
翻掉即可；buildroot 里有 `po2lmo` 时 `make` 会自动编成 `.lmo`，没有就跳过（不影响安装）。

## 排障

先跑这两个，绝大多数问题能定位：

```sh
/usr/share/pbr-lite/verify.sh          # 9 组 58 项，FAIL 会告诉你哪一层断了
/usr/share/pbr-lite/status.sh          # 内核事实 + 上一次更新的结果
/usr/share/pbr-lite/lookup-ip.sh 8.8.8.8
/usr/share/pbr-lite/diag.sh            # 人读的诊断汇总；--bundle 出纯文本诊断包
```

界面里的**诊断**页是同一个信息源的图形版：不想 SSH 就点那一页，
右上角「下载诊断包」会把环境、配置、规则、路由、自检、日志打成一个 txt，直接贴出来即可。

几个常见结论对应的原因：

| 现象 | 大概率原因 |
|---|---|
| `verify` 报「内核 N 条 != 文件 M 条」 | include 没被 reload，或 fw4 起不来 |
| 打标计数不涨 | 源地址不在 `pbrlite_src`；或设备走了 IPv6；或 flow offloading 让第二个包之后绕过 netfilter |
| 兜底计数持续增长 | 旁路由把包原样转回来了（缺 SNAT，或 dae 只放行不终结） |
| 内网服务全超时、外网正常 | 保留段被误改（本包不提供编辑入口，理论上不会） |
| 界面里「旁路由邻居」与配置不一致 | 旁路由换了网卡，`dae.mac` 要跟着改 |
| 界面「保存」报「已有任务在执行」 | 上一个任务还没跑完（正常 10 秒内），等它结束；超过 5 分钟会标成卡住 |
| 改完配置后提示要重建，想更快 | 只有改路由层（表号/优先级/下一跳）才是 1 秒；改集合相关一律要重建，这是设计 |
| 某个站点没走代理 / 走了代理 | 诊断页查那个 IP：`verdict` 决定该不该走，「实际去向」决定实际走没走。两者不一致就是 ip rule 或路由表没装 |

## 目录结构

```
pbr-lite/                     内核包（无 UI 也能跑）
  files/usr/sbin/pbr-lite-update
  files/usr/share/pbr-lite/{lib.sh,conf-export.sh,gen-not-cn.awk,exclude.txt,
                            verify.sh,status.sh,lookup-ip.sh,peer-info.sh,diag.sh,job.sh}
  files/etc/init.d/pbr-lite
  files/etc/hotplug.d/iface/99-pbr-lite
  files/etc/uci-defaults/90-pbr-lite-firstrun
  files/etc/config/pbr-lite
luci-app-pbr-lite/            界面包（纯视图层）
  htdocs/luci-static/resources/view/pbr-lite/{overview,settings,advanced,source,diagnostics}.js
  htdocs/luci-static/resources/pbr-lite/common.js    ← 卡片/表格/任务面板/复制等公共件
  root/usr/share/luci/menu.d/luci-app-pbr-lite.json
  root/usr/share/rpcd/acl.d/luci-app-pbr-lite.json
  root/usr/share/rpcd/ucode/pbr-lite        ← ubus 对象，方法白名单，无通用 exec
  po/templates/luci-app-pbr-lite.pot        ← 界面文案模板（220 条）
  po/zh_Hans/luci-app-pbr-lite.po
tools/
  install.sh                  不编译时的安装/卸载脚本
  migrate-from-sdwan.sh       从早期 shell 变量版（/etc/sdwan.conf）迁移
docs/
  architecture.md             设计取舍与踩过的坑
```

## 许可证

MIT
