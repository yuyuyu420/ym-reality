#!/usr/bin/env bash
# =============================================================================
# ym — Reality 最佳目标域名一键查找
#
# 流水线(两个上游项目串联):
#   1) XTLS/RealiTLScanner   扫描目标 IP 邻域的 TLS 站点,导出 CSV
#      https://github.com/XTLS/RealiTLScanner
#   2) 本脚本归一化 CSV(见下方注释,两个项目的新版 CSV 格式并不兼容,必须转)
#   3) V2RaySSR/RealityChecker  对候选域名做 TLS1.3/X25519/H2/SNI/证书/CDN/
#      热门/被墙/地理位置深度检测,给出适合做 Reality 目标的域名
#      https://github.com/V2RaySSR/RealityChecker
#
# 用法:
#   ym                 进入菜单(首次运行自动安装两个工具的最新版)
#   ym scan <IP> [秒]  非交互:直接对 IP 跑完整流水线
#   ym check <域名>    非交互:单域名检测
#   ym csv <文件>      非交互:对已有 CSV(Scanner 原始输出或归一化文件)检测
#   ym update [scanner|checker|all]   更新到最新版(会先征求确认)
#   ym rollback [scanner|checker] [版本]  回退到指定历史版本
#   ym version         查看当前/最新版本
#   ym uninstall       卸载 ym 命令(工具与结果目录可选一并删除)
#
# 版本管理设计:
#   - 每次启动都向 GitHub API 查询两个项目的最新 Release,有新版在菜单顶部提醒,
#     是否更新由使用者决定(菜单 7 或 ym update),绝不自动更新。
#   - 每个版本独立存放在 $YM_BASE/tools/<项目>/<版本>/,切换当前版本只是改指向,
#     因此回退到用过的版本是秒切;没下过的历史版本会现场下载/编译,装好验活后才切换,
#     失败不会破坏当前可用版本。
#   - 版本号以脚本自己记录的 state 文件为准:RealiTLScanner 本身没有 version 子命令,
#     RealityChecker 发行版的 version 输出也可能是 dev,不能依赖。
#
# 已知的上游坑(脚本已绕开,勿删相关逻辑):
#   - RealiTLScanner v0.2.0+ 的 CSV 是 11 列,CERT_DOMAIN 在第 9 列;
#     v0.1.x 及 RealityChecker 自带 file.csv 是 4~5 列,CERT_DOMAIN 在第 3 列。
#     而 RealityChecker 的 csv.go 把第 3 列硬编码为 CERT_DOMAIN —— 新版 Scanner
#     的输出直接喂给它,会把 "TLS 1.3" 当域名。所以必须先按表头名归一化。
#     归一化用 python3 的 csv 模块解析(证书签发者字段带引号逗号,awk 按逗号切会错位)。
#   - RealiTLScanner 对单个 IP 会自动进入 infinity 模式(从该 IP 向两侧无限扩展扫描,
#     永不自己结束),脚本必须按时长掐停并使用已产出的部分结果。
#   - RealityChecker 按相对路径 ./data/ 找数据文件(Country.mmdb 等),运行它时
#     必须 cd 到它所在的版本目录,否则数据文件检查会失败/乱下载。
#   - RealityChecker 的批量检测内部有一个 15 秒总计时(源码 batch/manager.go 写死),
#     候选太多时后面的会被判"超时"。脚本把候选按片(默认 30 个)分开多次调用它绕开。
#   - RealityChecker 只有 v2.2.3 一个 Release 带二进制资产,其余 tag 均无资产,
#     回退到这些版本只能源码编译(需要 Go >= 1.21,脚本会按需自动装)。
#     RealiTLScanner 各版都有资产,但资产名不一致:
#       v0.2.3: RealiTLScanner-linux-amd64 / -linux-arm64
#       更早:   RealiTLScanner-linux-64 (仅 amd64,ARM 需源码编译)
#   - RealityChecker 的 check/batch/csv 每次启动会先检查 data/ 文件、
#     超过 3 天的会尝试联网更新;离线环境可能变慢,属上游行为。
#
# 环境变量:
#   YM_BASE          数据根目录(默认:root 用 /opt/ym,普通用户 ~/.ym)
#   YM_NO_SELF_INSTALL=1  不把自身安装为 ym 命令
#   GITHUB_TOKEN     可选,提高 GitHub API 限额(未认证为 60 次/小时)
# =============================================================================

YM_VERSION="1.0.0"
SCANNER_REPO="XTLS/RealiTLScanner"
CHECKER_REPO="V2RaySSR/RealityChecker"
SCANNER_NAME="RealiTLScanner"
CHECKER_NAME="reality-checker"

# ---------- 基础路径 ----------
if [ -n "${YM_BASE:-}" ]; then
    BASE="$YM_BASE"
elif [ "$(id -u)" = "0" ]; then
    BASE="/opt/ym"
else
    BASE="$HOME/.ym"
fi
TOOLS_DIR="$BASE/tools"
STATE_DIR="$BASE/state"
RESULTS_DIR="$BASE/results"
CONFIG_FILE="$BASE/config"
mkdir -p "$TOOLS_DIR/scanner" "$TOOLS_DIR/checker" "$STATE_DIR" "$RESULTS_DIR"

# ---------- 颜色/输出 ----------
if [ -t 1 ]; then
    C_R='\033[0;31m'; C_G='\033[0;32m'; C_Y='\033[1;33m'; C_B='\033[0;34m'; C_N='\033[0m'
else
    C_R=''; C_G=''; C_Y=''; C_B=''; C_N=''
fi
info()  { printf '%b\n' "$*"; }
ok()    { printf '%b\n' "${C_G}$*${C_N}"; }
warn()  { printf '%b\n' "${C_Y}$*${C_N}"; }
err()   { printf '%b\n' "${C_R}$*${C_N}" >&2; }
hr()    { printf '%s\n' "------------------------------------------------------------"; }

# ---------- 配置(可持久化) ----------
PORT=443; THREAD=100; TIMEOUT=5; SCAN_SECONDS=90; CHUNK=30; MAX_DOMAINS=300
[ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE" 2>/dev/null
save_config() {
    cat > "$CONFIG_FILE" <<EOF
PORT=$PORT
THREAD=$THREAD
TIMEOUT=$TIMEOUT
SCAN_SECONDS=$SCAN_SECONDS
CHUNK=$CHUNK
MAX_DOMAINS=$MAX_DOMAINS
EOF
}

# ---------- 依赖 ----------
have() { command -v "$1" >/dev/null 2>&1; }

pkg_install() { # pkg_install <包名...>
    if have apt-get; then
        DEBIAN_FRONTEND=noninteractive apt-get update -qq 2>/dev/null
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@" >/dev/null 2>&1
    elif have apk; then
        apk add --no-cache "$@" >/dev/null 2>&1
    elif have dnf; then
        dnf install -y -q "$@" >/dev/null 2>&1
    elif have yum; then
        yum install -y -q "$@" >/dev/null 2>&1
    else
        return 1
    fi
}

ensure_deps() {
    local miss=()
    have curl    || miss+=(curl)
    have python3 || miss+=(python3)
    have unzip   || miss+=(unzip)
    have tar     || miss+=(tar)
    if [ "${#miss[@]}" -gt 0 ]; then
        info "正在安装基础依赖: ${miss[*]}"
        if have apk; then
            # Alpine 包名映射
            local mapped=() m
            for m in "${miss[@]}"; do
                case "$m" in
                    python3) mapped+=(python3);;
                    unzip)   mapped+=(unzip);;
                    tar)     mapped+=(tar);;
                    *)       mapped+=("$m");;
                esac
            done
            pkg_install "${mapped[@]}"
        else
            pkg_install "${miss[@]}"
        fi
    fi
    have curl    || { err "缺少 curl 且自动安装失败,请手动安装后重试"; return 1; }
    have python3 || { err "缺少 python3 且自动安装失败(归一化 CSV 需要它),请手动安装后重试"; return 1; }
    return 0
}

# Go 仅在源码编译时需要(RealityChecker 历史版本回退 / Scanner 的 ARM 旧版)
go_ok() {
    have go || return 1
    local v
    v=$(go version 2>/dev/null | sed -n 's/.*go\([0-9][0-9]*\)\.\([0-9][0-9]*\).*/\1 \2/p')
    [ -n "$v" ] || return 1
    local maj min
    maj=${v%% *}; min=${v##* }
    [ "$maj" -gt 1 ] || { [ "$maj" = "1" ] && [ "$min" -ge 21 ]; }
}
ensure_go() {
    go_ok && return 0
    info "源码编译需要 Go >= 1.21,正在自动安装官方 Go ..."
    local goarch file ver
    case "$(uname -m)" in
        x86_64|amd64)  goarch="amd64";;
        aarch64|arm64) goarch="arm64";;
        *) err "不支持的架构 $(uname -m),无法自动装 Go"; return 1;;
    esac
    ver=$(curl -fsSL --max-time 15 "https://go.dev/dl/?mode=json" 2>/dev/null \
        | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d[0]["version"])' 2>/dev/null)
    [ -n "$ver" ] || ver="go1.23.4"
    file="${ver}.linux-${goarch}.tar.gz"
    local tmpd; tmpd=$(mktemp -d)
    if ! curl -fL --max-time 300 -o "$tmpd/go.tgz" "https://go.dev/dl/$file"; then
        rm -rf "$tmpd"; err "下载 Go 失败: https://go.dev/dl/$file"; return 1
    fi
    if [ "$(id -u)" = "0" ]; then
        rm -rf /usr/local/go
        tar -C /usr/local -xzf "$tmpd/go.tgz" || { rm -rf "$tmpd"; return 1; }
        ln -sf /usr/local/go/bin/go /usr/local/bin/go
        ln -sf /usr/local/go/bin/gofmt /usr/local/bin/gofmt 2>/dev/null
    else
        rm -rf "$BASE/go"
        mkdir -p "$BASE"
        tar -C "$BASE" -xzf "$tmpd/go.tgz" || { rm -rf "$tmpd"; return 1; }
        export PATH="$BASE/go/bin:$PATH"
    fi
    rm -rf "$tmpd"
    go_ok && { ok "Go 已就绪: $(go version)"; return 0; }
    # 包管理器兜底
    pkg_install golang-go 2>/dev/null || pkg_install go 2>/dev/null
    go_ok
}

# ---------- 架构 ----------
arch_std() { # amd64 / arm64
    case "$(uname -m)" in
        x86_64|amd64)  echo "amd64";;
        aarch64|arm64) echo "arm64";;
        *) echo "$(uname -m)";;
    esac
}

# ---------- GitHub API ----------
API="https://api.github.com"
api_get() { # api_get <path> ;失败返回非 0 且无输出
    local auth=()
    [ -n "${GITHUB_TOKEN:-}" ] && auth=(-H "Authorization: Bearer $GITHUB_TOKEN")
    curl -fsSL --max-time 20 -H "Accept: application/vnd.github+json" \
         -H "User-Agent: ym-script/$YM_VERSION" "${auth[@]}" "$API$1" 2>/dev/null
}
py() { python3 -c "$1"; }

latest_tag() { # latest_tag <repo> -> tag 或空
    local repo="$1" out
    out=$(api_get "/repos/$repo/releases/latest") || out=""
    if [ -n "$out" ]; then
        printf '%s' "$out" | py 'import sys,json; print(json.load(sys.stdin).get("tag_name",""))' 2>/dev/null
        return 0
    fi
    # 没有 Release 时退回 tags 第一名
    out=$(api_get "/repos/$repo/tags?per_page=5") || return 1
    printf '%s' "$out" | py 'import sys,json; d=json.load(sys.stdin); print(d[0]["name"] if d else "")' 2>/dev/null
}

list_tags() { # list_tags <repo> -> 每行一个 tag,新到旧
    local out
    out=$(api_get "/repos/$1/tags?per_page=30") || return 1
    printf '%s' "$out" | py 'import sys,json; [print(t["name"]) for t in json.load(sys.stdin)]' 2>/dev/null
}

release_assets() { # release_assets <repo> <tag> -> "资产名 下载URL" 每行一个;无 Release 时无输出
    local out
    out=$(api_get "/repos/$1/releases/tags/$2") || return 0
    printf '%s' "$out" | py 'import sys,json
for a in json.load(sys.stdin).get("assets",[]):
    print(a["name"], a["browser_download_url"])' 2>/dev/null
}

# ---------- 版本状态 ----------
cur_version() { # cur_version <scanner|checker>
    local f="$STATE_DIR/$1.version"
    [ -f "$f" ] && tr -d ' \n' < "$f" || echo ""
}
set_current() { # set_current <scanner|checker> <tag>
    printf '%s\n' "$2" > "$STATE_DIR/$1.version"
    ln -sfn "$TOOLS_DIR/$1/$2" "$TOOLS_DIR/$1/current"
}
tool_dir()  { echo "$TOOLS_DIR/$1/$(cur_version "$1")"; }
scanner_bin() { echo "$TOOLS_DIR/scanner/$(cur_version scanner)/$SCANNER_NAME"; }
checker_bin() { echo "$TOOLS_DIR/checker/$(cur_version checker)/$CHECKER_NAME"; }
tool_installed() { # tool_installed <scanner|checker>
    local b
    case "$1" in
        scanner) b=$(scanner_bin);;
        checker) b=$(checker_bin);;
    esac
    [ -n "$(cur_version "$1")" ] && [ -x "$b" ]
}

# 更新检查结果(全局变量,check_updates 填充)
LATEST_SCANNER=""; LATEST_CHECKER=""; UPDATE_CHECK_OK=0; UPDATE_CHECK_AT=""
check_updates() {
    UPDATE_CHECK_OK=0
    local s c
    s=$(latest_tag "$SCANNER_REPO"); [ -n "$s" ] && LATEST_SCANNER="$s"
    c=$(latest_tag "$CHECKER_REPO"); [ -n "$c" ] && LATEST_CHECKER="$c"
    if [ -n "$LATEST_SCANNER" ] && [ -n "$LATEST_CHECKER" ]; then
        UPDATE_CHECK_OK=1
        UPDATE_CHECK_AT=$(date '+%H:%M:%S')
        cat > "$STATE_DIR/update.cache" <<EOF
LATEST_SCANNER=$LATEST_SCANNER
LATEST_CHECKER=$LATEST_CHECKER
CHECKED_AT="$(date '+%Y-%m-%d %H:%M:%S')"
EOF
    elif [ -f "$STATE_DIR/update.cache" ]; then
        . "$STATE_DIR/update.cache" 2>/dev/null
        UPDATE_CHECK_AT="${CHECKED_AT:-离线缓存}"
    fi
}
has_update() { # has_update <scanner|checker> -> 0 有新版
    local cur lat
    cur=$(cur_version "$1")
    case "$1" in
        scanner) lat="$LATEST_SCANNER";;
        checker) lat="$LATEST_CHECKER";;
    esac
    [ -n "$cur" ] && [ -n "$lat" ] && [ "$cur" != "$lat" ]
}

# ---------- 下载/编译单个版本 ----------
download() { # download <url> <dest>
    curl -fL --retry 2 --max-time 600 -o "$2" "$1" 2>/dev/null \
     || wget -q -O "$2" "$1"
}

build_from_source() { # build_from_source <repo> <tag> <proj> <destdir>
    local repo="$1" tag="$2" proj="$3" dest="$4"
    ensure_go || { err "没有可用的 Go,无法源码编译 $proj $tag"; return 1; }
    local tmpd; tmpd=$(mktemp -d)
    info "下载源码 $repo@$tag ..."
    if ! download "https://github.com/$repo/archive/refs/tags/$tag.tar.gz" "$tmpd/src.tgz"; then
        rm -rf "$tmpd"; err "源码下载失败"; return 1
    fi
    tar -xzf "$tmpd/src.tgz" -C "$tmpd" || { rm -rf "$tmpd"; return 1; }
    local srcd
    srcd=$(find "$tmpd" -maxdepth 1 -type d -name '*-*' | head -1)
    [ -n "$srcd" ] || { rm -rf "$tmpd"; err "源码包结构异常"; return 1; }
    info "编译中(首次编译需下载 Go 依赖,请稍候)..."
    local ldflags=""
    if [ "$proj" = "checker" ]; then
        ldflags="-X RealityChecker/internal/version.Version=$tag -X RealityChecker/internal/version.BuildTime=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    fi
    if ! ( cd "$srcd" && GOFLAGS=-mod=mod go build -trimpath -ldflags "$ldflags" -o "$dest.tmp-bin" . ); then
        info "默认 Go 代理拉依赖失败,改用 goproxy.cn 重试 ..."
        ( cd "$srcd" && GOFLAGS=-mod=mod GOPROXY="https://goproxy.cn,direct" GOSUMDB=off \
            go build -trimpath -ldflags "$ldflags" -o "$dest.tmp-bin" . ) \
            || { rm -rf "$tmpd"; err "编译失败"; return 1; }
    fi
    mkdir -p "$dest"
    mv "$dest.tmp-bin" "$dest/$([ "$proj" = scanner ] && echo "$SCANNER_NAME" || echo "$CHECKER_NAME")"
    chmod +x "$dest/$([ "$proj" = scanner ] && echo "$SCANNER_NAME" || echo "$CHECKER_NAME")"
    # 源码包自带 data/ 的话一并带过去(checker 运行时需要)
    if [ "$proj" = "checker" ] && [ -d "$srcd/data" ]; then
        mkdir -p "$dest/data"
        cp -f "$srcd/data/"* "$dest/data/" 2>/dev/null
    fi
    rm -rf "$tmpd"
    return 0
}

verify_scanner() { # verify_scanner <bin>
    [ -x "$1" ] || return 1
    local out
    out=$(timeout 10 "$1" 2>&1 | head -5)
    printf '%s' "$out" | grep -qi 'addr\|usage\|specify'
}
verify_checker() { # verify_checker <dir> ;在该目录内跑 version(data/ 为相对路径,必须 cd 进去)
    local dir="$1" rc
    [ -x "$dir/$CHECKER_NAME" ] || return 1
    ( cd "$dir" && timeout 120 "./$CHECKER_NAME" version >/dev/null 2>&1 )
    rc=$?
    # 126/127=无法执行(架构不对/文件损坏),132=非法指令;其余(含数据文件下载失败的 1)
    # 都说明二进制本身能跑,不因网络问题误杀
    if [ "$rc" = 126 ] || [ "$rc" = 127 ] || [ "$rc" = 132 ]; then
        return 1
    fi
    return 0
}

install_tool() { # install_tool <scanner|checker> <tag> ;成功后自动切换为当前版本
    local proj="$1" tag="$2" repo bin_name arch dest
    case "$proj" in
        scanner) repo="$SCANNER_REPO"; bin_name="$SCANNER_NAME";;
        checker) repo="$CHECKER_REPO"; bin_name="$CHECKER_NAME";;
    esac
    arch=$(arch_std)
    dest="$TOOLS_DIR/$proj/$tag"
    if [ -x "$dest/$bin_name" ]; then
        info "$proj $tag 已在本地,直接切换"
        set_current "$proj" "$tag"
        return 0
    fi
    mkdir -p "$dest"
    local tmpd; tmpd=$(mktemp -d)
    local got=0 assets name url want1 want2
    assets=$(release_assets "$repo" "$tag")
    if [ -n "$assets" ]; then
        # 按架构挑资产:先精确名,再历史名
        if [ "$proj" = scanner ]; then
            want1="$SCANNER_NAME-linux-$arch"; want2="$SCANNER_NAME-linux-64"
        else
            want1="$CHECKER_NAME-linux-$arch.zip"; want2=""
        fi
        while read -r name url; do
            [ "$name" = "$want1" ] || { [ -n "$want2" ] && [ "$name" = "$want2" ] && [ "$arch" = amd64 ]; } || continue
            info "下载 $name ($tag) ..."
            if download "$url" "$tmpd/pkg"; then
                case "$name" in
                    *.zip)
                        if have unzip; then unzip -o -q "$tmpd/pkg" -d "$tmpd/unzip"
                        else python3 -m zipfile -e "$tmpd/pkg" "$tmpd/unzip"; fi
                        local f
                        f=$(find "$tmpd/unzip" -type f -name "$bin_name" | head -1)
                        [ -n "$f" ] && cp "$f" "$dest/$bin_name"
                        # zip 里若带 data/ 一并保留
                        if [ -d "$tmpd/unzip/data" ]; then mkdir -p "$dest/data"; cp -f "$tmpd/unzip/data/"* "$dest/data/" 2>/dev/null; fi
                        ;;
                    *) cp "$tmpd/pkg" "$dest/$bin_name";;
                esac
                chmod +x "$dest/$bin_name" 2>/dev/null
                [ -x "$dest/$bin_name" ] && got=1
            fi
            break
        done <<EOF
$assets
EOF
    fi
    if [ "$got" = 0 ]; then
        if [ -n "$assets" ] || api_get "/repos/$repo/releases/tags/$tag" >/dev/null 2>&1; then
            info "该版本没有适配本机架构($(arch_std))的发行二进制,改走源码编译"
        else
            info "该版本没有 GitHub Release(或无二进制资产),改走源码编译"
        fi
        rm -rf "$tmpd"
        build_from_source "$repo" "$tag" "$proj" "$dest" || { err "$proj $tag 安装失败,当前版本保持不变"; return 1; }
    else
        rm -rf "$tmpd"
    fi
    # checker:把旧版本已下好的 data/ 搬过来,避免每次切换都重新下载数据文件
    if [ "$proj" = checker ]; then
        local old; old=$(cur_version checker)
        if [ -n "$old" ] && [ "$old" != "$tag" ] && [ -d "$TOOLS_DIR/checker/$old/data" ]; then
            mkdir -p "$dest/data"
            cp -fn "$TOOLS_DIR/checker/$old/data/"* "$dest/data/" 2>/dev/null
        fi
    fi
    # 验活:验不过不切换
    if [ "$proj" = scanner ]; then
        verify_scanner "$dest/$bin_name" || { err "$proj $tag 验活失败(二进制无法正常运行),已保留在 $dest 但不切换"; return 1; }
    else
        verify_checker "$dest" || warn "$proj $tag 验活未完全通过(可能因数据文件需联网下载),仍切换,请留意首次检测输出"
    fi
    set_current "$proj" "$tag"
    ok "$proj 已切换到 $tag"
    return 0
}

ensure_tools() { # 首次运行:两个工具都没装好时装最新版
    local need=0
    tool_installed scanner || need=1
    tool_installed checker || need=1
    [ "$need" = 0 ] && return 0
    info "首次运行:正在安装两个上游工具的最新版 ..."
    [ -z "$LATEST_SCANNER" ] && LATEST_SCANNER=$(latest_tag "$SCANNER_REPO")
    [ -z "$LATEST_CHECKER" ] && LATEST_CHECKER=$(latest_tag "$CHECKER_REPO")
    if ! tool_installed scanner; then
        [ -n "$LATEST_SCANNER" ] && install_tool scanner "$LATEST_SCANNER" \
            || err "RealiTLScanner 安装失败(网络?),可稍后在菜单 7 重试"
    fi
    if ! tool_installed checker; then
        [ -n "$LATEST_CHECKER" ] && install_tool checker "$LATEST_CHECKER" \
            || err "RealityChecker 安装失败(网络?),可稍后在菜单 7 重试"
    fi
}

# ---------- 自我安装为 ym 命令 ----------
self_install() {
    [ "${YM_NO_SELF_INSTALL:-0}" = "1" ] && return 0
    local self target
    self=$(readlink -f "$0" 2>/dev/null || echo "$0")
    if [ "$(id -u)" = "0" ]; then target="/usr/local/bin/ym"; else target="$HOME/.local/bin/ym"; fi
    mkdir -p "$(dirname "$target")"
    if [ "$self" != "$(readlink -f "$target" 2>/dev/null)" ]; then
        cp -f "$self" "$target" 2>/dev/null && chmod +x "$target" 2>/dev/null \
            && info "已安装命令: 输入 ym 即可进入菜单(路径 $target)"
    fi
}

# ---------- CSV 归一化(核心兼容层) ----------
# 按表头名定位 CERT_DOMAIN 等列,兼容 Scanner 新版 11 列 / 旧版 4~5 列 /
# Medium 流传的 IP,Port,Domain 三列 / 纯域名清单。输出 RealityChecker 能正确
# 读取的老格式(域名必须在第 3 列):IP,ORIGIN,CERT_DOMAIN,CERT_ISSUER,GEO_CODE
# 成功时 stdout 只输出去重后的域名数量;失败返回非 0。
normalize_csv() { # normalize_csv <输入> <输出>
    python3 - "$1" "$2" <<'PYEOF'
import csv, sys
src, dst = sys.argv[1], sys.argv[2]
try:
    f = open(src, newline='', encoding='utf-8', errors='replace')
except OSError as e:
    print(f"无法打开 {src}: {e}", file=sys.stderr); sys.exit(1)
rows = list(csv.reader(f)); f.close()
if not rows:
    print("CSV 为空", file=sys.stderr); sys.exit(1)

def find(header, name):
    for i, h in enumerate(header):
        if h.strip().strip('"').upper() == name:
            return i
    return -1

header = [h.strip().strip('"').upper() for h in rows[0]]
has_header = header and header[0] == 'IP'
if has_header:
    di = find(header, 'CERT_DOMAIN')
    ii = find(header, 'IP'); oi = find(header, 'ORIGIN')
    si = find(header, 'CERT_ISSUER'); gi = find(header, 'GEO_CODE')
    if di < 0:  # IP,Port,Domain 三列式
        di = 2 if len(header) >= 3 else -1
    data = rows[1:]
else:
    di, ii, oi, si, gi = -1, 0, 1, -1, -1
    data = rows

seen, out = set(), []
for r in data:
    if not r or all(not c.strip() for c in r):
        continue
    d = -1
    if di >= 0 and len(r) > di:
        d = di
    elif len(r) >= 11: d = 8   # 新版 11 列无表头兜底
    elif len(r) >= 3:  d = 2   # 旧版/三列式兜底
    elif len(r) == 1:  d = 0   # 纯域名清单
    if d < 0:
        continue
    dom = r[d].strip().strip('"').strip()
    if not dom or dom.upper() in ('CERT_DOMAIN', 'DOMAIN'):
        continue
    key = dom.lower()
    if key in seen:
        continue
    seen.add(key)
    def col(i):
        return r[i].strip().strip('"') if 0 <= i < len(r) else ''
    out.append([col(ii) if ii >= 0 else '', col(oi) if oi >= 0 else col(ii) if ii >= 0 else '',
                dom, col(si) if si >= 0 else '', col(gi) if gi >= 0 else ''])
with open(dst, 'w', newline='', encoding='utf-8') as f:
    w = csv.writer(f)
    w.writerow(['IP', 'ORIGIN', 'CERT_DOMAIN', 'CERT_ISSUER', 'GEO_CODE'])
    w.writerows(out)
print(len(out))
PYEOF
}

split_chunks() { # split_chunks <normalized.csv> <chunkdir> ;输出分片文件路径(每行一个)
    python3 - "$1" "$2" "$CHUNK" <<'PYEOF'
import csv, os, sys
src, cdir, size = sys.argv[1], sys.argv[2], int(sys.argv[3])
rows = list(csv.reader(open(src, newline='', encoding='utf-8', errors='replace')))
header, data = rows[0], rows[1:]
os.makedirs(cdir, exist_ok=True)
for n in range(0, len(data), size):
    p = os.path.join(cdir, f"chunk_{n // size + 1:02d}.csv")
    with open(p, 'w', newline='', encoding='utf-8') as f:
        w = csv.writer(f); w.writerow(header); w.writerows(data[n:n + size])
    print(p)
PYEOF
}

# ---------- 带时长上限地运行(Scanner infinity 模式必须掐停) ----------
SCAN_PID=""; SCAN_STOP=0
run_scan_timed() { # run_scan_timed <秒> <rundir> <scanner参数...>
    local secs="$1" rundir="$2"; shift 2
    local sbin; sbin=$(scanner_bin)
    SCAN_STOP=0
    ( cd "$rundir" && exec "$sbin" "$@" ) &
    SCAN_PID=$!
    trap 'SCAN_STOP=1' INT
    local el=0
    while kill -0 "$SCAN_PID" 2>/dev/null; do
        sleep 1; el=$((el + 1))
        if [ "$SCAN_STOP" = 1 ]; then
            info "收到中断,停止扫描并转入检测阶段 ..."
            kill -TERM "$SCAN_PID" 2>/dev/null; sleep 2; kill -KILL "$SCAN_PID" 2>/dev/null
            break
        fi
        if [ "$secs" -gt 0 ] && [ "$el" -ge "$secs" ]; then
            kill -TERM "$SCAN_PID" 2>/dev/null; sleep 2; kill -KILL "$SCAN_PID" 2>/dev/null
            break
        fi
        if [ $((el % 15)) -eq 0 ]; then
            local n=0
            [ -f "$rundir/scan.csv" ] && n=$(( $(wc -l < "$rundir/scan.csv") - 1 ))
            [ "$n" -lt 0 ] && n=0
            info "  ...已扫描 ${el}s / ${secs}s,已发现可行目标 $n 条"
        fi
    done
    wait "$SCAN_PID" 2>/dev/null
    trap - INT
}

# ---------- RealityChecker 调用 ----------
run_checker_csv() { # run_checker_csv <normalized.csv> <rundir> ;产出 $rundir/suitable.txt
    local norm="$1" rundir="$2"
    local cdir; cdir=$(tool_dir checker)
    local chunks; chunks=$(split_chunks "$norm" "$rundir/chunks")
    local total; total=$(printf '%s\n' "$chunks" | grep -c .)
    : > "$rundir/suitable.txt"
    local i=0 chunk report
    for chunk in $chunks; do
        i=$((i + 1))
        report="$rundir/report_$(printf '%02d' "$i").txt"
        info "检测分片 $i/$total ($(($(wc -l < "$chunk") - 1)) 个域名)..."
        ( cd "$cdir" && timeout 300 "./$CHECKER_NAME" csv "$chunk" ) > "$report" 2>&1
        cat "$report"
        # 从进度行提取"适合"的域名(行尾为"适合"且不含"不适合")
        python3 - "$report" >> "$rundir/suitable.txt" <<'PYEOF'
import re, sys
pat = re.compile(r'正在检测 \[\d+/\d+\]:\s*(\S+?)\.\.\.\s*适合\s*$')
seen = set()
for line in open(sys.argv[1], encoding='utf-8', errors='replace'):
    m = pat.search(line.rstrip('\n'))
    if m and m.group(1) not in seen:
        seen.add(m.group(1)); print(m.group(1))
PYEOF
    done
    # 跨分片去重保序
    python3 - "$rundir/suitable.txt" <<'PYEOF'
import sys
p = sys.argv[1]
seen, out = set(), []
for line in open(p, encoding='utf-8', errors='replace'):
    d = line.strip()
    if d and d.lower() not in seen:
        seen.add(d.lower()); out.append(d)
open(p, 'w', encoding='utf-8').write('\n'.join(out) + ('\n' if out else ''))
PYEOF
}

run_checker_single() { # run_checker_single <域名>
    local cdir; cdir=$(tool_dir checker)
    ( cd "$cdir" && "./$CHECKER_NAME" check "$1" )
}
run_checker_batch() { # run_checker_batch <域名...>
    local cdir; cdir=$(tool_dir checker)
    ( cd "$cdir" && "./$CHECKER_NAME" batch "$@" )
}

# ---------- 结果汇总 ----------
show_summary() { # show_summary <rundir> <target>
    local rundir="$1" target="$2"
    local total=0 suit=0
    [ -f "$rundir/normalized.csv" ] && total=$(( $(wc -l < "$rundir/normalized.csv") - 1 ))
    [ -f "$rundir/suitable.txt" ] && suit=$(grep -c . "$rundir/suitable.txt" || true)
    {
        echo "目标: $target"
        echo "时间: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "工具: RealiTLScanner $(cur_version scanner) / RealityChecker $(cur_version checker)"
        echo "候选域名: $total 个,适合做 Reality 目标: $suit 个"
    } > "$rundir/summary.txt"
    hr
    ok "完成:候选 $total 个,其中适合做 Reality 目标的 $suit 个"
    if [ "$suit" -gt 0 ]; then
        info "推荐域名(按检测通过顺序,越靠前越早通过全部硬性条件):"
        python3 - "$rundir/normalized.csv" "$rundir/suitable.txt" <<'PYEOF'
import csv, sys
info = {}
for r in csv.reader(open(sys.argv[1], newline='', encoding='utf-8', errors='replace')):
    if len(r) >= 5 and r[2] != 'CERT_DOMAIN':
        info.setdefault(r[2].lower(), r)
doms = [l.strip() for l in open(sys.argv[2], encoding='utf-8', errors='replace') if l.strip()]
for i, d in enumerate(doms, 1):
    r = info.get(d.lower())
    extra = f"  (同段IP {r[0]},地区 {r[4] or '?'},证书 {r[3] or '?'})" if r else ""
    print(f"  {i}. {d}{extra}")
if doms:
    d = doms[0]
    print()
    print("首选可直接填(Xray Reality 服务端):")
    print(f'  "dest": "{d}:443",')
    print(f'  "serverNames": ["{d}"]')
    print("注意:最终挑选请结合检测报告里的 CDN/热门 列 —— 无 CDN、非热门的更稳,")
    print("      热门站(如 apple/microsoft)与 CDN 站虽通过硬性条件但不推荐长期用。")
PYEOF
    else
        warn "本轮没有域名通过全部硬性条件。可以:加大扫描时长、换个 IP/时段重试,"
        warn "或在菜单 3 用已保存的 normalized.csv 单独重跑检测。完整报告见结果目录。"
    fi
    info "结果目录: $rundir"
    info "  scan.csv 原始扫描 | normalized.csv 归一化候选 | report_*.txt 检测报告 | suitable.txt 推荐清单"
    hr
}

# ---------- 主流水线 ----------
valid_target() {
    printf '%s' "$1" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$|^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$'
}

do_pipeline() { # do_pipeline <target> [扫描秒数]
    local target="$1" secs="${2:-$SCAN_SECONDS}"
    tool_installed scanner || { err "RealiTLScanner 未安装好,先到菜单 7 处理"; return 1; }
    tool_installed checker || { err "RealityChecker 未安装好,先到菜单 7 处理"; return 1; }
    valid_target "$target" || { err "目标格式不对:请输入 IPv4、CIDR(如 1.2.3.0/24)或域名"; return 1; }
    local stamp safe rundir
    stamp=$(date '+%Y%m%d-%H%M%S')
    safe=$(printf '%s' "$target" | sed 's#[^A-Za-z0-9.-]#_#g')
    rundir="$RESULTS_DIR/${stamp}_${safe}"
    mkdir -p "$rundir"
    # GeoIP 库借给 Scanner 用(输出 GEO_CODE 列);Checker 的 data/ 里有现成的
    local mmdb; mmdb="$(tool_dir checker)/data/Country.mmdb"
    [ -f "$mmdb" ] && cp -f "$mmdb" "$rundir/Country.mmdb"
    hr
    info "第 1 步:RealiTLScanner $(cur_version scanner) 扫描 $target (端口 $PORT,线程 $THREAD,单目标超时 ${TIMEOUT}s)"
    case "$target" in
        */*) info "CIDR 模式:扫完该段自动结束,同时受 ${secs}s 上限保护" ;;
        *.*.*.*) warn "单 IP 会进入 infinity 模式(从该 IP 向两侧扩展找同段站点),${secs}s 后自动掐停并用已扫到的结果继续 —— 这是预期行为" ;;
        *) info "域名模式同样为 infinity 扫描,${secs}s 后掐停" ;;
    esac
    warn "提示:上游建议扫描尽量在本机/可信网络跑;在 VPS 上跑可能被机房或目标段视为扫描行为。"
    run_scan_timed "$secs" "$rundir" -addr "$target" -port "$PORT" -thread "$THREAD" -timeout "$TIMEOUT" -out scan.csv
    if [ ! -f "$rundir/scan.csv" ] || [ "$(wc -l < "$rundir/scan.csv")" -le 1 ]; then
        err "没有扫到可行目标(TLS1.3+H2 的站点)。可加大扫描时长/线程,或换个 IP 再试。"
        info "结果目录(空结果): $rundir"
        return 1
    fi
    local raw_n=$(( $(wc -l < "$rundir/scan.csv") - 1 ))
    info "扫描产出 $raw_n 条,正在归一化 CSV(按表头对齐 CERT_DOMAIN,去重)..."
    local cnt
    cnt=$(normalize_csv "$rundir/scan.csv" "$rundir/normalized.csv") || { err "归一化失败"; return 1; }
    info "归一化后候选域名 $cnt 个"
    if [ "$cnt" -eq 0 ]; then err "候选域名为 0,结束"; return 1; fi
    if [ "$cnt" -gt "$MAX_DOMAINS" ]; then
        warn "候选超过单次上限 $MAX_DOMAINS,本次只检测前 $MAX_DOMAINS 个(离目标 IP 最近的优先)"
        head -n $((MAX_DOMAINS + 1)) "$rundir/normalized.csv" > "$rundir/normalized.head.csv"
        mv "$rundir/normalized.head.csv" "$rundir/normalized.csv"
    fi
    hr
    info "第 2 步:RealityChecker $(cur_version checker) 深度检测(每 $CHUNK 个一片,绕开上游 15 秒批量计时)"
    run_checker_csv "$rundir/normalized.csv" "$rundir"
    show_summary "$rundir" "$target"
}

do_check_csv() { # do_check_csv <csv文件> ;原始/归一化都收
    local f="$1"
    [ -f "$f" ] || { err "文件不存在: $f"; return 1; }
    tool_installed checker || { err "RealityChecker 未安装好,先到菜单 7 处理"; return 1; }
    local stamp rundir cnt
    stamp=$(date '+%Y%m%d-%H%M%S')
    rundir="$RESULTS_DIR/${stamp}_csv"
    mkdir -p "$rundir"
    cnt=$(normalize_csv "$f" "$rundir/normalized.csv") || { err "该 CSV 无法解析出域名字段"; return 1; }
    info "从 $f 解析出候选域名 $cnt 个,开始检测 ..."
    [ "$cnt" -eq 0 ] && { err "候选为 0"; return 1; }
    if [ "$cnt" -gt "$MAX_DOMAINS" ]; then
        warn "候选超过单次上限 $MAX_DOMAINS,只检测前 $MAX_DOMAINS 个"
        head -n $((MAX_DOMAINS + 1)) "$rundir/normalized.csv" > "$rundir/n.csv"
        mv "$rundir/n.csv" "$rundir/normalized.csv"
    fi
    run_checker_csv "$rundir/normalized.csv" "$rundir"
    show_summary "$rundir" "CSV:$f"
}

# ---------- 更新/回退 ----------
confirm() { # confirm <提示>
    [ "${YM_YES:-0}" = "1" ] && return 0
    local a
    printf '%s [y/N]: ' "$1"
    read -r a
    case "$a" in y|Y|yes|YES) return 0;; *) return 1;; esac
}

do_update() { # do_update <scanner|checker>
    local proj="$1" lat cur
    case "$proj" in
        scanner) lat="$LATEST_SCANNER";;
        checker) lat="$LATEST_CHECKER";;
    esac
    cur=$(cur_version "$proj")
    if [ -z "$lat" ]; then
        info "联网查询最新版本中 ..."
        case "$proj" in
            scanner) lat=$(latest_tag "$SCANNER_REPO");;
            checker) lat=$(latest_tag "$CHECKER_REPO");;
        esac
    fi
    [ -n "$lat" ] || { err "查不到 $proj 的最新版本(网络/GitHub API 限额?),稍后再试"; return 1; }
    if [ "$cur" = "$lat" ]; then ok "$proj 已是最新版 $lat"; return 0; fi
    info "$proj:当前 ${cur:-未安装} -> 最新 $lat"
    confirm "确认更新 $proj 到 $lat ?" || { info "已取消(是否更新由你决定,不会自动更新)"; return 0; }
    install_tool "$proj" "$lat"
}

do_rollback() { # do_rollback <scanner|checker> [tag]
    local proj="$1" tag="${2:-}"
    if [ -z "$tag" ]; then
        local tags i=0 t cur installed
        cur=$(cur_version "$proj")
        tags=$(list_tags "$([ "$proj" = scanner ] && echo "$SCANNER_REPO" || echo "$CHECKER_REPO")")
        if [ -z "$tags" ]; then
            warn "GitHub API 暂时拿不到版本列表,以下为本地已下载过的版本:"
            tags=$(ls -1 "$TOOLS_DIR/$proj" 2>/dev/null | grep -v '^current$')
        fi
        [ -n "$tags" ] || { err "没有任何可选版本"; return 1; }
        info "可选版本(新 -> 旧):"
        local -a arr=()
        while read -r t; do
            [ -n "$t" ] || continue
            arr+=("$t"); i=$((i + 1))
            installed=""; [ -d "$TOOLS_DIR/$proj/$t" ] && installed=" [已下载,秒切]"
            printf '  %2d) %s%s%s\n' "$i" "$t" "$([ "$t" = "$cur" ] && echo ' [当前]')" "$installed"
        done <<EOF
$tags
EOF
        printf '输入序号(或直接输版本号,回车取消): '
        local sel; read -r sel
        [ -n "$sel" ] || return 0
        if printf '%s' "$sel" | grep -Eq '^[0-9]+$'; then
            tag="${arr[$((sel - 1))]:-}"
            [ -n "$tag" ] || { err "序号超出范围"; return 1; }
        else
            tag="$sel"
        fi
    fi
    local cur; cur=$(cur_version "$proj")
    [ "$tag" = "$cur" ] && { info "$proj 当前就是 $tag,无需切换"; return 0; }
    info "$proj:当前 ${cur:-未安装} -> 切换到 $tag"
    confirm "确认切换 $proj 到 $tag ?" || { info "已取消"; return 0; }
    install_tool "$proj" "$tag"
}

# ---------- 菜单 ----------
ver_line() { # ver_line <scanner|checker> <显示名> <repo>
    local proj="$1" name="$2" cur lat
    cur=$(cur_version "$proj")
    case "$proj" in
        scanner) lat="$LATEST_SCANNER";;
        checker) lat="$LATEST_CHECKER";;
    esac
    if [ -z "$cur" ]; then
        printf '  %s: %b未安装%b\n' "$name" "$C_R" "$C_N"
    elif [ "$UPDATE_CHECK_OK" = 0 ] && [ -z "$lat" ]; then
        printf '  %s: %s (更新检查失败,显示为上次缓存/未知)\n' "$name" "$cur"
    elif [ -n "$lat" ] && [ "$cur" != "$lat" ]; then
        printf '  %s: %s  ->  %b🔔 有新版 %s,去菜单 7 更新%b\n' "$name" "$cur" "$C_Y" "$lat" "$C_N"
    else
        printf '  %s: %s %b✓ 已是最新%b\n' "$name" "$cur" "$C_G" "$C_N"
    fi
}

menu_versions() {
    while true; do
        hr
        info "版本管理"
        ver_line scanner "RealiTLScanner"
        ver_line checker "RealityChecker "
        hr
        cat <<'EOF'
  1) 一键更新两者到最新版
  2) 只更新 RealiTLScanner
  3) 只更新 RealityChecker
  4) 回退/切换 RealiTLScanner 版本
  5) 回退/切换 RealityChecker 版本
  6) 重新检查更新
  0) 返回主菜单
EOF
        printf '请选择: '
        local c; read -r c
        case "$c" in
            1) do_update scanner; do_update checker ;;
            2) do_update scanner ;;
            3) do_update checker ;;
            4) do_rollback scanner ;;
            5) do_rollback checker ;;
            6) info "重新检查中 ..."; check_updates
               if [ "$UPDATE_CHECK_OK" = 1 ]; then ok "检查完成($UPDATE_CHECK_AT)"
               else warn "检查失败(GitHub 不可达或 API 限额),当前显示可能不是最新状态"; fi ;;
            0) return ;;
            *) warn "无效选择" ;;
        esac
    done
}

menu_history() {
    local dirs d i=0
    dirs=$(ls -1dt "$RESULTS_DIR"/*/ 2>/dev/null)
    [ -n "$dirs" ] || { info "还没有历史结果"; return; }
    info "历史结果(新 -> 旧,最多 15 条):"
    local -a arr=()
    while read -r d; do
        i=$((i + 1)); arr+=("$d")
        printf '  %2d) %s  %s\n' "$i" "$(basename "$d")" "$(head -4 "$d/summary.txt" 2>/dev/null | tail -1)"
        [ "$i" -ge 15 ] && break
    done <<EOF
$dirs
EOF
    printf '输入序号查看详情(回车返回): '
    local sel; read -r sel
    [ -n "$sel" ] || return
    local dir="${arr[$((sel - 1))]:-}"
    [ -n "$dir" ] && [ -d "$dir" ] || { warn "序号无效"; return; }
    hr
    cat "$dir/summary.txt" 2>/dev/null
    if [ -s "$dir/suitable.txt" ]; then
        info "适合的域名:"
        nl -ba "$dir/suitable.txt" | sed 's/^/  /'
    fi
    info "完整文件都在: $dir"
}

menu_settings() {
    while true; do
        hr
        info "当前设置(保存在 $CONFIG_FILE):"
        printf '  1) 扫描端口 PORT=%s\n' "$PORT"
        printf '  2) 扫描线程 THREAD=%s\n' "$THREAD"
        printf '  3) 单目标超时 TIMEOUT=%ss\n' "$TIMEOUT"
        printf '  4) 单 IP 扫描时长 SCAN_SECONDS=%ss\n' "$SCAN_SECONDS"
        printf '  5) 检测分片大小 CHUNK=%s\n' "$CHUNK"
        printf '  6) 单次最多检测域名 MAX_DOMAINS=%s\n' "$MAX_DOMAINS"
        printf '  0) 返回\n'
        printf '选要改的项: '
        local c v; read -r c
        case "$c" in
            0) return ;;
            1|2|3|4|5|6)
                printf '新值: '; read -r v
                printf '%s' "$v" | grep -Eq '^[0-9]+$' || { warn "必须是正整数"; continue; }
                case "$c" in
                    1) PORT=$v;; 2) THREAD=$v;; 3) TIMEOUT=$v;;
                    4) SCAN_SECONDS=$v;; 5) CHUNK=$v;; 6) MAX_DOMAINS=$v;;
                esac
                save_config; ok "已保存" ;;
            *) warn "无效选择" ;;
        esac
    done
}

main_menu() {
    while true; do
        hr
        info "ym v$YM_VERSION — Reality 最佳目标域名一键查找"
        ver_line scanner "RealiTLScanner"
        ver_line checker "RealityChecker "
        hr
        cat <<'EOF'
  1) 一键找域名:输入 IP,全自动扫描 + 检测 + 给推荐
  2) 单域名检测(RealityChecker check)
  3) 对已有 CSV 检测(Scanner 的原始输出也行,自动归一化)
  4) 批量域名检测(手动输入多个域名)
  5) 历史结果
  6) 设置
  7) 版本管理(更新提醒 / 更新 / 回退)
  0) 退出
EOF
        printf '请选择: '
        local c; read -r c
        case "$c" in
            1)
                printf '输入目标 IP(或 CIDR / 域名): '
                local t; read -r t
                [ -n "$t" ] && do_pipeline "$t"
                ;;
            2)
                printf '输入域名(如 www.example.com): '
                local dm; read -r dm
                [ -n "$dm" ] && { tool_installed checker && run_checker_single "$dm" || err "RealityChecker 未安装好,先到菜单 7 处理"; }
                ;;
            3)
                printf '输入 CSV 文件路径: '
                local f; read -r f
                [ -n "$f" ] && do_check_csv "$f"
                ;;
            4)
                printf '输入多个域名(空格分隔): '
                local ds; read -r ds
                # shellcheck disable=SC2086
                [ -n "$ds" ] && { tool_installed checker && run_checker_batch $ds || err "RealityChecker 未安装好,先到菜单 7 处理"; }
                ;;
            5) menu_history ;;
            6) menu_settings ;;
            7) menu_versions ;;
            0) info "再见"; return 0 ;;
            *) warn "无效选择" ;;
        esac
    done
}

# ---------- 卸载 ----------
do_uninstall() {
    confirm "确认卸载 ym 命令?(工具和历史结果默认保留在 $BASE)" || { info "已取消"; return; }
    rm -f /usr/local/bin/ym "$HOME/.local/bin/ym" 2>/dev/null
    ok "ym 命令已移除"
    if confirm "同时删除全部工具与历史结果目录 $BASE ?"; then
        rm -rf "$BASE"
        ok "已删除 $BASE"
    fi
}

# ---------- 入口 ----------
usage() {
    sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
}

main() {
    ensure_deps || exit 1
    self_install
    case "${1:-menu}" in
        menu|"")
            info "正在检查两个上游项目的最新版本 ..."
            check_updates
            ensure_tools
            main_menu
            ;;
        scan)
            [ -n "${2:-}" ] || { err "用法: ym scan <IP> [扫描秒数]"; exit 1; }
            check_updates; ensure_tools
            has_update scanner && warn "🔔 RealiTLScanner 有新版 $LATEST_SCANNER(当前 $(cur_version scanner)),ym update 可更新"
            has_update checker && warn "🔔 RealityChecker 有新版 $LATEST_CHECKER(当前 $(cur_version checker)),ym update 可更新"
            do_pipeline "$2" "${3:-$SCAN_SECONDS}"
            ;;
        check)
            [ -n "${2:-}" ] || { err "用法: ym check <域名>"; exit 1; }
            check_updates; ensure_tools
            tool_installed checker || { err "RealityChecker 未安装好"; exit 1; }
            run_checker_single "$2"
            ;;
        csv)
            [ -n "${2:-}" ] || { err "用法: ym csv <文件>"; exit 1; }
            check_updates; ensure_tools
            do_check_csv "$2"
            ;;
        update)
            check_updates
            case "${2:-all}" in
                scanner) do_update scanner ;;
                checker) do_update checker ;;
                all)     do_update scanner; do_update checker ;;
                *) err "用法: ym update [scanner|checker|all]"; exit 1 ;;
            esac
            ;;
        rollback)
            case "${2:-}" in
                scanner|checker) do_rollback "$2" "${3:-}" ;;
                *) err "用法: ym rollback <scanner|checker> [版本]"; exit 1 ;;
            esac
            ;;
        version)
            check_updates
            printf 'ym 脚本: v%s\n' "$YM_VERSION"
            ver_line scanner "RealiTLScanner"
            ver_line checker "RealityChecker "
            ;;
        uninstall) do_uninstall ;;
        -h|--help|help) usage ;;
        *) err "未知参数: $1"; usage; exit 1 ;;
    esac
}

main "$@"
