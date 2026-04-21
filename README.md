# deploy_proxy

个人代理服务器（Vultr / Linode / DigitalOcean 等）部署与维护脚本集合。

目标是**两条命令把一台全新的 Debian/Ubuntu VPS 变成可用的代理节点**，同时为既有服务器提供常规维护能力。

## 仓库内容

| 脚本 | 用途 | 适用场景 |
|---|---|---|
| [`init-server.sh`](./init-server.sh) | **全新服务器一键部署**：Xray (VLESS+Reality / VLESS+Vision) + Hysteria2 + BBR + 证书 + 防火墙 + 日志轮转 + geo 周更 | **新机器**，从空系统开始 |
| [`v2ray-optimize.sh`](./v2ray-optimize.sh) | **既有服务器日常维护**：清理坏 cron、更新 geo、升级 Xray、补齐 logrotate / sysctl、安装 / 重装 Hysteria2 | **老机器**，已用 `mack-a/v2ray-agent` 或本仓库 `init-server.sh` 部署过 |

两个脚本使用**同一套目录布局**，可以接力使用：新机器跑 `init-server.sh`，以后日常维护跑 `v2ray-optimize.sh`。

---

## 快速开始

### A. 全新 VPS（推荐）

```bash
# 1. SSH 到新机器
ssh root@<vps-ip>

# 2. 下载脚本
curl -fsSL -o /root/init-server.sh \
  https://raw.githubusercontent.com/ljw3713/deploy_proxy/main/init-server.sh
chmod +x /root/init-server.sh

# 3. 执行 —— 交互式会问你域名和邮箱
bash /root/init-server.sh

# 或者非交互
DOMAIN=yehen.life EMAIL=me@example.com bash /root/init-server.sh

# 或者没有域名，只装 Reality
SKIP_DOMAIN=1 bash /root/init-server.sh
```

完成后客户端连接信息会保存到 `/root/proxy-credentials.txt`。

### B. 已有机器的日常维护

```bash
curl -fsSL -o /root/v2ray-optimize.sh \
  https://raw.githubusercontent.com/ljw3713/deploy_proxy/main/v2ray-optimize.sh
chmod +x /root/v2ray-optimize.sh
bash /root/v2ray-optimize.sh           # 交互菜单
bash /root/v2ray-optimize.sh --status  # 仅看状态
bash /root/v2ray-optimize.sh --all     # 跑所有维护项（不碰 Hy2）
```

> 因为仓库是 private，直接 `curl` 需要在 URL 里加 `?token=<PAT>` 或先 `gh auth setup-git` 后 clone。

---

## `init-server.sh` 详细说明

### 部署的内容

| 组件 | 说明 |
|---|---|
| **基础依赖** | `curl / wget / jq / socat / cron / ufw / openssl / dnsutils` 等 |
| **ufw 防火墙** | 默认拒绝入站，仅放行 22/tcp、Reality 端口、(若有域名) 80/443、Vision/Hy2 端口 |
| **BBR + 内核调优** | `/etc/sysctl.d/99-network-tune.conf`：BBR + fq、大 TCP/socket 缓冲、PMTU probing、TFO |
| **acme.sh + ECC 证书** | 仅在提供 `DOMAIN` 时。Let's Encrypt ZeroSSL 可切换，自动续期已写 cron |
| **Xray-core** | 官方 `XTLS/Xray-install` 安装器，最新 release；symlink 到 `/etc/v2ray-agent/xray/xray` 兼容老布局 |
| **VLESS + Reality** | 总是启用。默认监听 `TCP 443`，偷用 `www.microsoft.com:443` 作为 Reality dest（抗主动探测） |
| **VLESS + XTLS-Vision** | 仅在提供域名时启用。默认 `TCP 10443`（避免与 Reality 抢 443）+ 真 TLS 证书 |
| **Hysteria2** | 仅在提供域名时启用。默认 `UDP 8443`，Bing 伪装站，500 Mbps 带宽上限，QUIC 窗口调大 |
| **logrotate** | Xray / Hysteria 日志每周轮转 4 份、compress |
| **geo 规则周更** | `/usr/local/bin/v2ray-geo-update.sh` + 每周一 04:00 cron，从 Loyalsoldier 拉最新 |

### 环境变量（全可选）

| 变量 | 默认值 | 说明 |
|---|---|---|
| `DOMAIN` | — | 已 DNS A 记录解析到本机的域名。留空则只装 Reality |
| `EMAIL` | — | Let's Encrypt 注册邮箱。`DOMAIN` 非空时必填 |
| `SKIP_DOMAIN` | — | 显式跳过域名相关步骤（不会交互提示） |
| `REALITY_PORT` | `443` | Reality 监听的 TCP 端口 |
| `REALITY_DEST` | `www.microsoft.com:443` | Reality 偷用的真实站点 |
| `REALITY_SNI` | `www.microsoft.com` | 对应的 SNI |
| `VISION_PORT` | `10443` | VLESS-Vision 监听的 TCP 端口 |
| `HY2_PORT` | `8443` | Hysteria2 监听的 UDP 端口 |
| `HY2_MASQ` | `https://www.bing.com/` | Hysteria2 伪装站点 |

### DNS 检查

脚本会用 `getent ahostsv4` 解析域名，和 `ifconfig.me` 的公网 IP 比对。不一致会警告（通常意味着 Let's Encrypt 签发会失败），此时可选择继续或中止。

### 输出

脚本末尾会在终端和 `/root/proxy-credentials.txt` 同时输出：

- 每个协议的**字段列表**（UUID / PublicKey / ShortId / 密码 等）
- 每个协议的 **`vless://` / `hysteria2://` URI**（可直接粘到支持的客户端）
- **Mihomo / Clash.Meta YAML 片段**（直接加到 `proxies:` 列表即可）

---

## `v2ray-optimize.sh` 详细说明

针对**已部署环境**的维护。详见脚本顶部注释与菜单。简述：

| 序号 | 功能 |
|:---:|---|
| 1 | 清理失效的 `RenewTLS` cron（mack-a 老脚本常见残留） |
| 2 | 更新 geoip / geosite + 周度 cron |
| 3 | 升级 Xray-core 到最新版 |
| 4 | 配置 logrotate（xray / hysteria） |
| 5 | 应用 BBR + 大缓冲内核参数（和 `init-server.sh` 里那份一致，幂等） |
| 6 | 一键执行 1-5 |
| 7 | 安装 / 重装 Hysteria2（自动复用已有密码和证书） |
| 8 | 全部执行 1-5 + 7 |
| 9 | 状态检查 |

常用：

```bash
bash v2ray-optimize.sh --status   # 只看，不改
bash v2ray-optimize.sh --all      # 1-5
bash v2ray-optimize.sh --hy2      # 只装/重装 Hy2
bash v2ray-optimize.sh --full     # 1-5 + Hy2
```

---

## 目录布局

两个脚本共享：

```
/etc/v2ray-agent/
├── xray/
│   ├── xray                 -> /usr/local/bin/xray (symlink)
│   ├── geoip.dat
│   ├── geosite.dat
│   ├── access.log
│   ├── error.log
│   └── conf/
│       ├── 00_log.json
│       ├── 01_VLESS_Reality_inbound.json
│       ├── 02_VLESS_Vision_inbound.json   (若有域名)
│       ├── 10_outbounds.json
│       ├── 11_dns.json
│       └── 12_routing.json
└── tls/
    ├── <domain>.crt
    └── <domain>.key

/etc/hysteria/
└── config.yaml   (若有域名)

/etc/sysctl.d/99-network-tune.conf
/etc/logrotate.d/{xray,hysteria}
/usr/local/bin/v2ray-geo-update.sh
/root/proxy-credentials.txt
```

Xray 的 systemd unit 通过 drop-in 覆盖 `ExecStart` 为 `-confdir /etc/v2ray-agent/xray/conf`，这样新增 / 修改入站只要往 `conf/` 丢 JSON 文件再 `systemctl restart xray`。

---

## 安全边界

- 脚本本身**不含任何敏感信息**（密码、证书、UUID 都在运行时生成）
- `init-server.sh` 所有生成的凭证写在 `/root/proxy-credentials.txt`（`chmod 600`）
- Reality 不依赖自己的证书，**对旁观者完全像在访问 microsoft.com**
- Vision + Hy2 用同一张 ECC 证书，acme.sh 自动续期
- 所有下载源可信：`XTLS/Xray-install`、`apternative.dev/hy2`、`Loyalsoldier/v2ray-rules-dat`、`letsencrypt.org`

---

## 不做什么（刻意不做）

- ❌ 不装 Nginx（Reality 本身就能抗探测，省一层复杂度）
- ❌ 不改 SSH 配置（改端口 / 禁密码登录的锁死风险太高，按需手动改）
- ❌ 不装多用户管理面板（单人用不到）
- ❌ 不集成 Shadowsocks / Trojan / VMess（已经过时或冗余）

---

## 已知限制

- 仅测试过 **Debian 11/12** 与 **Ubuntu 20.04/22.04/24.04** + systemd + ufw
- CentOS / Rocky + firewalld 未测试（理论上改两处即可）
- `init-server.sh` 默认 `REALITY_PORT=443`，和 Hy2 UDP 共享 443 号没问题（协议不同）；但若本机已有 HTTPS 服务占用 TCP 443，请自行改端口
- Let's Encrypt 对同一域名 60 天内 5 张证书的 rate limit 依然存在，频繁重跑会触发

---

## 变更记录

- 2026-04-21 — 首版
  - `v2ray-optimize.sh` 维护脚本
  - `init-server.sh` 全新服务器一键部署脚本（Reality + Vision + Hy2）
