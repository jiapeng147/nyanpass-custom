#!/usr/bin/env bash

set -Eeuo pipefail

REPOSITORY_URL="https://github.com/jiapeng147/nyanpass-custom.git"
INSTALL_DIR="${INSTALL_DIR:-/opt/nyanpass}"
DOMAIN="${DOMAIN:-}"
ADMIN_USERNAME="${ADMIN_USERNAME:-admin}"
DEPLOY_MODE="${DEPLOY_MODE:-auto}"

log() {
  printf '\n[%s] %s\n' "nyanpass" "$*"
}

fail() {
  printf '\n[nyanpass] 错误：%s\n' "$*" >&2
  exit 1
}

ask() {
  local prompt="$1"
  local default_value="${2:-}"
  local answer

  if [ ! -r /dev/tty ]; then
    printf '%s' "$default_value"
    return
  fi

  if [ -n "$default_value" ]; then
    read -r -p "$prompt [$default_value]: " answer </dev/tty
    printf '%s' "${answer:-$default_value}"
  else
    read -r -p "$prompt: " answer </dev/tty
    printf '%s' "$answer"
  fi
}

install_docker() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    return
  fi

  log "正在安装 Docker 和 Docker Compose..."

  if command -v apt-get >/dev/null 2>&1; then
    apt-get update
    apt-get install -y ca-certificates curl git
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y ca-certificates curl git
  elif command -v yum >/dev/null 2>&1; then
    yum install -y ca-certificates curl git
  else
    fail "无法识别系统包管理器，请先手动安装 Docker、Docker Compose 和 Git。"
  fi

  curl -fsSL https://get.docker.com | sh
  systemctl enable --now docker 2>/dev/null || true
  docker compose version >/dev/null 2>&1 || fail "Docker Compose 安装失败。"
}

ports_are_busy() {
  command -v ss >/dev/null 2>&1 && ss -ltnH 2>/dev/null | awk '{print $4}' | grep -Eq '(^|:)(80|443)$'
}

validate_domain() {
  [[ "$1" =~ ^[A-Za-z0-9.-]+$ ]] || fail "域名格式不正确，请勿包含 http://、https://、端口或路径。"
  [[ "$1" == *.* ]] || fail "请输入完整域名，例如 panel.example.com。"
}

if [ "$(id -u)" -ne 0 ]; then
  fail "请使用 root 执行：curl -fsSL https://raw.githubusercontent.com/jiapeng147/nyanpass-custom/main/install.sh | sudo bash"
fi

[ "$(uname -m)" = "x86_64" ] || fail "当前二进制仅支持 Linux x86_64。"

install_docker

if ! command -v git >/dev/null 2>&1; then
  fail "未找到 Git，请先安装 Git。"
fi

if [ -d "$INSTALL_DIR/.git" ]; then
  log "检测到已有安装，正在更新仓库..."
  git -C "$INSTALL_DIR" pull --ff-only
elif [ -e "$INSTALL_DIR" ] && [ -n "$(find "$INSTALL_DIR" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]; then
  fail "安装目录 $INSTALL_DIR 已存在且非空，请更换 INSTALL_DIR 或先处理该目录。"
else
  log "正在下载 nyanpass..."
  git clone "$REPOSITORY_URL" "$INSTALL_DIR"
fi

cd "$INSTALL_DIR"

case "$DEPLOY_MODE" in
  auto)
    if ports_are_busy; then
      DEPLOY_MODE="backend"
    else
      DEPLOY_MODE="full"
    fi
    ;;
  full|backend) ;;
  *) fail "DEPLOY_MODE 只能是 auto、full 或 backend。" ;;
esac

if [ "$DEPLOY_MODE" = "full" ]; then
  if [ -z "$DOMAIN" ]; then
    DOMAIN="$(ask "请输入已解析到本服务器的域名")"
  fi
  [ -n "$DOMAIN" ] || fail "使用 Caddy HTTPS 部署时必须提供域名。"
  validate_domain "$DOMAIN"
else
  DOMAIN="${DOMAIN:-panel.example.com}"
fi

if [ "$ADMIN_USERNAME" = "admin" ] && [ -r /dev/tty ]; then
  ADMIN_USERNAME="$(ask "请输入管理员用户名" "admin")"
fi

cat > .env <<EOF
DOMAIN=$DOMAIN
ADMIN_USERNAME=$ADMIN_USERNAME
EOF
chmod 600 .env

if [ -f data.db ]; then
  FIRST_INSTALL=0
else
  FIRST_INSTALL=1
  : > initial-admin.txt
  chmod 600 initial-admin.txt
fi

if [ "$DEPLOY_MODE" = "full" ]; then
  log "正在启动后端和 Caddy HTTPS..."
  docker compose up -d
else
  log "检测到 80/443 已被占用，仅启动后端..."
  docker compose stop caddy >/dev/null 2>&1 || true
  docker compose up -d nya
fi

if [ "$FIRST_INSTALL" -eq 1 ]; then
  for _ in $(seq 1 60); do
    if [ -s initial-admin.txt ]; then
      break
    fi
    sleep 1
  done
fi

docker compose ps

if [ "$FIRST_INSTALL" -eq 1 ] && [ ! -s initial-admin.txt ]; then
  docker compose logs --tail=100 nya
  fail "初始化未完成，请根据上面的日志排查。"
elif [ -s initial-admin.txt ]; then
  log "初始管理员信息"
  cat initial-admin.txt
else
  log "数据库已存在，未重新创建管理员。"
fi

if [ "$DEPLOY_MODE" = "full" ]; then
  log "安装完成，请访问：https://$DOMAIN"
else
  log "安装完成。请在现有 Nginx、Caddy、GoEdge 或 CDN 中将域名回源到 http://127.0.0.1:18888"
fi

printf '\n配置目录：%s\n' "$INSTALL_DIR"
printf '查看日志：cd %s && docker compose logs -f nya\n' "$INSTALL_DIR"
