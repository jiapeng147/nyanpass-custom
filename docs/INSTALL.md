# nyanpass 手动安装教程

本文适合不使用 AI、希望逐步完成部署的用户。

## 1. 准备服务器

服务器需要满足：

- Linux x86_64
- 已安装 Docker、Docker Compose 和 Git
- 至少 1 GB 可用内存
- 至少 1 GB 可用磁盘
- 一个解析到服务器公网 IP 的域名

Ubuntu / Debian 可以先安装基础工具：

```bash
sudo apt update
sudo apt install -y ca-certificates curl git
curl -fsSL https://get.docker.com | sudo sh
sudo systemctl enable --now docker
```

确认安装成功：

```bash
docker --version
docker compose version
```

## 2. 下载程序

```bash
sudo git clone https://github.com/jiapeng147/nyanpass-custom.git /opt/nyanpass
cd /opt/nyanpass
```

## 3. 设置域名

先将域名的 A 记录解析到服务器公网 IP，然后执行：

```bash
sudo cp .env.example .env
sudo nano .env
```

内容示例：

```dotenv
DOMAIN=panel.example.com
ADMIN_USERNAME=admin
```

将 `panel.example.com` 改成自己的域名。不要填写 `http://`、`https://` 或路径。

## 4. 启动服务

确保服务器的 `80/443` 没有被其他程序占用：

```bash
sudo ss -ltnp | grep -E ':(80|443) '
```

没有输出时，可以启动后端和 Caddy：

```bash
cd /opt/nyanpass
sudo docker compose up -d
```

Caddy 会自动申请 HTTPS 证书。域名必须已经正确解析，并且云服务器安全组和系统防火墙允许 TCP `80/443`。

## 5. 获取管理员密码

首次启动会自动初始化数据库和管理员：

```bash
sudo cat /opt/nyanpass/initial-admin.txt
```

输出中会显示管理员用户名和随机密码。登录后请立即修改密码。

访问地址：

```text
https://你的域名
```

## 6. 已有反向代理或 CDN

如果 `80/443` 已被 Nginx、Caddy、GoEdge 或其他程序占用，只启动后端：

```bash
cd /opt/nyanpass
sudo docker compose up -d nya
```

在现有反向代理或 CDN 中添加回源：

```text
协议：http
地址：127.0.0.1
端口：18888
```

不要将 `18888` 直接开放到公网。

## 7. 常用维护命令

```bash
cd /opt/nyanpass

sudo docker compose ps
sudo docker compose logs -f nya
sudo docker compose logs -f caddy
sudo docker compose restart nya
sudo git pull
sudo docker compose up -d
```

## 8. 卸载

先停止服务：

```bash
cd /opt/nyanpass
sudo docker compose down
```

确认不再需要数据库后，再手动删除 `/opt/nyanpass`。其中的 `data.db` 包含所有账号和业务数据。

## 9. 常见问题

### 域名打不开

依次检查：

```bash
cd /opt/nyanpass
sudo docker compose ps
sudo docker compose logs --tail=100 nya
sudo docker compose logs --tail=100 caddy
```

确认域名解析正确，并检查安全组、防火墙和 `80/443` 端口占用。

### 找不到管理员密码

```bash
sudo cat /opt/nyanpass/initial-admin.txt
```

如果恢复的是已有 `data.db`，程序不会重新创建管理员。

### 日志显示授权相关信息

当前 0919 构建仍保留旧授权模块的日志，但无需填写授权码。授权服务器不可用、授权码为空或授权过期不会阻止面板启动和登录。
