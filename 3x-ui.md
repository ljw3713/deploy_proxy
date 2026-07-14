# 3X-UI 安装与配置手册

本文记录在 Debian/Ubuntu VPS 上部署 3X-UI，并配置 VLESS、Hysteria2（Hy2）、用户订阅和防火墙的操作。示例域名请按实际情况替换；**密码、UUID、订阅令牌和私钥不要写入仓库。**

## 规划示例

| 用途 | 示例地址/端口 | 协议 |
|---|---|---|
| 管理面板 | `https://panel.example.com:9439/<随机路径>` | TCP |
| 用户订阅 | `https://panel.example.com:2096/<随机订阅路径>/<用户令牌>` | TCP |
| VLESS + TLS + Vision | `node.example.com:10443` | TCP |
| Hysteria2 | `node.example.com:10443` | UDP/QUIC |

TCP 和 UDP 是两套独立的传输层端口空间，因此 VLESS（TCP）与 Hy2（UDP）可以同时使用 `10443`。管理面板、订阅服务和代理入站仍应使用不同的用途和安全策略。

## 1. DNS 与证书准备

在域名 DNS 控制台添加 A 记录，等待解析生效：

| 类型 | 主机记录 | 值 |
|---|---|---|
| A | `panel` | 新服务器公网 IPv4 |
| A | `node` | 新服务器公网 IPv4 |

`panel.example.com` 用于面板与订阅，`node.example.com` 用于代理节点。这样旧服务器可继续使用根域名或其他子域名，不会因为新节点上线而被替换。

在服务器上确认：

```bash
getent ahostsv4 panel.example.com
getent ahostsv4 node.example.com
```

签发 Let's Encrypt 证书前，DNS 必须指向本机，且外网必须可访问 TCP `80`。在 3X-UI 菜单中运行 `x-ui`，选择 **SSL Certificate Management**，为 `panel.example.com` 和 `node.example.com` 分别申请证书。证书文件通常保存于：

```text
/root/cert/<域名>/fullchain.pem
/root/cert/<域名>/privkey.pem
```

不要将证书目录复制到 Git 或通过不安全的聊天渠道发送。

## 2. 安装 3X-UI

可使用本仓库的部署脚本：

```bash
scp deploy-3x-ui.sh root@<服务器IP>:/root/
ssh root@<服务器IP>
chmod 700 /root/deploy-3x-ui.sh
bash /root/deploy-3x-ui.sh
```

脚本会安装 3X-UI、UFW，并放行 SSH、ACME 和随机生成的面板端口。安装完成后运行：

```bash
x-ui settings
systemctl status x-ui --no-pager
```

首次登录地址包含随机 Web 路径。请保存到密码管理器；不要把路径改成常见的 `/`、`/admin` 等。

### 修改面板端口

例如将面板改到 TCP `9439`：

```bash
ufw allow 9439/tcp comment '3X-UI panel'
x-ui
# 选择 Change Port，填入 9439
```

访问时仍须包含随机 Web 路径：

```text
https://panel.example.com:9439/<随机路径>
```

确认新地址可访问后，再移除旧面板端口的防火墙规则。

## 3. 防火墙与云防火墙

服务器 UFW 和云厂商防火墙必须同时允许所需端口。以本文规划为例：

```bash
# 管理与证书
ufw allow 22/tcp comment 'SSH'
ufw allow 80/tcp comment 'ACME HTTP-01'
ufw allow 9439/tcp comment '3X-UI panel'

# 订阅服务
ufw allow 2096/tcp comment '3X-UI subscription'

# VLESS 与 Hysteria2 同号不同协议
ufw allow 10443/tcp comment 'VLESS TLS Vision'
ufw allow 10443/udp comment 'Hysteria2'

ufw status numbered
```

建议：SSH 仅允许自己的固定 IP（若具备固定出口 IP）；面板端口也应尽可能限制来源。修改防火墙前保持一个已登录的 SSH 会话，以防误封自己。

## 4. 创建入站（Inbounds）

### VLESS + TLS + Vision

在 **Inbounds → Add Inbound** 中配置：

- Protocol：`vless`
- Port：`10443`
- Transport：`tcp`
- Security：`tls`
- Flow：`xtls-rprx-vision`（为客户端创建时设置）
- SNI / Server Name：`node.example.com`
- Certificate：`/root/cert/node.example.com/fullchain.pem`
- Key：`/root/cert/node.example.com/privkey.pem`

### Hysteria2

创建另一个入站：

- Protocol：`hysteria`，Version `2`
- Port：`10443`
- Network：`hysteria`
- Security：`tls`
- SNI / Server Name：`node.example.com`
- ALPN：`h3`
- Certificate / Key：使用与上面相同的 `node.example.com` 证书

Hy2 使用 UDP；只放行 TCP `10443` 会导致它无法连接。创建/修改入站后，分别用支持 VLESS Vision 和 Hy2 的客户端实测。

## 5. 创建用户与流量权限

在 **Clients** 中为每人建立一个独立客户端；同一用户可绑定到 VLESS 与 Hy2 两个入站。建议设置：

- 备注：用户名或可识别但不泄露隐私的别名；
- 流量限制：例如每月 `100 GB`；
- 到期时间：按授权时间设置；
- IP 限制：按实际需要设置，避免多设备滥用；
- 订阅：开启该用户的订阅并使用系统自动生成的 token。

不要让不同的人共用 UUID 或 Hy2 密码，否则无法精确统计、撤销和限额。需要停用用户时，在 Clients 中禁用或删除该用户并刷新订阅；必要时重置其订阅 token。

## 6. 配置订阅服务

进入 **Panel Settings → Subscription**（菜单名称可能随版本略有不同）：

1. 打开 **Subscription Service**。
2. 打开 **Clash / Mihomo subscription**，供 Clash Party、Mihomo 等使用。
3. `Listen Domain` 填 `panel.example.com`；`Listen Port` 填 `2096`。
4. 将默认 URI Path `/sub/` 改为高随机路径，例如 `/n7p4z2k8m5q1v9x3/`；路径必须以 `/` 开始和结束。
5. 保持 `Reverse Proxy URI` 为空，除非已用 Nginx/Caddy 在另一个地址反代订阅服务。
6. 选择正确的 `panel.example.com` TLS 证书并保存。

随后从 **Clients → 某用户 → Share / Subscription / QR** 复制链接或二维码：

- Shadowrocket：粘贴通用订阅 URL，或扫描二维码；
- Clash Party：粘贴该用户的 **Clash/Mihomo** 订阅 URL；
- v2rayN / Hiddify：粘贴通用订阅 URL，选择更新订阅。

改变 URI Path 会使旧订阅 URL 失效，需重新分发。随机路径可减少扫描，但用户 token 才是订阅链接的主要访问凭证。

## 7. 验证与维护

服务器侧检查：

```bash
systemctl is-active x-ui
systemctl is-enabled x-ui
ss -lntup | grep -E ':(80|2096|9439|10443)\\b'
ufw status numbered
journalctl -u x-ui -n 100 --no-pager
```

客户端侧至少验证：订阅能更新、VLESS 能连接、Hy2 能连接、流量统计会增加、过期/限额用户会被拒绝。

升级前先备份：

```bash
install -d -m 700 /root/backup/x-ui
cp -a /etc/x-ui/x-ui.db /etc/default/x-ui /root/cert /root/backup/x-ui/
```

数据库、证书和配置文件都含敏感数据。建议使用加密备份（例如 restic 或 age）后再上传到异地存储；3X-UI 内置 Telegram 备份可作为补充，但邮件备份通常需要自行用定时脚本和 SMTP 实现。

## 安全检查清单

- 使用域名证书、强管理员密码和随机面板路径；
- 不暴露默认订阅路径 `/sub/`；
- 面板与 SSH 采用 IP 白名单或 VPN 访问；
- 每人独立 Client、独立流量额度和到期时间；
- 定期更新 3X-UI/Xray，并在更新前备份；
- 仅把必需端口同步放行到 UFW 和云防火墙；
- 不在 Git、截图或公开聊天中泄露订阅 URL、二维码、UUID、密码或私钥。
