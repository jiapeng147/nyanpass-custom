# nyanpass backend（自改版 / custom build）

nyanpass 后端面板的自定义修改版。本仓库**只含程序本体**，不含任何个人数据。

## 包含什么

| 文件 | 说明 |
|------|------|
| `rel_backend` | 后端主程序（已改动的二进制） |
| `public/` | 前端文件（index.html / assets 等） |
| `qqwry.dat` | IPv4 归属地库 |
| `zxipv6wry.db` | IPv6 归属地库 |
| `docker-compose.yaml` | 容器编排（nya 后端 + caddy 反代） |
| `config.yml.example` | 配置模板（授权码已清空） |
| `caddy/Caddyfile.example` | 反代模板（域名为占位符） |

## 不包含什么（刻意移除的隐私数据）

- `config.yml` 里的**授权码 key**
- `caddy/Caddyfile` 里的**真实域名**
- `data.db` 及其 WAL —— 所有**账号、节点、转发规则、流量数据**
- `caddy_data/` —— **TLS 证书和私钥**

部署时这些会自动重新生成（证书）或由你手动填入（授权码、域名）。

---

## 这东西怎么用（已部署的情况）

程序跑起来后：

1. caddy 把你的域名反代到后端 `127.0.0.1:18888`（见 `config.yml` 的 `listen`）。
2. 浏览器打开你的域名即可访问面板，首次会让你创建管理员账号。
3. 授权码写在 `config.yml` 的 `key:` 字段，**面板能否启动依赖它有效**（过期会导致容器 crash 重启）。
4. 常用运维：
   ```bash
   cd /opt/backend
   docker compose ps              # 查看状态
   docker compose logs -f nya     # 看后端日志（排查启动失败）
   docker compose restart nya     # 改完 config.yml 后重启生效
   ```

---

## 怎么从零搭建回来（全新服务器）

> 前提：一台 Linux + 已装 Docker / docker compose，一个解析到本机公网 IP 的域名。

```bash
# 1. 拉取本仓库到 /opt/backend
git clone https://github.com/jiapeng147/nyanpass-custom.git /opt/backend
cd /opt/backend

# 2. 生成配置，填入你的授权码
cp config.yml.example config.yml
# 编辑 config.yml，把 key: 后面改成你的真实授权码

# 3. 生成反代配置，填入你的域名
cp caddy/Caddyfile.example caddy/Caddyfile
# 编辑 caddy/Caddyfile，把 your-domain.example 改成你的域名
#   your-domain.example {           ->   np.example.com {
#       reverse_proxy 127.0.0.1:18888
#   }

# 4. 给二进制可执行权限（git 克隆后可能丢失）
chmod +x rel_backend

# 5. 启动
docker compose up -d

# 6. 查看状态 / 日志
docker compose ps
docker compose logs -f nya
```

启动后 caddy 会自动向 Let's Encrypt 申请域名证书（需 80/443 端口可从公网访问），证书存入自动生成的 `caddy_data/`。

浏览器打开 `https://你的域名` → 创建管理员 → 开始用。

### 说明

- `config.yml` 默认监听 `127.0.0.1:18888`，只给 caddy 反代用，不直接对外。
- `caddy/Caddyfile` 里的后端地址：host 网络模式下用 `127.0.0.1:18888` 即可（示例里的 `172.30.242.2` 是旧的 docker 内网地址，按你的网络模式调整）。
- 授权码过期续费后，改回 `config.yml` 的 `key:` 再 `docker compose restart nya`。

## 恢复带数据的备份

如果你另外保存了含 `data.db` 的全量备份，直接把 `data.db*` 覆盖进 `/opt/backend/` 再重启即可，账号/转发规则/流量全部恢复。
