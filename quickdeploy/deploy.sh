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
XRAY_DROPIN=/etc/systemd/system/xray.service.d/20-restart.conf
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

# Check before changing contents or metadata; healthy repeat runs leave these files alone.
ensure_dir() {
    local path=$1 mode=$2 owner=$3 group=$4
    [[ ! -L "$path" ]] || die "受管目录不能是符号链接：$path"
    if [[ -e "$path" ]]; then
        [[ -d "$path" ]] || die "预期目录却发现其他文件：$path"
        if [[ "$(stat -c '%U:%G' -- "$path")" != "$owner:$group" ]]; then chown "$owner:$group" "$path"; fi
        if [[ "$(stat -c '%a' -- "$path")" != "${mode#0}" ]]; then chmod "$mode" "$path"; fi
    else
        install -d -m "$mode" -o "$owner" -g "$group" "$path"
    fi
}

ensure_file() {
    local source=$1 target=$2 mode=$3 owner=$4 group=$5 temp
    FILE_CHANGED=0
    [[ ! -L "$target" ]] || die "受管文件不能是符号链接：$target"
    [[ ! -e "$target" || -f "$target" ]] || die "预期普通文件：$target"
    if [[ ! -f "$target" ]] || ! cmp -s -- "$source" "$target"; then
        temp="$(mktemp "$(dirname -- "$target")/.xray-write.XXXXXX")"
        TEMP_FILES+=("$temp")
        install -m "$mode" -o "$owner" -g "$group" -- "$source" "$temp"
        mv -f -- "$temp" "$target"
        FILE_CHANGED=1
    else
        if [[ "$(stat -c '%U:%G' -- "$target")" != "$owner:$group" ]]; then
            chown "$owner:$group" "$target"
            FILE_CHANGED=1
        fi
        if [[ "$(stat -c '%a' -- "$target")" != "${mode#0}" ]]; then
            chmod "$mode" "$target"
            FILE_CHANGED=1
        fi
    fi
}

mark_once() {
    [[ ! -L "$1" ]] || die "状态标记不能是符号链接：$1"
    if [[ -e "$1" ]]; then
        [[ -f "$1" ]] || die "状态标记不是普通文件：$1"
    else
        : > "$1"
    fi
}

usage() {
    cat <<'EOF'
用法：sudo bash deploy.sh [all|xray|nginx|check]
首次使用先复制 deploy.conf.example 为 deploy.conf 并编辑；all 是默认动作。
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
                rm -f -- "$STATE_DIR/nginx.pending"
            elif [[ "$current" != "$NGINX_NEW_HASH" ]]; then
                say "站点文件发生了其他修改，未自动覆盖。原配置备份：$NGINX_BACKUP"
            elif [[ ! -f "$NGINX_BACKUP" || -L "$NGINX_BACKUP" ]] ||
                [[ "$(digest "$NGINX_BACKUP")" != "$NGINX_OLD_HASH" ]]; then
                say "原配置备份缺失或校验失败，未用它覆盖站点；请手动检查：$NGINX_BACKUP"
            else
                say '恢复原 Nginx 站点配置……'
                restore="$(mktemp "$(dirname -- "$NGINX_SITE")/.xray-restore.XXXXXX")"
                TEMP_FILES+=("$restore")
                if [[ -n "$restore" ]] && cp -p -- "$NGINX_BACKUP" "$restore" &&
                    mv -f -- "$restore" "$NGINX_SITE"; then
                    if nginx_test && nginx_reload; then
                        say '原站点文件已恢复，并已发送重载信号。'
                        rm -f -- "$STATE_DIR/nginx.pending"
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
    [[ -f "$TOOL" ]] || die '请保持 deploy.sh 和 config_tool.py 位于同一目录。'
    [[ -f "$BASE_DIR/deploy.conf" ]] || die '缺少 deploy.conf；首次使用请在脚本目录执行 cp -n deploy.conf.example deploy.conf，再编辑设置。'
    SITE_DOMAIN='' NGINX_SITE='' NGINX_BIN='' NGINX_MAIN='' XRAY_VERSION='' XRAY_PORT=''
    # This is the user's local, editable configuration, shipped alongside this script.
    # shellcheck disable=SC1091
    . "$BASE_DIR/deploy.conf"
    [[ "$XRAY_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die 'XRAY_VERSION 格式错误。'
    [[ "$XRAY_PORT" =~ ^[0-9]{1,5}$ ]] || die 'XRAY_PORT 必须是端口数字。'
    XRAY_PORT=$((10#$XRAY_PORT))
    (( XRAY_PORT >= 1024 && XRAY_PORT <= 65535 )) || die 'XRAY_PORT 应在 1024—65535 之间。'
    [[ ! -L "$STATE_DIR" ]] || die "$STATE_DIR 不能是符号链接。"
    ensure_dir "$STATE_DIR" 0700 root root
    ensure_dir "$STATE_DIR/logs" 0700 root root
    ensure_dir "$STATE_DIR/backups" 0700 root root
    command -v flock >/dev/null || die '缺少 flock，请先安装 util-linux。'
    [[ ! -L "$STATE_DIR/deploy.lock" ]] || die '部署锁不能是符号链接。'
    exec 9>>"$STATE_DIR/deploy.lock"
    flock -n 9 || die '另一个部署进程正在运行。'
    LOG_FILE="$STATE_DIR/logs/$(date '+%Y%m%d-%H%M%S')-$$.log"
    exec > >(tee -a "$LOG_FILE" 9>&-) 2>&1
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
    local command package package_status apt_status python_version
    local missing=()
    if [[ "$ACTION" == all || "$ACTION" == xray ]] && [[ ! -x "$XRAY_BIN" ]]; then
        step '检查已安装的依赖软件包'
        for package in ca-certificates curl unzip openssl python3 iproute2 util-linux ncurses-bin; do
            if package_status="$(dpkg-query -W -f='${Status}' "$package" 2>/dev/null)"; then
                case "$package_status" in
                    'install ok installed'|'hold ok installed') say "依赖已就绪：$package";;
                    *' not-installed'|*' config-files') missing+=("$package");;
                    *) die "软件包 $package 状态异常：$package_status；请先用 dpkg --audit 检查，不自动继续 APT。";;
                esac
            else
                missing+=("$package")
            fi
        done
        if (( ${#missing[@]} )); then
            step "仅安装缺失依赖：${missing[*]}"
            say '本次 APT 调用暂停 needrestart 钩子；保留系统的持久配置。'
            # Closing fd 9 prevents package hooks/background daemons inheriting our deployment lock.
            if DEBIAN_FRONTEND=noninteractive NEEDRESTART_SUSPEND=1 \
                timeout --verbose 300 apt-get -o Acquire::Retries=3 update \
                9>&- </dev/null 2>&1 | tee "$STATE_DIR/apt-update.log"; then
                say 'APT 软件包索引更新完成。'
            else
                apt_status=$?
                die "APT 索引更新失败或收到超时信号（退出码 $apt_status）；请先确认 apt/dpkg 状态。"
            fi
            if grep -Eq '^(E:|W: Failed to fetch|W: Some index files failed)' "$STATE_DIR/apt-update.log"; then
                die 'APT 索引有下载失败，请先修复软件源；未继续安装。'
            fi
            if DEBIAN_FRONTEND=noninteractive NEEDRESTART_SUSPEND=1 \
                timeout --verbose 600 apt-get -o Dpkg::Use-Pty=0 \
                -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold \
                install -y --no-upgrade --no-install-recommends "${missing[@]}" 9>&- </dev/null; then
                say 'APT 安装命令已退出，继续检查依赖。'
            else
                apt_status=$?
                die "APT 安装失败或收到超时信号（退出码 $apt_status）；先检查 apt/dpkg，不直接重跑安装。"
            fi
            for package in "${missing[@]}"; do
                package_status="$(dpkg-query -W -f='${Status}' "$package" 2>/dev/null)" || die "安装后仍无法查询软件包 $package。"
                [[ "$package_status" == 'install ok installed' || "$package_status" == 'hold ok installed' ]] ||
                    die "安装后软件包 $package 尚未配置完成：$package_status。"
            done
        else
            say '所有依赖包均已安装，跳过 apt-get update/install。'
        fi
        # The pinned upstream installer otherwise invokes APT itself for tput.
        for command in tput curl unzip; do
            command -v "$command" >/dev/null || die "软件包已安装但缺少 $command 命令；请先修复，避免安装器再次调用包管理器。"
        done
    fi
    step '检查依赖命令'
    for command in python3 curl openssl ss runuser timeout systemd-sysusers; do
        command -v "$command" >/dev/null || die "缺少命令：$command。请先安装相应系统软件包。"
        say "命令就绪：$command"
    done
    step '检查 Python 运行环境（15 秒后发送终止信号，另有 5 秒强制退出上限）'
    if python_version="$(timeout -k 5s 15s python3 -c \
        'import sys; print(sys.version.split()[0]); sys.exit(0 if sys.version_info >= (3, 6) else 1)')"; then
        say "依赖检查通过：Python $python_version"
    else
        die 'Python 自检失败或超时；请检查 command -v python3 和 python3 的运行环境。'
    fi
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

check_binary_version() {
    local version
    [[ -x "$XRAY_BIN" ]] || die '没有找到 Xray 二进制文件。'
    version="$("$XRAY_BIN" version)"
    [[ "$version" == "Xray ${XRAY_VERSION#v} "* || "$version" == "Xray ${XRAY_VERSION#v}"$'\n'* ]] ||
        die "现有 Xray 版本与 $XRAY_VERSION 不一致。本工具不会自动升级或降级；请检查 deploy.conf。"
    say "${version%%$'\n'*}"
}

check_version_and_unit() {
    local start
    check_binary_version
    [[ "$(systemctl show xray -p User --value)" == xray ]] || die 'xray.service 未使用专用 xray 账户，未自动修改。'
    start="$(systemctl show xray -p ExecStart --value)"
    [[ "$start" == *"argv[]=$XRAY_BIN run -config $XRAY_CONFIG ;"* ]] || die 'xray.service 的 ExecStart 不是预期的单配置启动方式。'
    runuser -u xray -- "$XRAY_BIN" run -test -config "$XRAY_CONFIG"
}

complete_xray_unit() {
    local tmp
    # Only complete a unit missing from our own interrupted installation.
    [[ -f "$STATE_DIR/install.started" && ! -e "$XRAY_UNIT" ]] || return 0
    [[ ! -L "$XRAY_UNIT" ]] || die '缺失的服务文件是悬空链接，未覆盖。'
    if [[ ! -d "$(dirname -- "$XRAY_UNIT")" ]]; then
        ensure_dir "$(dirname -- "$XRAY_UNIT")" 0755 root root
    fi
    tmp="$(mktemp "$STATE_DIR/unit.XXXXXX")"
    TEMP_FILES+=("$tmp")
    cat > "$tmp" <<EOF
[Unit]
Description=Xray Service
Documentation=https://xtls.github.io/
After=network.target nss-lookup.target
[Service]
User=xray
Group=xray
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
NoNewPrivileges=yes
UMask=0077
ExecStart=$XRAY_BIN run -config $XRAY_CONFIG
Restart=on-failure
RestartPreventExitStatus=23
LimitNPROC=10000
LimitNOFILE=1000000
RuntimeDirectory=xray
RuntimeDirectoryMode=0755
[Install]
WantedBy=multi-user.target
EOF
    ensure_file "$tmp" "$XRAY_UNIT" 0644 root root
    (( FILE_CHANGED == 0 )) || systemctl daemon-reload
    say '补齐本工具中断安装留下的缺失服务文件；复用现有二进制。'
}

setup_xray() {
    local installer downloaded tmp sockets config_changed=0
    step '检查或安装 Xray 后端'
    load_xray
    if [[ "$XRAY_STATE" == empty ]]; then
        [[ ! -e "$STATE_DIR/xray.complete" ]] || die '曾完成部署，但现有配置已丢失或为空；停止以避免生成新 UUID，请先恢复配置备份。'
        if [[ -e "$XRAY_BIN" || -e "$XRAY_UNIT" || -e "$(dirname -- "$XRAY_CONFIG")" ]] &&
            [[ ! -f "$STATE_DIR/install.started" ]]; then
            die '发现已有 Xray 文件，但不是可复用的本方案配置。未覆盖；请先检查原安装。'
        fi
        sockets="$(ss -H -ltn "sport = :$XRAY_PORT")"
        [[ -z "$sockets" ]] || die "端口 $XRAY_PORT 已被占用，请检查或修改 deploy.conf 中的 XRAY_PORT。"
        if [[ -e "$XRAY_BIN" ]]; then
            check_binary_version
            say '二进制已安装，仅补齐未完成配置，不重新运行安装器。'
        else
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
          mark_once "$STATE_DIR/install.started"
          INSTALL_IN_PROGRESS=1
          say "安装 $XRAY_VERSION；安装器会另行校验发行包 SHA256。"
        # Clear installer overrides so inherited shell variables cannot redirect files.
          DEBIAN_FRONTEND=noninteractive NEEDRESTART_SUSPEND=1 \
          env -u JSON_PATH -u JSONS_PATH -u DAT_PATH -u XRAY_CUSTOMIZE \
            timeout 600 bash "$installer" install --version "$XRAY_VERSION" \
            --without-geodata --without-logfiles --no-update-service 9>&-
          if systemctl is-active --quiet xray; then systemctl stop xray; fi
          check_binary_version
        fi
        complete_xray_unit
        id xray >/dev/null
        [[ "$(id -u xray)" != 0 && "$(id -g xray)" != 0 ]] || die 'xray 运行账户或组错误。'
        load_xray
        [[ "$XRAY_STATE" == empty ]] || die '安装后出现了意外的非空配置，未覆盖。'
        step '生成并校验独立 UUID、XHTTP 路径和配置'
        XRAY_UUID="$("$XRAY_BIN" uuid)"
        XRAY_PATH="/api/$(openssl rand -hex 16)/"
        ensure_dir "$(dirname -- "$XRAY_CONFIG")" 0750 root xray
        tmp="$(mktemp "$(dirname -- "$XRAY_CONFIG")/config.XXXXXX.json")"
        TEMP_FILES+=("$tmp")
        python3 "$TOOL" xray-write "$tmp" "$XRAY_UUID" "$XRAY_PATH" "$XRAY_PORT"
        chown root:xray "$tmp"
        chmod 0640 "$tmp"
        runuser -u xray -- "$XRAY_BIN" run -test -config "$tmp"
        load_xray
        [[ "$XRAY_STATE" == empty ]] || die '生成配置期间现有配置发生了变化，未覆盖。'
        mv -f -- "$tmp" "$XRAY_CONFIG"
        config_changed=1
        say '凭据已写入 Xray 配置；后续重复执行会复用它们。'
    else
        check_binary_version
        say '已有匹配的 Xray 配置；保留二进制、UUID、路径和其他配置。'
    fi
    # Complete only missing/changed files from our own unfinished installation.
    if [[ -f "$STATE_DIR/install.started" && ! -f "$STATE_DIR/xray.complete" ]]; then
        complete_xray_unit
        ensure_dir "$(dirname -- "$XRAY_DROPIN")" 0755 root root
        tmp="$(mktemp "$STATE_DIR/restart.XXXXXX")"
        TEMP_FILES+=("$tmp")
        printf '[Service]\nRestart=on-failure\nRestartSec=5s\n' \
            > "$tmp"
        ensure_file "$tmp" "$XRAY_DROPIN" 0644 root root
        (( FILE_CHANGED == 0 )) || systemctl daemon-reload
        # A prior run may have exited after the rename but before daemon-reload.
        if [[ "$(systemctl show xray -p NeedDaemonReload --value)" == yes ]]; then
            say '检测到中断前写入的服务配置尚未加载，补做 daemon-reload。'
            systemctl daemon-reload
        fi
    fi
    check_version_and_unit
    if [[ "$(systemctl is-enabled xray 2>/dev/null || true)" != enabled ]]; then systemctl enable xray; fi
    if ! systemctl is-active --quiet xray; then
        INSTALL_IN_PROGRESS=1
        systemctl start xray
    elif (( config_changed )) || { [[ -f "$STATE_DIR/install.started" && ! -f "$STATE_DIR/xray.complete" ]] &&
        ! xray_probe; }; then
        INSTALL_IN_PROGRESS=1
        say '补齐本工具未完成的配置后，需要使配置在运行进程中生效。'
        systemctl restart xray
    else
        say 'Xray 已运行，跳过 start/restart。'
    fi
    local attempt ready=0
    for attempt in {1..10}; do
        if xray_probe; then
            ready=1
            break
        fi
        sleep 1
    done
    (( ready )) || die 'Xray 启动后没有在规定时间内响应，请检查 journalctl。'
    check_backend
    mark_once "$STATE_DIR/xray.complete"
    INSTALL_IN_PROGRESS=0
}

xray_probe() {
    local code
    code="$(curl -q --noproxy '*' -sS --max-time 2 -X OPTIONS -o /dev/null \
        -w '%{http_code}' "http://127.0.0.1:$XRAY_PORT$XRAY_PATH" 2>/dev/null)" || return 1
    [[ "$code" == 200 ]]
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

load_nginx_pending() {
    NGINX_RESUME=0
    [[ ! -L "$STATE_DIR/nginx.pending" ]] || die 'Nginx 未完成记录不能是符号链接。'
    [[ -e "$STATE_DIR/nginx.pending" ]] || return 0
    [[ -f "$STATE_DIR/nginx.pending" ]] || die 'Nginx 未完成记录必须是普通文件。'
    local record=() current
    mapfile -t record < "$STATE_DIR/nginx.pending"
    [[ ${#record[@]} -eq 6 && "${record[0]}" == "$NGINX_SITE" &&
        "${record[3]}" == "$NGINX_BIN" && "${record[4]}" == "$NGINX_MAIN" &&
        "${record[1]}" =~ ^[0-9a-f]{64}$ && "${record[2]}" =~ ^[0-9a-f]{64}$ &&
        "${record[5]}" == "$STATE_DIR/backups/"* && -f "${record[5]}" ]] ||
        die "存在其他站点或异常的未完成记录，请先检查 $STATE_DIR/nginx.pending。"
    NGINX_NEW_HASH="${record[1]}"
    NGINX_OLD_HASH="${record[2]}"
    NGINX_BACKUP="${record[5]}"
    [[ "$(digest "$NGINX_BACKUP")" == "$NGINX_OLD_HASH" ]] || die '未完成部署的备份校验失败，未继续。'
    current="$(digest "$NGINX_SITE")"
    [[ "$current" == "$NGINX_NEW_HASH" || "$current" == "$NGINX_OLD_HASH" ]] ||
        die '未完成部署的站点又发生了其他修改，请先比较备份，不自动覆盖。'
    NGINX_RESUME=1
}

setup_nginx() {
    local candidate change baseline source_hash result staged pending_tmp
    step '检查网站原有 HTTPS 入口'
    baseline="$(https_probe GET /)"
    [[ "$baseline" =~ ^[23][0-9][0-9]\ 2$ ]] || die "现有网站预期返回 2xx/3xx 且使用 HTTP/2，实际 $baseline；未修改站点。"
    load_nginx_pending
    step '比较站点路由与目标配置'
    source_hash="$(digest "$NGINX_SITE")"
    candidate="$(mktemp "$STATE_DIR/nginx-candidate.XXXXXX")"
    TEMP_FILES+=("$candidate")
    change="$(python3 "$TOOL" nginx-write "$NGINX_SITE" "$candidate" "$SITE_DOMAIN" "$XRAY_PATH" "$XRAY_PORT")"
    if [[ "$change" == changed ]]; then
        if (( NGINX_RESUME )); then
            [[ "$source_hash" == "$NGINX_OLD_HASH" && "$(digest "$candidate")" == "$NGINX_NEW_HASH" ]] ||
                die '本次目标与未完成部署不一致，未继续修改。'
            say '复用上次未完成部署的备份。'
        else
            NGINX_OLD_HASH="$source_hash"
            NGINX_NEW_HASH="$(digest "$candidate")"
            NGINX_BACKUP="$STATE_DIR/backups/$(date '+%Y%m%d-%H%M%S')-$$.nginx.conf"
            cp -p -- "$NGINX_SITE" "$NGINX_BACKUP"
            printf '%s\n' "$NGINX_SITE" > "${NGINX_BACKUP}.original-path"
            pending_tmp="$(mktemp "$STATE_DIR/nginx-pending.XXXXXX")"
            TEMP_FILES+=("$pending_tmp")
            printf '%s\n' "$NGINX_SITE" "$NGINX_NEW_HASH" "$NGINX_OLD_HASH" \
                "$NGINX_BIN" "$NGINX_MAIN" "$NGINX_BACKUP" > "$pending_tmp"
            ensure_file "$pending_tmp" "$STATE_DIR/nginx.pending" 0600 root root
        fi
        [[ "$(digest "$NGINX_SITE")" == "$source_hash" &&
            "$(digest "$NGINX_BACKUP")" == "$NGINX_OLD_HASH" ]] || die '生成变更期间站点被其他程序修改，已停止。'
        staged="$(mktemp "$(dirname -- "$NGINX_SITE")/.xray-site.XXXXXX")"
        TEMP_FILES+=("$staged")
        cp -p -- "$NGINX_SITE" "$staged"
        cat -- "$candidate" > "$staged"
        # Recheck after staging too; preparing the replacement can take time.
        [[ "$(digest "$NGINX_SITE")" == "$source_hash" &&
            "$(digest "$NGINX_BACKUP")" == "$NGINX_OLD_HASH" ]] ||
            die "提交前检测到站点或备份被其他程序修改，未覆盖。备份：$NGINX_BACKUP"
        NGINX_PENDING=1
        mv -f -- "$staged" "$NGINX_SITE"
        say "已插入受管 location；备份：$NGINX_BACKUP"
    elif [[ "$change" == unchanged ]]; then
        if (( NGINX_RESUME )); then
            [[ "$source_hash" == "$NGINX_NEW_HASH" ]] || die '未完成记录与当前站点配置不符，未继续。'
            NGINX_PENDING=1
        fi
        say '现有 location 已与本次参数一致，无需改写或新增备份。'
    else
        die '配置工具返回了未知状态。'
    fi
    step '校验 Nginx，按需重载'
    nginx_test
    if [[ "$change" == changed ]]; then
        nginx_reload
    elif (( NGINX_RESUME )); then
        if result="$(https_probe OPTIONS "$XRAY_PATH")" && [[ "$result" == '200 2' ]]; then
            say '上次未完成部署的入口已经生效，跳过重载。'
        else
            say '发现本工具未完成的路由变更，补做重载。'
            nginx_reload
        fi
    else
        say '配置未变化，跳过 Nginx 重载，仅执行入口检查。'
    fi
    check_https
    NGINX_PENDING=0
    if [[ -f "$STATE_DIR/nginx.pending" ]]; then rm -- "$STATE_DIR/nginx.pending"; fi
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
    ensure_file "$tmp" "$STATE_DIR/node.env" 0600 root root
    if (( FILE_CHANGED )); then say "连接参数已保存：$STATE_DIR/node.env（仅 root 可读）。"
    else say "连接参数未变化，保留原文件：$STATE_DIR/node.env"; fi
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
