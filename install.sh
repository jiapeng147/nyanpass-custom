#!/usr/bin/env bash

set -Eeuo pipefail

REPOSITORY_URL="https://github.com/jiapeng147/nyanpass-custom.git"
INSTALL_DIR="${INSTALL_DIR:-/opt/nyanpass}"
DOMAIN="${DOMAIN:-}"
ADMIN_USERNAME="${ADMIN_USERNAME:-}"
DEPLOY_MODE="${DEPLOY_MODE:-auto}"
HAS_TTY=0

if [ -t 1 ] && [ -r /dev/tty ]; then
  HAS_TTY=1
fi

log() {
  printf '\n[%s] %s\n' "nyanpass" "$*"
}

warn() {
  printf '\n[nyanpass] 警告：%s\n' "$*" >&2
}

fail() {
  printf '\n[nyanpass] 错误：%s\n' "$*" >&2
  exit 1
}

ask() {
  local prompt="$1"
  local default_value="${2:-}"
  local answer=""

  if [ "$HAS_TTY" -ne 1 ]; then
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

read_env_value() {
  local key="$1"
  local env_file="$2"

  [ -f "$env_file" ] || return 0
  awk -F= -v wanted="$key" '$1 == wanted {sub(/^[^=]*=/, ""); sub(/\r$/, ""); print; exit}' "$env_file"
}

detect_package_manager() {
  if command -v apt-get >/dev/null 2>&1; then
    printf 'apt'
  elif command -v dnf >/dev/null 2>&1; then
    printf 'dnf'
  elif command -v yum >/dev/null 2>&1; then
    printf 'yum'
  elif command -v apk >/dev/null 2>&1; then
    printf 'apk'
  elif command -v pacman >/dev/null 2>&1; then
    printf 'pacman'
  elif command -v zypper >/dev/null 2>&1; then
    printf 'zypper'
  else
    printf 'unknown'
  fi
}

install_base_packages() {
  if command -v curl >/dev/null 2>&1 && command -v git >/dev/null 2>&1 && command -v ss >/dev/null 2>&1; then
    return
  fi

  case "$PACKAGE_MANAGER" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update
      apt-get install -y ca-certificates curl git iproute2
      ;;
    dnf)
      dnf install -y ca-certificates curl git iproute
      ;;
    yum)
      yum install -y ca-certificates curl git iproute
      ;;
    apk)
      apk add --no-cache ca-certificates curl git iproute2
      ;;
    pacman)
      pacman -Syu --noconfirm --needed ca-certificates curl git iproute2
      ;;
    zypper)
      zypper --non-interactive install ca-certificates curl git iproute2
      ;;
    *)
      fail "无法识别系统包管理器。请手动安装 Docker、Docker Compose、Git 和 curl。"
      ;;
  esac
}

start_docker() {
  if command -v systemctl >/dev/null 2>&1; then
    systemctl enable --now docker 2>/dev/null || true
  fi
  if command -v rc-update >/dev/null 2>&1; then
    rc-update add docker default 2>/dev/null || true
  fi
  if command -v service >/dev/null 2>&1; then
    service docker start 2>/dev/null || true
  fi
  if command -v rc-service >/dev/null 2>&1; then
    rc-service docker start 2>/dev/null || true
  fi
}

install_compose_plugin() {
  local plugin_dir="/usr/local/lib/docker/cli-plugins"
  local plugin_path="$plugin_dir/docker-compose"

  docker compose version >/dev/null 2>&1 && return

  log "正在安装 Docker Compose CLI 插件..."
  install -d -m 0755 "$plugin_dir"
  curl -fL --retry 3 --connect-timeout 15 \
    https://github.com/docker/compose/releases/latest/download/docker-compose-linux-x86_64 \
    -o "$plugin_path"
  chmod 0755 "$plugin_path"
  docker compose version >/dev/null 2>&1 || fail "Docker Compose CLI 插件安装失败。"
}

install_docker() {
  if command -v docker >/dev/null 2>&1; then
    install_compose_plugin
    start_docker
    docker info >/dev/null 2>&1 || fail "Docker 已安装，但服务未运行。请先启动 Docker。"
    return
  fi

  log "正在安装 Docker 和 Docker Compose..."

  case "$PACKAGE_MANAGER" in
    apk)
      apk add --no-cache docker docker-cli-compose
      ;;
    pacman)
      pacman -Syu --noconfirm --needed docker docker-compose
      ;;
    zypper)
      zypper --non-interactive install docker
      ;;
    apt|dnf|yum)
      curl -fsSL https://get.docker.com | sh
      ;;
    *)
      fail "当前系统无法自动安装 Docker，请先手动安装。"
      ;;
  esac

  start_docker
  command -v docker >/dev/null 2>&1 || fail "Docker 安装失败。"
  install_compose_plugin
  docker info >/dev/null 2>&1 || fail "Docker 服务未成功启动。"
}

ports_are_busy() {
  if command -v ss >/dev/null 2>&1; then
    ss -ltnH 2>/dev/null | awk '{print $4}' | grep -Eq ':(80|443)$'
    return
  fi

  if command -v netstat >/dev/null 2>&1; then
    netstat -ltn 2>/dev/null | awk 'NR > 2 {print $4}' | grep -Eq ':(80|443)$'
    return
  fi

  awk '$4 == "0A" {split($2, address, ":"); if (address[2] == "0050" || address[2] == "01BB") found=1} END {exit !found}' \
    /proc/net/tcp /proc/net/tcp6 2>/dev/null
}

validate_domain() {
  local label

  [ "${#1}" -le 253 ] || fail "域名总长度不能超过 253 个字符。"
  [[ "$1" =~ ^[A-Za-z0-9.-]+$ ]] || fail "域名格式不正确，请勿包含协议、端口或路径。"
  [[ "$1" == *.* ]] || fail "请输入完整域名，例如 panel.example.com。"
  [[ "$1" != .* && "$1" != *. && "$1" != *..* ]] || fail "域名格式不正确。"

  IFS='.' read -r -a domain_labels <<<"$1"
  for label in "${domain_labels[@]}"; do
    [ "${#label}" -le 63 ] || fail "域名标签长度不能超过 63 个字符。"
    [[ "$label" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || fail "域名中的每一段都必须以字母或数字开头和结尾。"
  done
}

compose_service_running() {
  docker compose ps --status running --services 2>/dev/null | grep -Fxq "$1"
}

show_failure_logs() {
  docker compose ps 2>/dev/null || true
  docker compose logs --tail=100 nya 2>/dev/null || true
  if [ "$DEPLOY_MODE" = "full" ]; then
    docker compose logs --tail=100 caddy 2>/dev/null || true
  fi
}

if [ "$(id -u)" -ne 0 ]; then
  fail "请使用 root 执行：curl -fsSL https://raw.githubusercontent.com/jiapeng147/nyanpass-custom/main/install.sh | sudo bash"
fi

[ "$(uname -s)" = "Linux" ] || fail "此脚本仅支持 Linux。"
[ "$(uname -m)" = "x86_64" ] || fail "当前 rel_backend 仅支持 Linux x86_64。"

PACKAGE_MANAGER="$(detect_package_manager)"
install_base_packages
install_docker

if [ -d "$INSTALL_DIR/.git" ]; then
  log "检测到已有安装，正在更新仓库..."
  git -C "$INSTALL_DIR" pull --ff-only || fail "仓库存在本地修改或无法更新，请进入 $INSTALL_DIR 手动处理。"
elif [ -e "$INSTALL_DIR" ] && [ -n "$(find "$INSTALL_DIR" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]; then
  fail "安装目录 $INSTALL_DIR 已存在且非空，请更换 INSTALL_DIR 或先处理该目录。"
else
  log "正在下载 nyanpass..."
  git clone "$REPOSITORY_URL" "$INSTALL_DIR"
fi

cd "$INSTALL_DIR"

EXISTING_DOMAIN="$(read_env_value DOMAIN .env)"
EXISTING_ADMIN_USERNAME="$(read_env_value ADMIN_USERNAME .env)"
EXISTING_DEPLOY_MODE="$(read_env_value DEPLOY_MODE .env)"

DOMAIN="${DOMAIN:-$EXISTING_DOMAIN}"
ADMIN_USERNAME="${ADMIN_USERNAME:-${EXISTING_ADMIN_USERNAME:-admin}}"

if [ "$DEPLOY_MODE" = "auto" ] && [[ "$EXISTING_DEPLOY_MODE" =~ ^(full|backend)$ ]]; then
  DEPLOY_MODE="$EXISTING_DEPLOY_MODE"
fi

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
  [ -n "$DOMAIN" ] || fail "没有交互终端时，请设置 DOMAIN=panel.example.com 后重新执行。"
  validate_domain "$DOMAIN"
else
  DOMAIN="${DOMAIN:-panel.example.com}"
fi

if [ -z "$ADMIN_USERNAME" ]; then
  ADMIN_USERNAME="admin"
fi
if [ "$ADMIN_USERNAME" = "admin" ] && [ "$HAS_TTY" -eq 1 ] && [ -z "$EXISTING_ADMIN_USERNAME" ]; then
  ADMIN_USERNAME="$(ask "请输入管理员用户名" "admin")"
fi
[[ "$ADMIN_USERNAME" =~ ^[A-Za-z0-9_.-]{1,64}$ ]] || fail "管理员用户名只能包含字母、数字、点、下划线和短横线。"

cat > .env <<EOF
DOMAIN=$DOMAIN
ADMIN_USERNAME=$ADMIN_USERNAME
DEPLOY_MODE=$DEPLOY_MODE
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
  if ports_are_busy && ! compose_service_running caddy; then
    fail "80/443 已被其他程序占用。请停止占用程序，或使用 DEPLOY_MODE=backend 重新运行。"
  fi
  log "正在启动后端和 Caddy HTTPS..."
  if ! docker compose up -d; then
    show_failure_logs
    fail "容器启动失败。"
  fi
else
  log "使用现有反向代理模式，仅启动后端..."
  docker compose stop caddy >/dev/null 2>&1 || true
  if ! docker compose up -d nya; then
    show_failure_logs
    fail "后端启动失败。"
  fi
fi

if [ "$FIRST_INSTALL" -eq 1 ]; then
  for _ in $(seq 1 60); do
    if [ -s initial-admin.txt ]; then
      break
    fi
    sleep 1
  done
fi

for _ in $(seq 1 30); do
  if compose_service_running nya; then
    break
  fi
  sleep 1
done

if ! compose_service_running nya; then
  show_failure_logs
  fail "后端容器没有正常运行。"
fi

if [ "$DEPLOY_MODE" = "full" ] && ! compose_service_running caddy; then
  show_failure_logs
  fail "Caddy 容器没有正常运行，请检查 80/443 端口和域名配置。"
fi

docker compose ps

if [ "$FIRST_INSTALL" -eq 1 ] && [ ! -s initial-admin.txt ]; then
  show_failure_logs
  fail "数据库初始化未完成。"
elif [ -s initial-admin.txt ]; then
  log "初始管理员信息"
  cat initial-admin.txt
else
  log "数据库已存在，未重新创建管理员。"
fi

if [ "$DEPLOY_MODE" = "full" ]; then
  log "安装完成，请访问：https://$DOMAIN"
  warn "如果外网暂时打不开，请检查域名解析、云服务器安全组以及 TCP 80/443。"
else
  log "安装完成。请将现有 Nginx、Caddy、GoEdge 或 CDN 回源到 http://127.0.0.1:18888"
fi

printf '\n配置目录：%s\n' "$INSTALL_DIR"
printf '查看日志：cd %s && docker compose logs -f nya\n' "$INSTALL_DIR"
