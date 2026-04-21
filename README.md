# deploy_proxy

个人代理服务器（Vultr Tokyo）的部署维护脚本集合。

目前包含一个脚本：

- **[`v2ray-optimize.sh`](./v2ray-optimize.sh)** — 针对基于 [`mack-a/v2ray-agent`](https://github.com/mack-a/v2ray-agent) 部署的 Xray 服务的**维护/优化脚本**，同时集成官方 [Hysteria2](https://v2.hysteria.network/) 的安装与配置。

---

## 适用场景

本脚本假设你有一台通过 `mack-a/v2ray-agent` v2.x 部署过的 Debian/Ubuntu VPS，目录布局大致如下：

```
/etc/v2ray-agent/
├── xray/
│   ├── xray                # 二进制
│   ├── geoip.dat
│   ├── geosite.dat
│   ├── conf/               # Xray 入站配置
│   └── error.log
└── tls/
    ├── <domain>.crt
    └── <domain>.key
```

如果你还没部署过，请先按 `mack-a/v2ray-agent` 的原始流程跑一遍，本脚本只负责**后续维护 + 接入 Hysteria2**。

---

## 脚本做了什么

| 序号 | 功能 | 说明 |
|:---:|---|---|
| 1 | 清理失效的 `RenewTLS` cron | mack-a 老脚本升级 / 重装后会留下指向已不存在的 `/etc/v2ray-agent/install.sh` 的 cron，每天失败一次。脚本会移除它并交给 `acme.sh` 自带 cron 续证 |
| 2 | 更新 geoip / geosite + 加每周自动更新 | 从 [Loyalsoldier/v2ray-rules-dat](https://github.com/Loyalsoldier/v2ray-rules-dat) 拉最新规则，带完整性校验（< 1 MiB 拒绝替换），并写入 `/usr/local/bin/v2ray-geo-update.sh` + 每周一 04:00 cron |
| 3 | 升级 Xray 到最新版 | 调用官方 `XTLS/Xray-install` 安装器，并同步到 mack-a 的 `/etc/v2ray-agent/xray/xray` 路径 |
| 4 | 配置 logrotate | 为 `xray` 和 `hysteria` 的日志写 `/etc/logrotate.d/*` 配置（weekly / rotate 4 / compress） |
| 5 | 应用内核网络参数调优 | 写入 `/etc/sysctl.d/99-network-tune.conf`：BBR + fq、TCP / socket buffer 放大、PMTU probing、TFO 等，针对 VPS 翻墙场景做了优化 |
| 6 | **安装 / 重装 Hysteria2** | 走官方 `get.hy2.sh`，自动检测已有证书与老密码，生成 `/etc/hysteria/config.yaml`，开 ufw `443/udp`，启动 `hysteria-server.service`，输出 Mihomo YAML + `hysteria2://` URI |
| 7 | 状态检查 | 一键看所有相关服务、版本、端口、geo 文件日期、BBR 状态、cron 列表 |

所有操作**幂等**：同一命令重复跑不会出问题（cron 去重、logrotate 覆盖、hy2 复用老密码）。

---

## 使用方式

### 1. 上传到服务器

```bash
scp v2ray-optimize.sh root@<your-vps>:/root/
ssh root@<your-vps>
chmod +x /root/v2ray-optimize.sh
```

### 2. 运行

**交互菜单（推荐第一次使用）：**

```bash
bash /root/v2ray-optimize.sh
```

你会看到：

```
================================================
  v2ray-agent 维护 & Hysteria2 安装脚本
================================================

  通用优化
    1) 清理失效 cron (RenewTLS)
    2) 更新 geoip / geosite + 周度自动更新 cron
    3) 升级 Xray 到最新版
    4) 配置 logrotate (xray / hysteria)
    5) 应用内核网络参数调优 (BBR + 大缓冲)
    6) 一键跑完以上 1-5

  Hysteria2
    7) 安装 / 重装 Hysteria2

  整体
    8) 全部执行 (1-5 + 7)
    9) 查看当前状态
    0) 退出
```

**非交互模式（适合放到自动化脚本里）：**

```bash
bash /root/v2ray-optimize.sh --status      # 仅看状态，不改任何东西
bash /root/v2ray-optimize.sh --all         # 通用优化 1-5（不动 Hy2）
bash /root/v2ray-optimize.sh --hy2         # 只装/重装 Hysteria2
bash /root/v2ray-optimize.sh --full        # 通用优化 + Hysteria2
```

### 3. 首次推荐流程

```bash
# a. 先看基线
bash /root/v2ray-optimize.sh --status

# b. 跑通用优化（不碰 hy2）
bash /root/v2ray-optimize.sh --all

# c. 再看一次状态确认
bash /root/v2ray-optimize.sh --status
```

如果 Hysteria2 当前跑得正常，**不必**再 `--hy2` 重装（这步会覆盖 `/etc/hysteria/config.yaml`，虽然脚本会复用老密码）。

---

## Hysteria2 配置细节

第 7 项会：

1. 执行官方安装器 `bash <(curl -fsSL https://get.hy2.sh/)` 拉取最新二进制并注册 `hysteria-server.service`
2. **自动检测**
   - 域名：先看 `/etc/v2ray-agent/tls/*.crt`，再看 `~/.acme.sh/` 列表
   - 证书：同时支持 mack-a 路径和 acme.sh 默认路径（`_ecc` 后缀也会尝试）
   - 老密码：如果 `/etc/hysteria/config.yaml` 存在就复用，不存在则生成 24 字节 URL-safe 随机串
3. **可用环境变量覆盖默认**
   ```bash
   HY2_DOMAIN=yourdomain.com \
   HY2_PASSWORD=yourpassword \
   HY2_PORT=443 \
   HY2_UP="500 mbps" \
   HY2_DOWN="500 mbps" \
   HY2_MASQ=https://www.bing.com/ \
     bash /root/v2ray-optimize.sh --hy2
   ```
4. 写出的 `config.yaml` 关键参数
   - `bandwidth`：上下行各 500 mbps（给 BBR / Brutal 留 headroom）
   - `ignoreClientBandwidth: false`：信任客户端上报（避免拥塞）
   - `masquerade`：指向 Bing，对主动探测伪装成普通站
   - `quic`：放大了接收窗口（8M/20M），`maxIncomingStreams: 1024`
5. ufw 自动放行 `${HY2_PORT}/udp`
6. 启动后在终端打印：
   - Mihomo / Clash Meta 的 YAML 片段（可直接粘到客户端配置里）
   - `hysteria2://<password>@<domain>:<port>/?sni=<domain>#hy2-<domain>` 连接串

---

## 安全保障

- `set -Eeuo pipefail` —— 任何一步报错立即中止并打印出错行号
- `trap ERR` —— 统一日志输出 `/var/log/v2ray-optimize.log`
- geo 下载做了大小校验（< 1 MiB 视为损坏，拒绝替换）
- Hysteria2 启动失败会自动 `journalctl -n 20` 打印最近日志
- 所有文件操作都是幂等的 → 安全地重复跑

---

## 不做什么

- ❌ **不会**改 `mack-a/v2ray-agent` 原脚本本身（升级下次就被覆盖，没意义）
- ❌ **不会**修改 Xray 的入站配置（VLESS/Trojan 等），只动 Xray 二进制和 geo 数据
- ❌ **不会**动 Nginx 配置（除非手动操作）
- ❌ **不会**改防火墙已有规则，只在装 Hy2 时**新增**一条 `${HY2_PORT}/udp`

如果需要更激进的操作（比如升级 mack-a 脚本本身到 v3.x、换 Reality、关闭未使用入站），请手动进行，本脚本定位就是**"低风险常规维护 + Hysteria2 接入"**。

---

## 日志位置

| 用途 | 路径 |
|---|---|
| 脚本自身运行日志 | `/var/log/v2ray-optimize.log` |
| geo 周更 cron 日志 | `/var/log/v2ray-optimize.log`（与上面合并） |
| Xray 日志 | `/etc/v2ray-agent/xray/error.log` |
| Hysteria2 日志 | `journalctl -u hysteria-server -f` |

---

## 已知限制

- 仅测试过 Debian / Ubuntu + systemd + ufw。CentOS / firewalld 需要微调。
- 依赖 `curl` / `awk` / `sed` / `systemctl` 已存在（99% 的服务器都有）。
- 如果 acme.sh 装在非 `root` 用户下，`--install-cronjob` 那一步要手动执行。

---

## 变更记录

- 2026-04-21 — 初版，整合紧急修复 + Hy2 安装
