#!/usr/bin/env bash
# Ubuntu 18.04+ / Bash 4.4+; one local Xray + one existing HTTPS Nginx site.
set -Eeuo pipefail
umask 077

BASE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
TOOL="$BASE_DIR/config_tool.py"
STATE_DIR=/var/lib/xray-quick-deploy
XRAY_BIN=/usr/local/bin/xray
XRAY_CONFIG=/usr/local/etc/xray/config.json
XRAY_UNIT=/etc/systemd/system/xray.service
INSTALL_COMMIT=e42df6a772e60dd7b058f852262c4dbeb0bc231d
INSTALL_SHA256=954666bb028ba8561b2218372b7db76ba051f8252b2db9195321e672263aab94
PHASE='初始化'
NGINX_PENDING=0
INSTALL_IN_PROGRESS=0
TEMP_FILES=()

say() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
die() { say "错误：$*" >&2; exit 1; }
step() { PHASE="$*"; say "开始：$PHASE"; }
digest() { sha256sum -- "$1" | cut -d ' ' -f 1; }
nginx_test() { "$NGINX_BIN" -t -c "$NGINX_MAIN"; }
nginx_reload() { "$NGINX_BIN" -s reload -c "$NGINX_MAIN"; }

usage() {
    cat <<'EOF'
用法：sudo bash deploy.sh [all|xray|nginx|check]
先编辑同目录 deploy.conf；all 是默认动作。
  all    安装/复用 Xray，接入已有 HTTPS 站点，并检查入口
  xray   只安装/复用 Xray 并检查后端，无需填写域名
  nginx  复用已配置的 Xray，仅接入 Nginx 并检查入口
  check  只检查后端及已配置的 HTTPS 入口，不安装或重载服务
此工具不新建网站、不申请证书，不自动升级已有 Xray。
EOF
}

finish() {
    local status=$? current restore
    trap - EXIT ERR INT TERM
    set +e
    if (( status != 0 )); then
        say "部署未完成，退出码 $status；阶段：$PHASE。日志：${LOG_FILE:-未创建}"
        if (( NGINX_PENDING )); then
            current="$(digest "$NGINX_SITE")"
            if [[ "$current" == "$NGINX_OLD_HASH" ]]; then
                say '站点文件仍为原内容，无需恢复。'
            elif [[ "$current" != "$NGINX_NEW_HASH" ]]; then
                say "站点文件发生了其他修改，未自动覆盖。原配置备份：$NGINX_BACKUP"
            else
                say '恢复原 Nginx 站点配置……'
                restore="$(mktemp "$(dirname -- "$NGINX_SITE")/.xray-restore.XXXXXX")"
                if [[ -n "$restore" ]] && cp -p -- "$NGINX_BACKUP" "$restore" &&
                    mv -f -- "$restore" "$NGINX_SITE"; then
                    if nginx_test && nginx_reload; then
                        say '原站点文件已恢复，并已发送重载信号。'
                    else
                        say "文件已恢复，但检查/重载失败，请立即检查 Nginx。备份：$NGINX_BACKUP"
                    fi
                else
                    say "自动恢复失败，请手动恢复。备份：$NGINX_BACKUP"
                fi
            fi
        fi
        if (( INSTALL_IN_PROGRESS )); then
            systemctl stop xray >/dev/null 2>&1
            say '已尝试停止本次未通过验收的 Xray；未卸载软件，便于排错后重试。'
        fi
        say '排错命令：systemctl status xray --no-pager -l'
        say '排错命令：journalctl -u xray -b -n 60 --no-pager'
    fi
    for restore in "${TEMP_FILES[@]}"; do rm -f -- "$restore"; done
    exit "$status"
}

environment() {
    [[ $EUID -eq 0 ]] || die '请用 sudo bash deploy.sh 运行。'
    export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
    export LC_ALL=C
    export PYTHONIOENCODING=utf-8
    [[ -r /etc/os-release ]] || die '缺少 /etc/os-release。'
    # shellcheck disable=SC1091
    . /etc/os-release
    [[ "${ID:-}" == ubuntu ]] || die '此脚本只处理 Ubuntu。'
    dpkg --compare-versions "${VERSION_ID:-0}" ge 18.04 || die '需要 Ubuntu 18.04 或更新版本。'
    [[ -d /run/systemd/system && "$(ps -p 1 -o comm=)" == systemd ]] || die '需要以 systemd 启动的宿主机；不支持普通 Docker 容器。'
    [[ -f "$BASE_DIR/deploy.conf" && -f "$TOOL" ]] || die '请保持 deploy.sh、deploy.conf、config_tool.py 位于同一目录。'
    SITE_DOMAIN='' NGINX_SITE='' NGINX_BIN='' NGINX_MAIN='' XRAY_VERSION='' XRAY_PORT=''
    # This is the user's local, editable configuration, shipped alongside this script.
    # shellcheck disable=SC1091
    . "$BASE_DIR/deploy.conf"
    [[ "$XRAY_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die 'XRAY_VERSION 格式错误。'
    [[ "$XRAY_PORT" =~ ^[0-9]{1,5}$ ]] || die 'XRAY_PORT 必须是端口数字。'
    XRAY_PORT=$((10#$XRAY_PORT))
    (( XRAY_PORT >= 1024 && XRAY_PORT <= 65535 )) || die 'XRAY_PORT 应在 1024—65535 之间。'
    [[ ! -L "$STATE_DIR" ]] || die "$STATE_DIR 不能是符号链接。"
    install -d -m 0700 -o root -g root "$STATE_DIR" "$STATE_DIR/logs" "$STATE_DIR/backups"
    command -v flock >/dev/null || die '缺少 flock，请先安装 util-linux。'
    exec 9>"$STATE_DIR/deploy.lock"
    flock -n 9 || die '另一个部署进程正在运行。'
    LOG_FILE="$STATE_DIR/logs/$(date '+%Y%m%d-%H%M%S')-$$.log"
    exec > >(tee -a "$LOG_FILE") 2>&1
    trap 'rc=$?; say "命令失败：第 $LINENO 行，退出码 $rc。" >&2; exit "$rc"' ERR
    trap finish EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    say "Ubuntu $VERSION_ID / $(uname -m)，动作：$ACTION，Xray：$XRAY_VERSION"
    say "部署日志：$LOG_FILE"
    if dpkg --compare-versions "$VERSION_ID" lt 22.04; then
        say '提示：该 Ubuntu 版本已结束标准维护；请确保已有 ESM 或其他有效安全维护安排。'
    fi
}

dependencies() {
    local command
    if [[ "$ACTION" == all || "$ACTION" == xray ]] && [[ ! -x "$XRAY_BIN" ]]; then
        step '安装依赖（不执行系统整体升级）'
        timeout 300 apt-get -o Acquire::Retries=3 update 2>&1 | tee "$STATE_DIR/apt-update.log"
        if grep -Eq '^(E:|W: Failed to fetch|W: Some index files failed)' "$STATE_DIR/apt-update.log"; then
            die 'APT 索引有下载失败，请先修复软件源；未继续安装。'
        fi
        DEBIAN_FRONTEND=noninteractive timeout 600 apt-get install -y --no-install-recommends \
            ca-certificates curl unzip openssl python3 iproute2 util-linux
    fi
    for command in python3 curl openssl ss runuser timeout systemd-sysusers; do
        command -v "$command" >/dev/null || die "缺少命令：$command。请先安装相应系统软件包。"
    done
    python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 6) else 1)'
    say "依赖检查通过：$(python3 --version 2>&1)"
}

load_xray() {
    local values
    [[ ! -L "$XRAY_CONFIG" ]] || die 'Xray 配置是符号链接，未自动处理。'
    values="$(python3 "$TOOL" xray-read "$XRAY_CONFIG" "$XRAY_PORT")"
    mapfile -t XRAY_VALUES <<< "$values"
    XRAY_STATE="${XRAY_VALUES[0]}"
    if [[ "$XRAY_STATE" == ready ]]; then
        XRAY_UUID="${XRAY_VALUES[1]}"
        XRAY_PATH="${XRAY_VALUES[2]}"
    fi
}

check_version_and_unit() {
    local version start
    [[ -x "$XRAY_BIN" ]] || die '没有找到 Xray 二进制文件。'
    version="$("$XRAY_BIN" version)"
    [[ "$version" == "Xray ${XRAY_VERSION#v} "* || "$version" == "Xray ${XRAY_VERSION#v}"$'\n'* ]] ||
        die "现有 Xray 版本与 $XRAY_VERSION 不一致。本工具不会自动升级或降级；请检查 deploy.conf。"
    say "${version%%$'\n'*}"
    [[ "$(systemctl show xray -p User --value)" == xray ]] || die 'xray.service 未使用专用 xray 账户，未自动修改。'
    start="$(systemctl show xray -p ExecStart --value)"
    [[ "$start" == *"argv[]=$XRAY_BIN run -config $XRAY_CONFIG ;"* ]] || die 'xray.service 的 ExecStart 不是预期的单配置启动方式。'
    runuser -u xray -- "$XRAY_BIN" run -test -config "$XRAY_CONFIG"
}

setup_xray() {
    local installer downloaded tmp sockets
    step '检查或安装 Xray 后端'
    load_xray
    if [[ "$XRAY_STATE" == empty ]]; then
        if [[ -e "$XRAY_BIN" || -e "$XRAY_UNIT" || -e /usr/local/etc/xray ]] &&
            [[ ! -f "$STATE_DIR/install.started" ]]; then
            die '发现已有 Xray 文件，但不是可复用的本方案配置。未覆盖；请先检查原安装。'
        fi
        sockets="$(ss -H -ltn "sport = :$XRAY_PORT")"
        [[ -z "$sockets" ]] || die "端口 $XRAY_PORT 已被占用，请检查或修改 deploy.conf 中的 XRAY_PORT。"
        installer="$STATE_DIR/xray-install-release.sh"
        if [[ ! -f "$installer" ]]; then
            say '从官方仓库下载固定提交的安装器……'
            downloaded="$(mktemp "$STATE_DIR/installer.XXXXXX")"
            TEMP_FILES+=("$downloaded")
            curl -q --fail --show-error --silent --location --retry 3 \
                --connect-timeout 15 --max-time 180 \
                --output "$downloaded" \
                "https://raw.githubusercontent.com/XTLS/Xray-install/$INSTALL_COMMIT/install-release.sh"
            [[ "$(digest "$downloaded")" == "$INSTALL_SHA256" ]] || die '官方安装器 SHA256 与固定版本不符，未执行。'
            bash -n "$downloaded"
            mv -- "$downloaded" "$installer"
        fi
        [[ "$(digest "$installer")" == "$INSTALL_SHA256" ]] || die '缓存的安装器校验失败，未执行。'
        : > "$STATE_DIR/install.started"
        rm -f -- "$STATE_DIR/xray.complete"
        INSTALL_IN_PROGRESS=1
        say "安装 $XRAY_VERSION；安装器会另行校验发行包 SHA256。"
        # Clear installer overrides so inherited shell variables cannot redirect files.
        env -u JSON_PATH -u JSONS_PATH -u DAT_PATH -u XRAY_CUSTOMIZE \
            timeout 600 bash "$installer" install --version "$XRAY_VERSION" \
            --force --without-geodata --without-logfiles
        systemctl stop xray
        id xray >/dev/null
        [[ "$(id -u xray)" != 0 && "$(id -g xray)" != 0 ]] || die 'xray 运行账户或组错误。'
        load_xray
        [[ "$XRAY_STATE" == empty ]] || die '安装后出现了意外的非空配置，未覆盖。'
        step '生成并校验独立 UUID、XHTTP 路径和配置'
        XRAY_UUID="$("$XRAY_BIN" uuid)"
        XRAY_PATH="/api/$(openssl rand -hex 16)/"
        install -d -m 0750 -o root -g xray /usr/local/etc/xray
        tmp="$(mktemp /usr/local/etc/xray/config.XXXXXX.json)"
        TEMP_FILES+=("$tmp")
        python3 "$TOOL" xray-write "$tmp" "$XRAY_UUID" "$XRAY_PATH" "$XRAY_PORT"
        chown root:xray "$tmp"
        chmod 0640 "$tmp"
        runuser -u xray -- "$XRAY_BIN" run -test -config "$tmp"
        mv -f -- "$tmp" "$XRAY_CONFIG"
        say '凭据已写入 Xray 配置；后续重复执行会复用它们。'
    else
        say '已有匹配的 Xray 配置；保留二进制、UUID、路径和其他配置。'
    fi
    # Resume our own interrupted first installation without rotating credentials.
    if [[ -f "$STATE_DIR/install.started" && ! -f "$STATE_DIR/xray.complete" ]]; then
        INSTALL_IN_PROGRESS=1
        install -d -m 0755 /etc/systemd/system/xray.service.d
        printf '[Service]\nRestart=on-failure\nRestartSec=5s\n' \
            > /etc/systemd/system/xray.service.d/20-restart.conf
        chmod 0644 /etc/systemd/system/xray.service.d/20-restart.conf
        systemctl daemon-reload
    fi
    check_version_and_unit
    systemctl enable xray
    systemctl start xray
    local attempt ready=0 code
    for attempt in {1..10}; do
        if code="$(curl -q --noproxy '*' -sS --max-time 2 -X OPTIONS -o /dev/null \
            -w '%{http_code}' "http://127.0.0.1:$XRAY_PORT$XRAY_PATH" 2>/dev/null)" && [[ "$code" == 200 ]]; then
            ready=1
            break
        fi
        sleep 1
    done
    (( ready )) || die 'Xray 启动后没有在规定时间内响应，请检查 journalctl。'
    check_backend
    : > "$STATE_DIR/xray.complete"
    INSTALL_IN_PROGRESS=0
}

check_backend() {
    local pid listeners result
    step '验收 Xray 配置、服务状态、监听地址和 HTTP 响应'
    load_xray
    [[ "$XRAY_STATE" == ready ]] || die '缺少已配置的 Xray 入站，请先执行 xray 阶段。'
    check_version_and_unit
    systemctl is-active --quiet xray || die 'Xray 未运行。'
    [[ "$(systemctl is-enabled xray)" == enabled ]] || die 'Xray 未设置开机启动。'
    [[ "$(systemctl show xray -p Restart --value)" == on-failure ]] || die 'Xray 未配置 Restart=on-failure。'
    [[ "$(systemctl show xray -p RestartUSec --value)" == 5s ]] || die 'Xray 重启间隔不是预期的 5s。'
    pid="$(systemctl show xray -p MainPID --value)"
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || die 'Xray 主进程 PID 无效。'
    listeners="$(ss -H -ltnp "sport = :$XRAY_PORT")"
    [[ "$listeners" != *$'\n'* && "$listeners" == *"127.0.0.1:$XRAY_PORT "* &&
        "$listeners" == *"pid=$pid,"* ]] || die '监听端口、地址或所属进程与预期不一致。'
    result="$(curl -q --noproxy '*' -sS --max-time 5 -o /dev/null -w '%{http_code}' \
        "http://127.0.0.1:$XRAY_PORT/")"
    [[ "$result" == 404 ]] || die "后端根路径预期 404，实际 $result。"
    result="$(curl -q --noproxy '*' -sS --max-time 5 -X OPTIONS -o /dev/null -w '%{http_code}' \
        "http://127.0.0.1:$XRAY_PORT$XRAY_PATH")"
    [[ "$result" == 200 ]] || die "后端 XHTTP OPTIONS 预期 200，实际 $result。"
    say "后端通过：active / enabled / 仅 127.0.0.1:$XRAY_PORT / 根路径 404 / OPTIONS 200。"
}

nginx_environment() {
    local candidate dump
    step '定位现有 Nginx 和 HTTPS 站点'
    SITE_DOMAIN="${SITE_DOMAIN,,}"
    [[ ${#SITE_DOMAIN} -le 253 && "$SITE_DOMAIN" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] ||
        die '请在 deploy.conf 填写 SITE_DOMAIN，仅填域名，不带 https://、端口或路径。'
    if [[ -z "$NGINX_BIN" ]]; then
        if [[ -x /www/server/nginx/sbin/nginx ]]; then NGINX_BIN=/www/server/nginx/sbin/nginx
        else NGINX_BIN="$(command -v nginx || true)"; fi
    fi
    [[ -x "$NGINX_BIN" ]] || die '找不到 Nginx，请填写 deploy.conf 中的 NGINX_BIN。'
    if [[ -z "$NGINX_MAIN" ]]; then
        if [[ "$NGINX_BIN" == /www/server/nginx/sbin/nginx ]]; then NGINX_MAIN=/www/server/nginx/conf/nginx.conf
        else NGINX_MAIN=/etc/nginx/nginx.conf; fi
    fi
    [[ -f "$NGINX_MAIN" ]] || die '找不到 Nginx 主配置，请填写 NGINX_MAIN。'
    if [[ -z "$NGINX_SITE" ]]; then
        local candidates=()
        for candidate in "/www/server/panel/vhost/nginx/$SITE_DOMAIN.conf" \
            "/etc/nginx/sites-available/$SITE_DOMAIN" "/etc/nginx/sites-available/$SITE_DOMAIN.conf" \
            "/etc/nginx/conf.d/$SITE_DOMAIN.conf"; do
            [[ ! -f "$candidate" ]] || candidates+=("$candidate")
        done
        [[ ${#candidates[@]} -eq 1 ]] || die '未找到唯一站点文件，请明确填写 NGINX_SITE。'
        NGINX_SITE="${candidates[0]}"
    fi
    [[ -f "$NGINX_SITE" ]] || die 'NGINX_SITE 指定的文件不存在。'
    NGINX_BIN="$(readlink -e -- "$NGINX_BIN")"
    NGINX_MAIN="$(readlink -e -- "$NGINX_MAIN")"
    NGINX_SITE="$(readlink -e -- "$NGINX_SITE")"
    [[ "$NGINX_SITE" != "$NGINX_MAIN" ]] || die '请指定独立的站点配置文件，不修改整个 nginx.conf。'
    curl -q --version | grep -w HTTP2 >/dev/null || die '当前 curl 不支持 HTTP/2；请安装支持 HTTP/2 的发行版 curl。'
    "$NGINX_BIN" -V
    nginx_test
    dump="$(mktemp "$STATE_DIR/nginx-dump.XXXXXX")"
    TEMP_FILES+=("$dump")
    "$NGINX_BIN" -T -c "$NGINX_MAIN" > "$dump"
    python3 "$TOOL" included "$dump" "$NGINX_SITE"
    say "目标站点：$SITE_DOMAIN；文件：$NGINX_SITE"
}

https_probe() {
    curl -q --noproxy '*' --http2 --silent --show-error --connect-timeout 5 --max-time 15 \
        --resolve "$SITE_DOMAIN:443:127.0.0.1" -X "$1" -o /dev/null \
        -w '%{http_code} %{http_version}' "https://$SITE_DOMAIN$2"
}

check_https() {
    local result attempt
    step '验收本机 HTTPS、证书、HTTP/2 和 XHTTP 入口'
    for attempt in {1..5}; do
        if result="$(https_probe OPTIONS "$XRAY_PATH")" && [[ "$result" == '200 2' ]]; then
            say '入口通过：HTTP 200; version 2，证书验证已开启。'
            return 0
        fi
        say "入口检查第 $attempt 次未通过：${result:-连接失败}"
        sleep 1
    done
    die 'HTTPS 入口未返回预期的 200 / HTTP2，请检查站点重写、WAF、证书和代理路由。'
}

setup_nginx() {
    local candidate change baseline
    step '检查网站原有 HTTPS 入口'
    baseline="$(https_probe GET /)"
    [[ "$baseline" =~ ^[23][0-9][0-9]\ 2$ ]] || die "现有网站预期返回 2xx/3xx 且使用 HTTP/2，实际 $baseline；未修改站点。"
    step '生成站点变更并保留备份'
    NGINX_OLD_HASH="$(digest "$NGINX_SITE")"
    candidate="$(mktemp "$(dirname -- "$NGINX_SITE")/.xray-site.XXXXXX")"
    TEMP_FILES+=("$candidate")
    cp -p -- "$NGINX_SITE" "$candidate"
    change="$(python3 "$TOOL" nginx-write "$NGINX_SITE" "$candidate" "$SITE_DOMAIN" "$XRAY_PATH" "$XRAY_PORT")"
    if [[ "$change" == changed ]]; then
        NGINX_BACKUP="$STATE_DIR/backups/$(date '+%Y%m%d-%H%M%S')-$$.nginx.conf"
        cp -p -- "$NGINX_SITE" "$NGINX_BACKUP"
        printf '%s\n' "$NGINX_SITE" > "${NGINX_BACKUP}.original-path"
        [[ "$(digest "$NGINX_SITE")" == "$NGINX_OLD_HASH" &&
            "$(digest "$NGINX_BACKUP")" == "$NGINX_OLD_HASH" ]] || die '生成变更期间站点被其他程序修改，已停止。'
        NGINX_NEW_HASH="$(digest "$candidate")"
        NGINX_PENDING=1
        mv -f -- "$candidate" "$NGINX_SITE"
        say "已插入受管 location；备份：$NGINX_BACKUP"
    elif [[ "$change" == unchanged ]]; then
        say '受管 location 已与本次参数一致，无需改写。'
    else
        die '配置工具返回了未知状态。'
    fi
    step '校验并平滑重载 Nginx'
    nginx_test
    nginx_reload
    check_https
    NGINX_PENDING=0
}

save_info() {
    local tmp
    tmp="$(mktemp "$STATE_DIR/node.XXXXXX")"
    TEMP_FILES+=("$tmp")
    {
        printf '# 本机生成的连接参数；不要公开或放入网站目录。\n'
        printf 'XRAY_UUID=%q\nXRAY_PATH=%q\nXRAY_PORT=%q\n' "$XRAY_UUID" "$XRAY_PATH" "$XRAY_PORT"
        printf 'SITE_DOMAIN=%q\nXRAY_VERSION=%q\n' "$SITE_DOMAIN" "$XRAY_VERSION"
        printf 'CLIENT_PORT=443\nCLIENT_XHTTP_MODE=packet-up\nCLIENT_TLS=true\nCLIENT_ALPN=h2\n'
    } > "$tmp"
    chmod 0600 "$tmp"
    mv -f -- "$tmp" "$STATE_DIR/node.env"
    say "连接参数已保存：$STATE_DIR/node.env（仅 root 可读）。"
}

main() {
    ACTION="${1:-all}"
    case "$ACTION" in -h|--help|help) usage; return 0;; all|xray|nginx|check) ;; *) usage; die '未知动作。';; esac
    [[ $# -le 1 ]] || die '只接受一个阶段参数，请在 deploy.conf 填写其他设置。'
    environment
    dependencies
    # Check the existing site before installing a backend during an all-in-one run.
    if [[ "$ACTION" != xray ]]; then nginx_environment; fi
    case "$ACTION" in
        all|xray) setup_xray; save_info;;
        nginx|check) check_backend;;
    esac
    case "$ACTION" in
        all|nginx) setup_nginx; save_info;;
        check) check_https;;
    esac
    say "成功：$ACTION 阶段的全部检查已通过。"
    if [[ "$ACTION" == xray ]]; then
        say '目前仅完成本机后端；网站准备好后填写 deploy.conf，再执行 nginx 阶段。'
    else
        say '还需在实际客户端连接并访问外部网站，才能完成公网端到端验收。'
    fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
