# ym — Reality 最佳目标域名一键查找

给一台服务器的 IP，自动帮你找到**最适合给它做 Xray Reality 目标（dest / serverNames）的域名**。

它把两个优秀的开源工具串成一条流水线，你只管输入 IP 和看结果：

| 阶段 | 工具 | 做什么 |
|---|---|---|
| 扫描 | [XTLS/RealiTLScanner](https://github.com/XTLS/RealiTLScanner) | 扫描目标 IP 邻域的 TLS 站点，找出支持 TLS 1.3 + H2 的候选 |
| 归一化 | ym 内置 | 对齐两个工具之间的 CSV 格式差异、去重（见下文「工作原理」） |
| 检测 | [V2RaySSR/RealityChecker](https://github.com/V2RaySSR/RealityChecker) | 逐个深检：TLS 1.3 / X25519 / H2 / SNI 匹配 / 证书有效期 / CDN / 热门站 / 被墙 / 地理位置 |
| 推荐 | ym 内置 | 汇总通过全部硬性条件的域名，给出可直接粘贴的 `dest` / `serverNames` 配置片段 |

单文件 bash 脚本，`ym` 一个命令进菜单，风格和常见的 VPS 一键脚本一样：首次运行自安装、数字菜单操作、**每次启动自动检查两个上游工具的新版本并在菜单顶部提醒，是否更新由你决定**，还可以**回退到任意历史版本**。

---

## 快速开始

```bash
# 1. 拿到脚本（克隆本仓库，或直接下载单个 ym.sh 文件都可以）
git clone https://github.com/yuyuyu420/ym-reality.git
cd ym-reality
chmod +x ym.sh
# 只想要单文件版:
# curl -fsSL -o ym.sh https://raw.githubusercontent.com/yuyuyu420/ym-reality/main/ym.sh && chmod +x ym.sh

# 2. 首次运行：自动把自己安装为 ym 命令，并下载安装两个上游工具的最新版
./ym.sh

# 3. 以后直接：
ym            # 进菜单
ym scan 1.2.3.4        # 或者不进菜单，直接对一个 IP 跑完整流水线
```

菜单长这样：

```
------------------------------------------------------------
ym v1.0.0 — Reality 最佳目标域名一键查找
  RealiTLScanner: v0.2.3 ✓ 已是最新
  RealityChecker : v2.2.2  ->  🔔 有新版 v2.2.3,去菜单 7 更新
------------------------------------------------------------
  1) 一键找域名:输入 IP,全自动扫描 + 检测 + 给推荐
  2) 单域名检测(RealityChecker check)
  3) 对已有 CSV 检测(Scanner 的原始输出也行,自动归一化)
  4) 批量域名检测(手动输入多个域名)
  5) 历史结果
  6) 设置
  7) 版本管理(更新提醒 / 更新 / 回退)
  0) 退出
```

选 `1`，输入你服务器的 IP，等扫描 + 检测跑完，就会得到类似：

```
完成:候选 4 个,其中适合做 Reality 目标的 2 个
推荐域名(按检测通过顺序):
  1. smadex.com  (同段IP 44.203.158.152,地区 US,证书 Let's Encrypt)
  2. picnext.ai  (同段IP 44.203.156.12,地区 US,证书 Let's Encrypt)

首选可直接填(Xray Reality 服务端):
  "dest": "smadex.com:443",
  "serverNames": ["smadex.com"]
```

## 使用方法详解

### 目标可以填什么

菜单 1 / `ym scan` 的目标支持三种：

| 目标形式 | 示例 | 行为 |
|---|---|---|
| 单个 IP | `44.203.156.208` | RealiTLScanner 的单 IP 模式会从这个 IP 向两侧扩展、扫描邻域站点（上游称 infinity 模式，永不自己停），ym 按「扫描时长」设置（默认 90 秒）自动掐停并用已扫到的结果继续检测 |
| CIDR 网段 | `1.2.3.0/24` | 扫完整个段自动结束（同样受扫描时长上限保护） |
| 域名 | `example.com` | 先解析到它的 IP，再按单 IP 模式扫它所在的那一段 |

为什么总是围绕「IP 段」找域名：Reality 的 dest 域名最好是你服务器 IP **同段的真实站点**——客户端连的是你的服务器 IP、握手时带的却是这个域名的 SNI，同段才最像一次正常访问。所以最常见的用法就是在服务器上扫它自己的 IP。

### 菜单功能

- **1 一键找域名**：完整流水线（扫描 → 归一化 → 分片检测 → 推荐汇总），结果保存在结果目录（见下）。
- **2 单域名检测**：只测一个你已知的域名是否适合做 Reality 目标（走 RealityChecker `check`）。
- **3 对已有 CSV 检测**：你自己跑过 RealiTLScanner 得到的 CSV 直接拖进来；新版/旧版 Scanner 的 CSV 都认，ym 会先归一化再检测。
- **4 批量域名检测**：手动输入多个域名（空格分隔），走 RealityChecker `batch`。
- **5 历史结果**：历次扫描的结果目录列表，可回看当时的推荐清单。
- **6 设置**：见下表，保存在配置文件里，下次启动继续生效。
- **7 版本管理**：更新两个工具、或回退到任意历史版本；也在这里手动重新检查更新。

### 命令行子命令（不进菜单）

```bash
ym                          # 进菜单（同 ./ym.sh）
ym scan <IP> [扫描秒数]      # 一键流水线，如 ym scan 1.2.3.4 120
ym check <域名>             # 单域名检测
ym csv <文件>               # 对已有 CSV 检测
ym update [scanner|checker|all]   # 更新到最新版（执行前会征求确认）
ym rollback [scanner|checker] [版本]  # 回退/切换版本，不带版本号会列出可选版本
ym version                  # 查看两个工具的当前/最新版本
ym uninstall                # 卸载 ym 命令（工具与历史结果可选一并删）
```

脚本化调用时可用 `YM_YES=1` 跳过确认提示。

### 版本管理：更新提醒与回退

- **每次启动** ym 都会向 GitHub API 查询 RealiTLScanner 和 RealityChecker 的最新 Release，菜单顶部的版本行会显示 `✓ 已是最新` 或 `🔔 有新版 vX.Y.Z`。**它只提醒，绝不自动更新**，更新与否完全由你决定。
- 更新走菜单 7 或 `ym update`；每个版本独立存放在数据目录的 `tools/<工具>/<版本>/` 下，**已经下过的版本回退是秒切**；没下过的历史版本会先下载（或源码编译）并验活，**成功后才切换，失败不会破坏当前可用版本**。
- 回退时菜单 7 → 4/5 会列出上游全部 tag（新→旧），标明「当前」「已下载」；也可以直接 `ym rollback checker v2.2.2` 指定版本。
- 版本号以 ym 自己记录的状态为准：RealiTLScanner 本身没有 version 子命令，RealityChecker 自报的版本也可能是 `dev`，不能依赖。
- 两个上游的发行差异（ym 已自动处理，了解即可）：
  - RealiTLScanner 每个版本都有二进制，但文件名不同（v0.2.3 是 `RealiTLScanner-linux-amd64/arm64`，更早是 `RealiTLScanner-linux-64`）；ARM 机器回退老版本可能需要源码编译，ym 会自动处理。
  - RealityChecker **只有 v2.2.3 有官方二进制**，其余版本回退时 ym 会自动下载源码编译，需要 Go ≥ 1.21——机器上没有时 ym 会自动装官方 Go（直连 `go.dev` 失败时，编译依赖还会自动改走 `goproxy.cn` 重试）。

### 设置项（菜单 6）

| 设置 | 默认 | 说明 |
|---|---|---|
| `PORT` | 443 | 扫描端口（Reality 一般就是 443） |
| `THREAD` | 100 | 扫描并发线程 |
| `TIMEOUT` | 5 | 单个目标扫描超时（秒） |
| `SCAN_SECONDS` | 90 | 单 IP / 域名模式的扫描时长（秒），到时掐停并用已有结果继续 |
| `CHUNK` | 30 | 检测分片大小（个/片），见下文为什么要分片 |
| `MAX_DOMAINS` | 300 | 单次最多检测的候选域名数，超出的（离目标更远的）本次跳过，完整候选仍保存在结果目录 |

### 目录与结果文件

数据根目录：root 用户是 `/opt/ym`，普通用户是 `~/.ym`（可用环境变量 `YM_BASE` 覆盖）。

```
/opt/ym/
├── config                  # 设置
├── state/                  # 当前版本号、更新检查缓存
├── tools/
│   ├── scanner/<版本>/     # RealiTLScanner 各版本
│   └── checker/<版本>/     # RealityChecker 各版本（含它自己的 data/ 数据文件）
└── results/<日期>_<目标>/
    ├── scan.csv            # Scanner 原始扫描结果
    ├── normalized.csv      # 归一化后的候选清单
    ├── report_01.txt ...   # RealityChecker 每片的完整检测报告
    ├── suitable.txt        # 最终推荐清单（通过全部硬性条件的域名）
    └── summary.txt         # 本次小结
```

**挑域名时除了看 suitable.txt，还要看 report 里的表格**：通过硬性条件 ≠ 最推荐。优先选 **CDN 列为「-」、热门列为「-」** 的：用了 CDN 或太热门（如 apple、microsoft 这类）的站点虽然能用，但更容易被识别、稳定性也差；证书剩余天数越长、握手时间越短越好。

### 环境变量

| 变量 | 说明 |
|---|---|
| `YM_BASE` | 数据根目录（默认 root `/opt/ym`，普通用户 `~/.ym`） |
| `YM_YES=1` | 更新/回退时跳过确认提示 |
| `YM_NO_SELF_INSTALL=1` | 不把脚本自安装为 `ym` 命令 |
| `GITHUB_TOKEN` | 可选，提高 GitHub API 限额（未认证默认 60 次/小时，一般够用） |

## 工作原理与上游的坑（ym 已经替你绕开）

1. **两个工具的新版 CSV 格式互不兼容**。RealiTLScanner v0.2.0+ 输出 11 列、域名（`CERT_DOMAIN`）在第 9 列；而 RealityChecker 的 CSV 解析把**第 3 列硬编码**为域名字段（它对齐的是 Scanner 旧版 4~5 列格式）。新版 Scanner 的输出直接喂给 Checker，它会把 `TLS 1.3` 当成域名。ym 用 Python 的 `csv` 模块**按表头名**重新对齐列、生成 Checker 能正确读取的格式——注意证书签发者字段里带引号和逗号，用 `awk -F,` 粗暴切分会错位，网上流传的 awk 转换命令有这个隐患。
2. **单 IP 扫描永不自停**。RealiTLScanner 对单个 IP/域名自动启用 infinity 模式向两侧无限扩展，ym 用时长上限掐停并使用部分结果，这是预期行为不是卡死。
3. **RealityChecker 的数据文件是相对路径**。它按 `./data/` 找 `Country.mmdb`、`gfwlist.conf` 等，脱离它的目录运行就会报错或乱下载；ym 始终在它自己的版本目录里启动它，并把 GeoIP 库借给 Scanner 用（这样扫描结果才有地区列）。
4. **RealityChecker 批量检测有一个写死的 15 秒总计时**（其源码 `internal/batch/manager.go`）：候选一多，后面没测完的会被判「超时」。ym 把候选按 `CHUNK`（默认 30 个）分片、多次调用它来绕开，所以候选几百个也能测完。

## 环境要求

- Linux（Debian / Ubuntu / Alpine 等主流发行版均可），`bash` 环境
- 基础依赖：`curl`、`python3`、`unzip`、`tar`——缺失时 ym 会尝试用系统包管理器自动安装
- 架构：x86_64 与 ARM64 均可
- 仅在「回退到无二进制的历史版本」需要源码编译时才用到 Go，ym 会按需自动安装，无需预装

## 注意事项

- 上游作者建议扫描尽量在**本机或可信网络**进行。在云服务器上对大网段长时间扫描，可能被机房或目标网段视为扫描行为甚至触发滥用投诉；建议短时、小范围使用（默认 90 秒、从目标 IP 向两侧渐进扩展的节奏是相对温和的）。
- 扫别人 IP 段得到的域名只对那段 IP 的拥有者有意义——Reality 的 dest 要和**你自己服务器的 IP**同段才自然。
- 本工具仅用于为自有服务器挑选 Reality 目标域名等合法自用场景，请遵守当地法律法规与服务器提供商的条款。

## FAQ

- **扫不到任何候选？** 加大扫描时长（菜单 6 的 `SCAN_SECONDS`，或 `ym scan <IP> 180`）、加大线程，或换个时段重试；有些机房段本身就没什么 TLS 1.3 站点，可以试试扫同机房邻近的段。
- **候选很多、检测很慢？** 正常，检测是逐个真实握手。调小 `MAX_DOMAINS` 只测离目标最近的一批，或调大 `CHUNK`（但单片太大又会撞上游 15 秒计时，不建议超过 50）。
- **提示更新检查失败？** 多半是 GitHub API 不可达或未认证限额（60 次/小时）用完，稍后重试，或设置 `GITHUB_TOKEN` 环境变量；检查失败时菜单显示的是上次缓存结果，不影响使用。
- **回退失败了怎么办？** 放心，ym 是「先装好验活、再切换」，失败时当前版本原封不动；错误信息里会写明是下载失败还是编译失败。
- **RealityChecker 报数据文件下载失败？** 它首次运行要从 GitHub 拉 `Country.mmdb` 等 4 个数据文件，网络不通就会失败；恢复网络后重跑即可，文件在 `tools/checker/<版本>/data/`，超过 3 天它会自己尝试更新。

## 卸载

```bash
ym uninstall
```

会移除 `ym` 命令，并询问是否一并删除数据目录（含全部工具版本与历史结果）。

## 致谢与许可

- 上游项目：[XTLS/RealiTLScanner](https://github.com/XTLS/RealiTLScanner)（MPL-2.0）、[V2RaySSR/RealityChecker](https://github.com/V2RaySSR/RealityChecker)，以及它们依赖的 Loyalsoldier/geoip、clash-rules 数据。ym 只是在运行时从 GitHub 下载它们的官方发行版/源码，不打包、不修改其代码，各自遵循其仓库内的许可。
- 本脚本（`ym.sh` 与本 README）以 MIT 许可发布，见 [LICENSE](LICENSE)。
