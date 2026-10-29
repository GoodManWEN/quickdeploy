#!/usr/bin/env bash
# fieldnotes 部署脚本：虚拟环境 + 依赖 + supervisor 守护（uvicorn 运行，不写日志）
#
# 用法（把本脚本与 fieldnotes.py / fieldnotes.html 放在同一目录）：
#   sudo bash install.sh                     # 装到 /opt/fieldnotes，监听 127.0.0.1:18080
#   sudo bash install.sh --port 9000
#   sudo bash install.sh --user fieldnotes   # 指定运行用户（需已存在）
#   bash install.sh --no-supervisor          # 只建环境与文件，不碰 supervisor（本机自测用）
#   bash install.sh --print-nginx            # 只输出宝塔接入说明，不安装或重启
#
# 设计说明：
#   * 用 supervisor 而不是 systemd，按你的要求；脚本不安装 supervisor 本身，
#     缺失时会给出对应发行版的安装命令后退出。
#   * 日志一律丢弃：uvicorn --no-access-log，supervisor 的 stdout/stderr 指向 /dev/null。
#     排查问题时把 LOG_MODE=file 打开即可写到 /var/log/fieldnotes.log。
#   * 幂等：重复执行会更新文件、依赖与配置，然后重启进程。

set -euo pipefail

APP_NAME="${APP_NAME:-fieldnotes}"
APP_DIR="${APP_DIR:-/opt/fieldnotes}"
APP_HOST="${APP_HOST:-127.0.0.1}"
APP_PORT="${APP_PORT:-18080}"
RUN_USER="${RUN_USER:-}"
PYTHON_BIN="${PYTHON_BIN:-python3}"
UVICORN_VERSION="${UVICORN_VERSION:-0.54.0}"
SUPERVISOR_CONF_DIR="${SUPERVISOR_CONF_DIR:-/etc/supervisor/conf.d}"
LOG_MODE="${LOG_MODE:-none}"          # none | file
LOG_FILE="${LOG_FILE:-/var/log/fieldnotes.log}"
SKIP_SUPERVISOR="${SKIP_SUPERVISOR:-0}"
DRY_RUN="${DRY_RUN:-0}"
PRINT_NGINX_ONLY=0

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'EOF'
用法：sudo bash install.sh [选项]
  --dir DIR          安装目录，默认 /opt/fieldnotes
  --port PORT        网站后端端口，默认 18080
  --host HOST        监听地址，默认 127.0.0.1
  --user USER        使用已存在的运行账户
  --no-supervisor    只安装文件和环境，之后手动启动
  --dry-run          预览操作，不安装或启动
  --print-nginx      只输出宝塔反向代理说明；改过端口/地址时同时传入原值
  -h, --help         显示帮助
EOF
  exit 0
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dir|--port|--host|--user)
      if [ $# -lt 2 ] || [ -z "$2" ] || [[ "$2" == --* ]]; then
        printf '参数 %s 缺少取值。\n' "$1" >&2
        exit 2
      fi ;;
  esac
  case "$1" in
    --dir)    APP_DIR="$2"; shift 2 ;;
    --port)   APP_PORT="$2"; shift 2 ;;
    --host)   APP_HOST="$2"; shift 2 ;;
    --user)   RUN_USER="$2"; shift 2 ;;
    --no-supervisor) SKIP_SUPERVISOR=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --print-nginx) PRINT_NGINX_ONLY=1; shift ;;
    -h|--help) usage ;;
    *) echo "未知参数：$1（--help 看用法）" >&2; exit 2 ;;
  esac
done

say()  { printf '\033[1m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[警告]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31m[失败]\033[0m %s\n' "$*" >&2; exit 1; }

run() {
  if [ "$DRY_RUN" = "1" ]; then
    printf '  [dry-run] %s\n' "$*"
    return 0
  fi
  "$@"
}

# 输出的是 Nginx 配置，不直接写入宝塔配置，也不申请证书。
# 两处 location 使用相同的代理参数；所有 Nginx $变量必须保持字面量。
print_proxy_location() {
  printf '%s {\n' "$1"
  cat <<EOF
    proxy_pass $APP_UPSTREAM;
    proxy_http_version 1.1;
    proxy_set_header Host \$host;
    proxy_set_header Connection "";
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$remote_addr;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_connect_timeout 5s;
    proxy_send_timeout 60s;
    proxy_read_timeout 60s;
    proxy_intercept_errors off;
}
EOF
}

print_nginx_instructions() {
  cat <<'EOF'

========== 下一步：手动接入宝塔 Nginx ==========
前提：宝塔的 Nginx 与本服务在同一台主机、同一网络命名空间。

1. 打开「网站 → 对应站点 → 设置 → 配置文件」，先保存原配置副本。
2. 找到 server_name 对应域名的 server { ... }。
   已开启 HTTPS 时，修改含 listen 443 ssl 的 server，不改只负责跳转的 80 server。
3. 将下面 BEGIN / END 之间的整段 Nginx 配置粘贴到这个 server 内：
   推荐紧接 #REWRITE-END 之后、现有的静态文件正则 location 之前。
   没有该标记时，放在证书配置之后、现有 location / include 路由之前。
   两个 location 与 listen、server_name 同级，不要套在另一个 location 内。
4. 若已有 location /，用下方版本替换它，不要添加第二份。
   若已有 BEGIN FIELDNOTES WEB / END FIELDNOTES WEB 标记，则整段替换。
   同时检查「伪静态」及 include 的配置，避免重复 location / 或改写请求到 PHP。
   本站不需要 PHP 伪静态；移除原网站冲突的 rewrite / try_files，勿删除 SSL 验证 include。
   保留 SSL、强制 HTTPS、.well-known 证书验证与敏感文件拦截规则。
   已有独立的 location ^~ /api/<随机路径>/（XHTTP）也保留，与这两个块同级。

下面第一段承接首页和 API；第二段保护应用生成的 HTML/SVG，避免被宝塔静态缓存规则截走。
第二段必须排在现有的静态文件正则 location 之前；已有这些路径的单独规则时先处理冲突。
只复制配置块；说明文字和后面的 SSH 命令不要贴进 conf。

----- BEGIN NGINX CONFIG -----
# BEGIN FIELDNOTES WEB
EOF
  print_proxy_location 'location /'
  printf '\n'
  print_proxy_location 'location ~ ^/(?:index\.html|favicon\.svg|placeholder\.svg|assets/placeholder\.svg)$'
  cat <<'EOF'
# END FIELDNOTES WEB
----- END NGINX CONFIG -----

在宝塔保存并重载 Nginx；若通过 SSH 操作，宝塔默认安装路径的校验/重载命令为：
sudo /www/server/nginx/sbin/nginx -t -c /www/server/nginx/conf/nginx.conf &&
sudo /www/server/nginx/sbin/nginx -s reload -c /www/server/nginx/conf/nginx.conf

以上只给出手动操作说明；本脚本不会替你修改、测试或重载 Nginx。
保存后用浏览器检查自己域名的 /、/api/gallery、/favicon.svg 和联系表单。
若已有 XHTTP 节点，也再检查原节点连接，确认站点改动未影响它。
EOF
  printf '\n本机后端检查命令（绕过代理环境变量）：\n'
  printf 'curl --noproxy '\''*'\'' --fail --show-error --max-time 5 %q\n' "$APP_UPSTREAM/api/gallery"
  printf '\n以后只重新显示这份说明，不安装或重启：\n'
  printf 'PYTHON_BIN=%q bash %q --print-nginx --host %q --port %q\n' \
    "$PYTHON_BIN" "$SRC_DIR/install.sh" "$APP_HOST" "$APP_PORT"
}

# ---------- 1. 前置检查 ----------

say "检查运行环境"
command -v "$PYTHON_BIN" >/dev/null 2>&1 || die "找不到 $PYTHON_BIN；用 PYTHON_BIN=/path/to/python3 指定"

[[ "$APP_PORT" =~ ^[0-9]{1,5}$ ]] || die '端口必须是 1—65535 的数字'
APP_PORT=$((10#$APP_PORT))
(( APP_PORT >= 1 && APP_PORT <= 65535 )) || die '端口必须介于 1 和 65535'
APP_UPSTREAM="$("$PYTHON_BIN" - "$APP_HOST" "$APP_PORT" <<'PY'
import ipaddress
import re
import sys

host, port = sys.argv[1:]
try:
    address = ipaddress.ip_address(host)
except ValueError:
    label = r'[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?'
    if len(host) > 253 or not re.fullmatch(label + r'(?:\.' + label + r')*', host):
        sys.exit('监听地址必须是 IP 或主机名，不含协议、端口、括号或路径。')
else:
    if address.is_unspecified:
        host = '127.0.0.1' if address.version == 4 else '::1'
    if address.version == 6:
        if '%' in host:
            sys.exit('此脚本暂不支持带网卡区域标识的 IPv6 监听地址。')
        host = '[' + host + ']'
print('http://{}:{}'.format(host, port))
PY
)" || die '无法生成后端地址，请检查 --host / --port'

if [ "$PRINT_NGINX_ONLY" = "1" ]; then
  say "仅输出接入说明：$APP_UPSTREAM（未检查服务状态）"
  print_nginx_instructions
  exit 0
fi

PY_OK="$("$PYTHON_BIN" -c 'import sys; print(1 if sys.version_info >= (3, 8) else 0)')"
[ "$PY_OK" = "1" ] || die "需要 Python 3.8 及以上（当前 $("$PYTHON_BIN" -V 2>&1)）"

[ -f "$SRC_DIR/fieldnotes.py" ]   || die "同目录缺少 fieldnotes.py"
[ -f "$SRC_DIR/fieldnotes.html" ] || die "同目录缺少 fieldnotes.html"

if [ "$SKIP_SUPERVISOR" != "1" ] && [ "$DRY_RUN" != "1" ]; then
  command -v supervisorctl >/dev/null 2>&1 || {
    warn "没找到 supervisorctl。先装 supervisor，再重跑本脚本："
    cat >&2 <<'EOF'
    Debian/Ubuntu:  sudo apt-get install -y supervisor
    RHEL/CentOS:    sudo yum install -y supervisor      # 或 dnf install -y supervisor
    Alpine:         sudo apk add supervisor
EOF
    exit 2
  }
fi

if [ -n "$RUN_USER" ] && [ "$DRY_RUN" != "1" ]; then
  id -u "$RUN_USER" >/dev/null 2>&1 || die "用户 $RUN_USER 不存在；先 useradd 或换 --user"
fi

if [ "$(id -u)" != "0" ] && [ "$SKIP_SUPERVISOR" != "1" ] && [ "$DRY_RUN" != "1" ]; then
  die "写 supervisor 配置与切换用户需要 root，请用 sudo 运行"
fi

# ---------- 2. 落地文件 ----------

say "安装目录：$APP_DIR"
run mkdir -p "$APP_DIR"
if [ "$SRC_DIR" != "$APP_DIR" ]; then
  run install -m 0644 "$SRC_DIR/fieldnotes.html" "$APP_DIR/fieldnotes.html"
  run install -m 0755 "$SRC_DIR/fieldnotes.py"   "$APP_DIR/fieldnotes.py"
fi

# ---------- 3. 虚拟环境与依赖 ----------

say "创建虚拟环境并安装依赖（uvicorn==$UVICORN_VERSION）"
if [ ! -x "$APP_DIR/venv/bin/python" ] && [ ! -x "$APP_DIR/venv/Scripts/python.exe" ]; then
  run "$PYTHON_BIN" -m venv "$APP_DIR/venv"
fi

# Linux 是 bin/，Windows（仅自测时）是 Scripts/
if [ -x "$APP_DIR/venv/bin/python" ]; then
  VENV_PY="$APP_DIR/venv/bin/python"
elif [ -x "$APP_DIR/venv/Scripts/python.exe" ]; then
  VENV_PY="$APP_DIR/venv/Scripts/python.exe"
elif [ "$DRY_RUN" = "1" ]; then
  VENV_PY="$APP_DIR/venv/bin/python"   # 干跑时环境还没建，按 Linux 布局假定
else
  die "虚拟环境创建失败：$APP_DIR/venv 下没有 python"
fi

run "$VENV_PY" -m pip install --quiet --disable-pip-version-check --no-cache-dir \
  "uvicorn==$UVICORN_VERSION"

say "校验应用能否导入（顺带检查内嵌数据完整）"
if [ "$DRY_RUN" != "1" ]; then
  "$VENV_PY" - "$APP_DIR" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import fieldnotes  # noqa: E402

items = fieldnotes.json.loads(fieldnotes.GALLERY_JSON)["items"]
assert len(items) == 24, f"图集条数异常：{len(items)}"
assert fieldnotes.app, "ASGI 应用缺失"
print(f"    OK：{len(items)} 条图集，{len(fieldnotes.GALLERY_BYTES)} 字节公开 JSON")
PY
else
  echo "  [dry-run] 跳过导入校验"
fi

if [ -n "$RUN_USER" ]; then
  say "把 $APP_DIR 归属给 $RUN_USER"
  run chown -R "$RUN_USER":"$RUN_USER" "$APP_DIR"
fi

# ---------- 4. supervisor 配置 ----------

VENV_DIR="$(dirname "$VENV_PY")"
if [ -x "$VENV_DIR/uvicorn" ]; then
  VENV_UVICORN="$VENV_DIR/uvicorn"
elif [ -x "$VENV_DIR/uvicorn.exe" ]; then
  VENV_UVICORN="$VENV_DIR/uvicorn.exe"
else
  VENV_UVICORN="$VENV_DIR/uvicorn"
fi
CONF="$SUPERVISOR_CONF_DIR/$APP_NAME.conf"

if [ "$SKIP_SUPERVISOR" = "1" ]; then
  warn "已跳过 supervisor（--no-supervisor）。手动启动命令："
  printf '    cd %q && %q fieldnotes:app --host %q --port %q --workers 1 --no-access-log\n' \
    "$APP_DIR" "$VENV_UVICORN" "$APP_HOST" "$APP_PORT"
else
  say "写入 supervisor 配置：$CONF"
  run mkdir -p "$SUPERVISOR_CONF_DIR"

  LOG_LINES="stdout_logfile=/dev/null
stdout_logfile_maxbytes=0
stderr_logfile=/dev/null
stderr_logfile_maxbytes=0"
  if [ "$LOG_MODE" = "file" ]; then
    LOG_LINES="stdout_logfile=$LOG_FILE
stdout_logfile_maxbytes=10MB
stdout_logfile_backups=2
stderr_logfile=$LOG_FILE
stderr_logfile_maxbytes=10MB
stderr_logfile_backups=2"
  fi

  USER_LINE=""
  [ -n "$RUN_USER" ] && USER_LINE="user=$RUN_USER"

  CONF_BODY="$(cat <<EOF
; 由 install.sh 生成。改端口/用户请重新跑脚本，不要手改后忘记 reload。
[program:$APP_NAME]
directory=$APP_DIR
command=$VENV_UVICORN fieldnotes:app --host $APP_HOST --port $APP_PORT --workers 1 --no-access-log --log-level warning
$USER_LINE
autostart=true
autorestart=true
startsecs=3
startretries=3
stopsignal=TERM
stopwaitsecs=10
stopasgroup=true
killasgroup=true
environment=PYTHONUNBUFFERED="1",PYTHONDONTWRITEBYTECODE="1"
$LOG_LINES
EOF
)"

  if [ "$DRY_RUN" = "1" ]; then
    echo "  [dry-run] 将写入 $CONF："
    printf '%s\n' "$CONF_BODY" | sed 's/^/    /'
  else
    tmp_conf="$(mktemp)"
    printf '%s\n' "$CONF_BODY" > "$tmp_conf"
    install -m 0644 "$tmp_conf" "$CONF"
    rm -f "$tmp_conf"
  fi

  say "让 supervisor 加载并重启"
  run supervisorctl reread
  run supervisorctl update
  run supervisorctl restart "$APP_NAME"
  if [ "$DRY_RUN" != "1" ]; then
    supervisorctl status "$APP_NAME" || die "服务状态检查失败，检查 supervisor 是否在运行"
  fi
fi

# ---------- 5. 冒烟检查 ----------

if [ "$DRY_RUN" != "1" ] && [ "$SKIP_SUPERVISOR" != "1" ]; then
  say "等待进程就绪并做一次本地探活"
  ok=0
  for _ in $(seq 1 15); do
    sleep 1
    if "$VENV_PY" - "$APP_UPSTREAM/api/gallery" <<'PY' 2>/dev/null
import json, sys, urllib.request
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
with opener.open(sys.argv[1], timeout=2) as r:
    payload = json.load(r)
    sys.exit(0 if r.status == 200 and isinstance(payload, dict)
             and isinstance(payload.get('items'), list) and len(payload['items']) == 24 else 1)
PY
    then ok=1; break; fi
  done
  [ "$ok" = "1" ] || die "15 次本地探活未通过；未输出部署成功或接入配置。可用 LOG_MODE=file 重跑排查"
  echo "    探活通过：/api/gallery 返回 200，包含 24 条图集"
fi

if [ "$DRY_RUN" = "1" ]; then
  say '预览结束：没有安装或启动服务；以下接入配置仅供预览。'
elif [ "$SKIP_SUPERVISOR" = "1" ]; then
  say '文件与环境已准备好；尚未启动或探活，请先执行上面的手动启动命令。'
else
  say '部署完成，本机网站服务探活通过。'
fi

cat <<EOF

Supervisor 模式下的常用命令：
  supervisorctl status $APP_NAME
  supervisorctl restart $APP_NAME
  supervisorctl stop $APP_NAME

本机后端：$APP_UPSTREAM/
日志：$([ "$LOG_MODE" = "file" ] && echo "$LOG_FILE" || echo "不记录（/dev/null）；需要排查时用 LOG_MODE=file 重跑本脚本")
EOF

print_nginx_instructions
