#!/usr/bin/env bash
# fieldnotes 部署脚本：虚拟环境 + 依赖 + supervisor 守护（uvicorn 运行，不写日志）
#
# 用法（把本脚本与 fieldnotes.py / fieldnotes.html 放在同一目录）：
#   sudo bash install.sh                     # 装到 /opt/fieldnotes，监听 127.0.0.1:18080
#   sudo bash install.sh --port 9000
#   sudo bash install.sh --user fieldnotes   # 指定运行用户（需已存在）
#   bash install.sh --no-supervisor          # 只建环境与文件，不碰 supervisor（本机自测用）
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

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  sed -n '2,17p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 0
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dir)    APP_DIR="$2"; shift 2 ;;
    --port)   APP_PORT="$2"; shift 2 ;;
    --host)   APP_HOST="$2"; shift 2 ;;
    --user)   RUN_USER="$2"; shift 2 ;;
    --no-supervisor) SKIP_SUPERVISOR=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
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

# ---------- 1. 前置检查 ----------

say "检查运行环境"
command -v "$PYTHON_BIN" >/dev/null 2>&1 || die "找不到 $PYTHON_BIN；用 PYTHON_BIN=/path/to/python3 指定"

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
  echo "    $VENV_UVICORN fieldnotes:app --host $APP_HOST --port $APP_PORT --workers 1 --no-access-log"
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
  run bash -c "supervisorctl restart '$APP_NAME' >/dev/null 2>&1 || true"
  if [ "$DRY_RUN" != "1" ]; then
    supervisorctl status "$APP_NAME" || warn "状态查询失败，检查 supervisor 是否在运行"
  fi
fi

# ---------- 5. 冒烟检查 ----------

if [ "$DRY_RUN" != "1" ] && [ "$SKIP_SUPERVISOR" != "1" ]; then
  say "等待进程就绪并做一次本地探活"
  ok=0
  for _ in $(seq 1 15); do
    sleep 1
    if "$VENV_PY" - "$APP_HOST" "$APP_PORT" <<'PY' 2>/dev/null
import sys, urllib.request
host, port = sys.argv[1], sys.argv[2]
with urllib.request.urlopen(f"http://{host}:{port}/api/gallery", timeout=2) as r:
    sys.exit(0 if r.status == 200 else 1)
PY
    then ok=1; break; fi
  done
  [ "$ok" = "1" ] && echo "    探活通过：/api/gallery 返回 200" || warn "15 秒内未探活成功（日志已按设定丢弃，可用 LOG_MODE=file 重跑排查）"
fi

cat <<EOF

完成。常用命令：
  supervisorctl status $APP_NAME
  supervisorctl restart $APP_NAME
  supervisorctl stop $APP_NAME

访问：http://$APP_HOST:$APP_PORT/   （前面如需 HTTPS/域名，交给你的 Nginx）
日志：$([ "$LOG_MODE" = "file" ] && echo "$LOG_FILE" || echo "不记录（/dev/null）；需要排查时用 LOG_MODE=file 重跑本脚本")
EOF