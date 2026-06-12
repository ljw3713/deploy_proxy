# Hysteria2 / Shadowrocket 连接失败与证书续期故障排查记录

## 1. 背景

服务器上运行 Hysteria2，客户端使用 iPhone Shadowrocket 2.2.88 连接 HY2 节点。

节点信息大致如下：

- 服务端：Vultr Tokyo VPS
- 域名：`yehen.life`
- 服务端 IP：`167.179.113.111`
- 协议：Hysteria2
- 端口：UDP `443`
- 证书：Let's Encrypt ECC 证书
- Hysteria 配置文件：`/etc/hysteria/config.yaml`
- 证书路径：
  - `/etc/v2ray-agent/tls/yehen.life.crt`
  - `/etc/v2ray-agent/tls/yehen.life.key`

一开始的现象是：

- 电脑端使用相同 HY2 节点可以正常访问网络。
- iPhone Shadowrocket 使用同一配置无法连接。
- 该配置在前一天仍然正常使用。
- iPhone 重新安装 Shadowrocket 后问题仍然存在。
- Shadowrocket 开启 `允许不安全` 后可以访问。

---

## 2. 初始问题现象

iPhone Shadowrocket 连接失败，但代理日志显示流量已经被 Shadowrocket 捕获并走代理规则。

这说明：

- iPhone VPN 接管流量是生效的。
- Shadowrocket 规则命中是生效的。
- 问题不在 DNS 解析是否进入 Shadowrocket。
- 问题也不是 Shadowrocket 完全没有工作。

随后将排查方向转为：请求是否真正从手机发出、服务器是否收到、服务器是否回包。

---

## 3. 服务器抓包确认链路状态

在服务器上使用 `tcpdump` 抓取来自手机公网 IP 的 UDP 443 流量：

```bash
sudo tcpdump -ni any udp port 443 and host 39.144.40.255
```

抓包显示手机确实向服务器发送了 UDP 包，服务器也有回包：

```text
In  IP 39.144.40.255.51394 > 167.179.113.111.443: UDP, length 1200
Out IP 167.179.113.111.443 > 39.144.40.255.51394: UDP, length 1280
Out IP 167.179.113.111.443 > 39.144.40.255.51394: UDP, length 1210
Out IP 167.179.113.111.443 > 39.144.40.255.51394: UDP, length 99
```

但是手机端的源端口不断变化：

```text
51394
51395
51396
51397
...
```

这说明手机端不断重新发起连接，但没有进入稳定会话。

---

## 4. 与电脑端成功连接进行对照

电脑端使用相同 HY2 节点可以正常访问。服务器抓包时发现电脑端连接有明显不同：

```bash
sudo tcpdump -ni any udp port 443 and host 112.54.232.38
```

电脑成功连接时，源端口保持稳定：

```text
112.54.232.38.57265 > 167.179.113.111.443
```

并且后续出现大量持续双向数据：

```text
UDP, length 1441
UDP, length 33
UDP, length 34
UDP, length 69
...
```

对比后判断：

- 手机请求可以到达服务器。
- 服务器也会向手机回包。
- 但手机端 HY2 / QUIC / TLS 握手没有完成。
- 问题更像是证书校验、SNI、TLS 或客户端侧校验失败，而不是网络完全不通。

---

## 5. 关键发现：开启“允许不安全”后可访问

在 Shadowrocket 的 HY2 节点 TLS 设置中，仅开启 `允许不安全` 后，iPhone 即可正常访问。

这说明：

- 网络链路是通的。
- HY2 密码、端口、服务器地址基本正确。
- 服务端 Hysteria 进程可以正常响应。
- 根因高度集中在 TLS 证书校验失败。

因此排查方向转向服务器证书。

---

## 6. 检查 Hysteria 使用的证书配置

Hysteria systemd 服务如下：

```bash
systemctl cat hysteria-server
```

服务启动命令：

```ini
ExecStart=/usr/local/bin/hysteria server --config /etc/hysteria/config.yaml
User=hysteria
Group=hysteria
```

Hysteria 配置文件：

```bash
cat /etc/hysteria/config.yaml
```

核心配置：

```yaml
listen: :443

tls:
  cert: /etc/v2ray-agent/tls/yehen.life.crt
  key: /etc/v2ray-agent/tls/yehen.life.key

auth:
  type: password
  password: ********
```

可以确认 Hysteria 使用的是本地证书文件：

```text
/etc/v2ray-agent/tls/yehen.life.crt
/etc/v2ray-agent/tls/yehen.life.key
```

---

## 7. 发现证书已经过期

检查证书有效期：

```bash
sudo openssl x509 -in /etc/v2ray-agent/tls/yehen.life.crt -noout -subject -issuer -dates -ext subjectAltName
```

输出：

```text
subject=CN = yehen.life
issuer=C = US, O = Let's Encrypt, CN = E7
notBefore=Mar 14 02:35:49 2026 GMT
notAfter=Jun 12 02:35:48 2026 GMT
X509v3 Subject Alternative Name:
    DNS:yehen.life
```

当时系统时间已经超过 `Jun 12 02:35:48 2026 GMT`，因此证书已经过期。

这解释了为什么：

- Shadowrocket 默认校验证书时连接失败。
- 开启 `允许不安全` 后可以访问。
- 电脑端可能因为客户端行为、缓存、设置或临时忽略校验而仍能使用，但 iPhone Shadowrocket 严格校验证书后失败。

---

## 8. 证书续期过程中遇到的问题

### 8.1 acme.sh 原续期方式不可自动续期

执行：

```bash
~/.acme.sh/acme.sh --renew -d yehen.life --force
```

提示：

```text
It seems that you are using dns manual mode.
```

说明之前证书可能是通过 manual DNS 模式签发的，无法自动完成续期。

---

### 8.2 ZeroSSL 默认 CA 要求邮箱

尝试重新签发时，`acme.sh` 默认 CA 指向 ZeroSSL，提示需要邮箱或 EAB：

```text
No EAB credentials found for ZeroSSL
Please update your account with an email address first.
```

解决方式是切换默认 CA 为 Let's Encrypt：

```bash
~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
```

---

### 8.3 HTTP-01 验证超时

使用 standalone 模式签发：

```bash
~/.acme.sh/acme.sh --issue -d yehen.life --standalone --keylength ec-256 --force --server letsencrypt
```

遇到：

```text
Timeout during connect (likely firewall problem)
```

原因是服务器防火墙未放行 TCP 80，或 80 端口被其他服务占用。

处理：

```bash
sudo ufw allow 80/tcp
sudo systemctl stop nginx
sudo lsof -i :80
```

确认 80 端口空闲后，再次签发成功。

---

## 9. 重新签发并安装证书

成功签发 ECC 证书：

```bash
~/.acme.sh/acme.sh --issue -d yehen.life --standalone --keylength ec-256 --force --server letsencrypt
```

安装证书到 Hysteria 使用的路径：

```bash
~/.acme.sh/acme.sh --install-cert -d yehen.life --ecc \
  --key-file /etc/v2ray-agent/tls/yehen.life.key \
  --fullchain-file /etc/v2ray-agent/tls/yehen.life.crt
```

安装后检查证书：

```bash
sudo openssl x509 -in /etc/v2ray-agent/tls/yehen.life.crt -noout -dates
```

新证书有效期变为未来日期，例如：

```text
notAfter=Sep 10 04:56:42 2026 GMT
```

---

## 10. 续签后 Hysteria 启动失败

证书续签后，Hysteria 服务仍然启动失败：

```bash
sudo systemctl status hysteria-server
sudo journalctl -u hysteria-server -f
```

错误：

```text
FATAL failed to load server config {"error": "invalid config: tls.key: open /etc/v2ray-agent/tls/yehen.life.key: permission denied"}
```

检查证书文件权限：

```bash
ls -l /etc/v2ray-agent/tls/yehen.life.*
```

发现私钥权限类似：

```text
-rw------- 1 root root  227 Jun 12 05:55 yehen.life.key
-rw-r--r-- 1 root root 4807 Jun 12 05:55 yehen.life.crt
```

问题原因：

- Hysteria systemd 服务以 `hysteria` 用户运行。
- 私钥属于 `root:root`，权限为 `600`。
- `hysteria` 用户无法读取私钥。
- 因此服务启动失败。

---

## 11. 权限问题的推荐修复方案

临时方案是让 Hysteria 以 root 用户运行，但这不是最佳实践。

更推荐的做法是保持服务以非 root 用户运行：

```ini
User=hysteria
Group=hysteria
```

然后将私钥所属组改为 `hysteria`，并设置组可读：

```bash
sudo chown root:hysteria /etc/v2ray-agent/tls/yehen.life.key
sudo chmod 640 /etc/v2ray-agent/tls/yehen.life.key

sudo chown root:hysteria /etc/v2ray-agent/tls/yehen.life.crt
sudo chmod 644 /etc/v2ray-agent/tls/yehen.life.crt
```

验证 `hysteria` 用户是否可读：

```bash
sudo -u hysteria test -r /etc/v2ray-agent/tls/yehen.life.key && echo "key readable" || echo "key not readable"
sudo -u hysteria test -r /etc/v2ray-agent/tls/yehen.life.crt && echo "cert readable" || echo "cert not readable"
```

正常输出：

```text
key readable
cert readable
```

然后重载并重启服务：

```bash
sudo systemctl daemon-reload
sudo systemctl restart hysteria-server
sudo systemctl status hysteria-server
```

服务恢复为：

```text
Active: active (running)
```

---

## 12. 最终验证

### 12.1 服务端验证

检查服务状态：

```bash
sudo systemctl status hysteria-server
```

检查 UDP 443 是否监听：

```bash
sudo ss -lunpt | grep ':443'
```

检查证书有效期：

```bash
sudo openssl x509 -in /etc/v2ray-agent/tls/yehen.life.crt -noout -subject -issuer -dates -ext subjectAltName
```

确认：

- `notAfter` 是未来日期。
- `Subject Alternative Name` 包含 `DNS:yehen.life`。
- `hysteria-server` 状态为 `active (running)`。

### 12.2 客户端验证

在 iPhone Shadowrocket 中：

1. 打开 HY2 节点。
2. 进入 TLS 设置。
3. 关闭 `允许不安全`。
4. 保存。
5. 重新连接。
6. 打开 `https://ipinfo.io` 测试。

如果可以正常访问，说明证书校验已经恢复正常。

---

## 13. 最终命令汇总

### 13.1 证书重新签发与安装

```bash
sudo ufw allow 80/tcp
sudo systemctl stop nginx

~/.acme.sh/acme.sh --set-default-ca --server letsencrypt

~/.acme.sh/acme.sh --issue -d yehen.life --standalone --keylength ec-256 --force --server letsencrypt

~/.acme.sh/acme.sh --install-cert -d yehen.life --ecc \
  --key-file /etc/v2ray-agent/tls/yehen.life.key \
  --fullchain-file /etc/v2ray-agent/tls/yehen.life.crt

sudo systemctl start nginx
```

### 13.2 修复 Hysteria 读取证书权限

```bash
sudo chown root:hysteria /etc/v2ray-agent/tls/yehen.life.key
sudo chmod 640 /etc/v2ray-agent/tls/yehen.life.key

sudo chown root:hysteria /etc/v2ray-agent/tls/yehen.life.crt
sudo chmod 644 /etc/v2ray-agent/tls/yehen.life.crt

sudo -u hysteria test -r /etc/v2ray-agent/tls/yehen.life.key && echo "key readable" || echo "key not readable"
sudo -u hysteria test -r /etc/v2ray-agent/tls/yehen.life.crt && echo "cert readable" || echo "cert not readable"

sudo systemctl daemon-reload
sudo systemctl restart hysteria-server
sudo systemctl status hysteria-server
```

### 13.3 检查证书

```bash
sudo openssl x509 -in /etc/v2ray-agent/tls/yehen.life.crt -noout -subject -issuer -dates -ext subjectAltName
```

---

## 14. 经验总结

| 问题 | 表现 | 根因 | 解决方法 |
|---|---|---|---|
| iPhone Shadowrocket 无法连接 HY2 | 代理日志有流量，但无法访问 | TLS 证书过期，校验失败 | 续签证书 |
| 开启 `允许不安全` 后可访问 | 绕过证书校验后正常 | 进一步确认是证书校验问题 | 不建议长期使用，应修复证书 |
| acme.sh 续期失败 | manual DNS 模式提示 | 之前使用 manual DNS 签发 | 改用 standalone 或 DNS API |
| ZeroSSL 要求邮箱 | 无 EAB credentials | acme.sh 默认 CA 为 ZeroSSL | 切换 Let's Encrypt |
| HTTP-01 验证超时 | Timeout during connect | 80 端口未放行或被占用 | 放行 80，停止 nginx |
| Hysteria 启动失败 | permission denied | 私钥 root:root 600，hysteria 用户不可读 | 设置 root:hysteria + 640 |
| 服务安全性 | 以 root 运行可绕过权限问题 | 权限设计不佳 | 推荐保留非 root 用户运行 |

---

## 15. 后续预防措施

### 15.1 确认 acme.sh 自动续期任务

检查 cron：

```bash
crontab -l
sudo crontab -l
```

如果没有，可以添加：

```bash
0 3 * * * /root/.acme.sh/acme.sh --cron --home /root/.acme.sh > /dev/null
```

### 15.2 续期后自动安装证书并重启服务

建议后续给 `--install-cert` 增加 reload 命令：

```bash
~/.acme.sh/acme.sh --install-cert -d yehen.life --ecc \
  --key-file /etc/v2ray-agent/tls/yehen.life.key \
  --fullchain-file /etc/v2ray-agent/tls/yehen.life.crt \
  --reloadcmd "chown root:hysteria /etc/v2ray-agent/tls/yehen.life.key /etc/v2ray-agent/tls/yehen.life.crt && chmod 640 /etc/v2ray-agent/tls/yehen.life.key && chmod 644 /etc/v2ray-agent/tls/yehen.life.crt && systemctl restart hysteria-server"
```

### 15.3 提前检查证书过期时间

定期执行：

```bash
sudo openssl x509 -in /etc/v2ray-agent/tls/yehen.life.crt -noout -dates
```

或者写入定时检查脚本，在证书剩余天数过低时提醒。

---

## 16. 本次最终结论

这次故障的根因不是 Shadowrocket 配置损坏，也不是 HY2 节点失效，而是：

1. `yehen.life` 的 Let's Encrypt 证书已经过期。
2. iPhone Shadowrocket 严格校验证书，导致 HY2 TLS 握手失败。
3. 开启 `允许不安全` 后可以访问，证明网络和服务本身可通。
4. 续签证书后，Hysteria 因为私钥权限无法读取而启动失败。
5. 最终通过重新签发证书、安装到 Hysteria 使用路径、修正私钥权限、重启服务解决。

最终推荐状态：

- Shadowrocket：关闭 `允许不安全`
- Hysteria：以 `hysteria` 用户运行
- 私钥权限：`root:hysteria` + `640`
- 证书权限：`root:hysteria` + `644`
- 证书续期方式：acme.sh + Let's Encrypt + standalone 或 DNS API 自动续期
