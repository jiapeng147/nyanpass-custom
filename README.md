# nyanpass backend（免授权自改版）

nyanpass 后端面板的自定义构建。本仓库包含可直接部署的后端程序、前端文件、IP 数据库和 Docker Compose 配置，不包含任何用户数据。

当前构建无需填写授权码。首次启动会自动初始化数据库，并创建管理员账户。

## 文件说明

| 文件 | 说明 |
|------|------|
| `rel_backend` | Linux x86_64 后端程序 |
| `public/` | 面板前端文件 |
| `qqwry.dat` | IPv4 归属地库 |
| `zxipv6wry.db` | IPv6 归属地库 |
| `docker-compose.yaml` | 后端和 Caddy HTTPS 反向代理 |
| `config.yml.example` | 后端配置模板 |
| `.env.example` | 域名和管理员用户名模板 |
| `caddy/Caddyfile.example` | Caddy 配置 |

## 环境要求

- Linux x86_64 服务器
- Docker 和 Docker Compose
- 一个已解析到服务器公网 IP 的域名
- 公网可以访问服务器的 TCP `80` 和 `443` 端口

## 一键部署

不熟悉 Linux 的用户可以直接执行交互式安装脚本：

```bash
curl -fsSL https://raw.githubusercontent.com/jiapeng147/nyanpass-custom/main/install.sh | sudo bash
```

脚本会自动安装 Docker、下载程序、询问域名、初始化数据库并显示管理员密码。如果检测到 `80/443` 已被占用，会仅启动后端并提示现有反向代理的回源地址。

脚本要求 Linux x86_64。Docker 自动安装主要覆盖 Debian、Ubuntu、CentOS、RHEL、Fedora 和 Alpine Linux；Arch Linux 与 openSUSE 使用发行版软件包安装 Docker。若系统没有 Compose 插件，脚本会从 Docker Compose 官方 GitHub Release 安装 x86_64 CLI 插件。其他系统只要已经安装 Docker、Git、curl 和 `ss`，也可以运行脚本。

不支持 ARM、32 位 Linux、Windows、macOS、Rootless Docker，以及禁止 Docker/host 网络的受限容器或虚拟化环境。脚本不会修改防火墙、安全组、DNS 或现有反向代理；检测到 `80/443` 已占用时默认切换为仅后端模式，不会停止占用端口的服务。

可通过环境变量强制选择部署模式：

```bash
# 使用内置 Caddy，占用 80/443
curl -fsSL https://raw.githubusercontent.com/jiapeng147/nyanpass-custom/main/install.sh | sudo env DEPLOY_MODE=full DOMAIN=panel.example.com bash

# 只启动后端，交给已有反向代理或 CDN
curl -fsSL https://raw.githubusercontent.com/jiapeng147/nyanpass-custom/main/install.sh | sudo env DEPLOY_MODE=backend bash
```

完整的逐步教程见 [`docs/INSTALL.md`](docs/INSTALL.md)。

## 手动快速部署

```bash
git clone https://github.com/jiapeng147/nyanpass-custom.git /opt/nyanpass
cd /opt/nyanpass

cp .env.example .env
sed -i 's/panel.example.com/你的域名/' .env

docker compose up -d
docker compose logs nya
```

首次启动时，后端会自动：

1. 从 `config.yml.example` 生成 `config.yml`。
2. 初始化 `data.db`。
3. 创建管理员账户。
4. 将初始用户名和密码写入 `initial-admin.txt`。

查看初始管理员信息：

```bash
cd /opt/nyanpass
cat initial-admin.txt
```

然后打开：

```text
https://你的域名
```

登录后请立即修改管理员密码。

## 常用命令

```bash
cd /opt/nyanpass

docker compose ps
docker compose logs -f nya
docker compose logs -f caddy
docker compose restart nya
git pull
docker compose up -d
```

## 配置说明

- 后端只监听 `127.0.0.1:18888`，不会直接暴露到公网。
- Caddy 使用 host 网络访问后端，并自动申请和续期 HTTPS 证书。
- 域名在 `.env` 的 `DOMAIN` 中配置。
- 管理员用户名可通过 `.env` 的 `ADMIN_USERNAME` 修改，默认是 `admin`。
- 部署模式保存在 `.env` 的 `DEPLOY_MODE`，可选 `full`、`backend` 或首次安装时使用 `auto` 自动判断。
- `config.yml` 的 `key` 保持为空，无需填写授权码。
- 如果服务器的 `80/443` 已被 Nginx、Caddy、GoEdge 或其他程序占用，请不要启动 Compose 中的 `caddy` 服务，改用现有反向代理转发到 `127.0.0.1:18888`。

仅启动后端：

```bash
docker compose up -d nya
```

现有反向代理的回源配置：

```text
协议：http
地址：127.0.0.1
端口：18888
```

## 恢复备份

先停止服务，再将旧数据库复制到仓库目录：

```bash
cd /opt/nyanpass
docker compose down
cp /你的备份路径/data.db ./data.db
cp /你的备份路径/data.db-wal ./data.db-wal 2>/dev/null || true
cp /你的备份路径/data.db-shm ./data.db-shm 2>/dev/null || true
docker compose up -d
```

恢复已有数据库时不会重新创建管理员。

## 注意

- `data.db*`、`config.yml`、`.env`、`initial-admin.txt` 和 `caddy_data/` 包含敏感信息，请勿提交到 Git。
- 当前仓库提供的是已编译二进制，不包含后端源代码。
- 0919 构建仍可能输出旧授权模块的联网或授权日志，但授权服务器不可用、授权码为空或授权过期均不会阻止面板启动和登录。
