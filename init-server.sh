#!/usr/bin/env bash
# ============================================================================
#  init-server.sh
#  ---------------------------------------------------------------------------
#  全新 Debian / Ubuntu VPS 一键部署脚本。安装：
#
#    1. 基础依赖 + ufw 防火墙
#    2. BBR + 内核网络调优
#    3. Xray-core (官方 XTLS/Xray-install)
#       - VLESS + Reality (无需域名/证书)
#       - VLESS + XTLS-Vision + TLS (需域名+证书)
#    4. acme.sh (仅在提供域名时) + Let's Encrypt 证书
#    5. Hysteria2 (官方 get.hy2.sh, 仅在提供域名时)
#    6. logrotate + 周度 geo 规则更新
#
#  用法:
#     sudo bash init-server.sh                 # 交互提示
#     sudo DOMAIN=yehen.life EMAIL=me@x.com \
#       bash init-server.sh                    # 非交互
#     sudo SKIP_DOMAIN=1 bash init-server.sh   # 只装 Reality
#
#  环境变量 (全部可选):
#     DOMAIN            域名 (已 DNS A/AAAA 解析到本机)
#     EMAIL             Let's Encrypt 注册邮箱
#     SKIP_DOMAIN=1     明确跳过域名/证书 (只装 Reality)
#     REALITY_PORT      默认 443
#     REALITY_DEST      默认 www.microsoft.com:443 (偷用的真站)
#     REALITY_SNI       默认 www.microsoft.com
#     VISION_PORT       默认 10443
#     HY2_PORT          默认 8443 (若与 Reality 不同端口更稳)
#     HY2_MASQ          默认 https://www.bing.com/
#
#  目录布局 (兼容 v2ray-optimize.sh):
#     /etc/v2ray-agent/
#       ├── xray/
#       │   ├── xray              -> /usr/local/bin/xray (symlink)
#       │   ├── geoip.dat
#       │   ├── geosite.dat
#       │   └── conf/*.json
#       └── tls/
#           ├── <domain>.crt
#           └── <domain>.key
#     /etc/hysteria/config.yaml
# ============================================================================

set -Eeuo pipefail

# ---------- 常量 ----------
readonly SCRIPT_NAME="$(basename "$0")"
readonly V2RAY_DIR="/etc/v2ray-agent"
readonly XRAY_DIR="${V2RAY_DIR}/xray"
readonly XRAY_CONF_DIR="${XRAY_DIR}/conf"
readonly TLS_DIR="${V2RAY_DIR}/tls"
readonly HY_CONFIG_DIR="/etc/hysteria"
readonly HY_CONFIG="${HY_CONFIG_DIR}/config.yaml"
readonly LOG_FILE="/var/log/init-server.log"
readonly INFO_FILE="/root/proxy-credentials.txt"

# ---------- 默认端口 / 参数 ----------
REALITY_PORT="${REALITY_PORT:-443}"
REALITY_DEST="${REALITY_DEST:-www.microsoft.com:443}"
REALITY_SNI="${REALITY_SNI:-www.microsoft.com}"
VISION_PORT="${VISION_PORT:-10443}"
HY2_PORT="${HY2_PORT:-8443}"
HY2_MASQ="${HY2_MASQ:-https://www.bing.com/}"

# ---------- 颜色 ----------
if [[ -t 1 ]]; then
    C_RED=$'\033[0;31m'; C_GRN=$'\033[0;32m'; C_YLW=$'\033[0;33m'
    C_BLU=$'\033[0;34m'; C_BLD=$'\033[1m'; C_END=$'\033[0m'
else
    C_RED=''; C_GRN=''; C_YLW=''; C_BLU=''; C_BLD=''; C_END=''
fi

# ---------- 日志 ----------
log()  { printf '%b\n' "${C_BLU}[*]${C_END} $*"; echo "[*] $*" >> "$LOG_FILE"; }
ok()   { printf '%b\n' "${C_GRN}[OK]${C_END} $*"; echo "[OK] $*" >> "$LOG_FILE"; }
warn() { printf '%b\n' "${C_YLW}[!]${C_END} $*"; echo "[!] $*" >> "$LOG_FILE"; }
err()  { printf '%b\n' "${C_RED}[x]${C_END} $*"; echo "[x] $*" >> "$LOG_FILE"; }
trap 'err "在第 $LINENO 行失败 (exit=$?)，日志: $LOG_FILE"; exit 1' ERR

# ============================================================================
#  前置检查
# ============================================================================
require_root() {
    [[ $EUID -eq 0 ]] || { err "请用 root 运行: sudo bash $SCRIPT_NAME"; exit 1; }
}

check_os() {
    if ! grep -qiE 'ubuntu|debian' /etc/os-release 2>/dev/null; then
        err "只支持 Debian / Ubuntu"; exit 1
    fi
    mkdir -p "$(dirname "$LOG_FILE")"
    : >> "$LOG_FILE"
}

get_public_ip() {
    curl -4 -fsSL --max-time 5 ifconfig.me 2>/dev/null \
        || curl -4 -fsSL --max-time 5 api.ipify.org 2>/dev/null \
        || hostname -I | awk '{print $1}'
}

prompt_inputs() {
    if [[ -n "${SKIP_DOMAIN:-}" ]]; then
        DOMAIN=""
        return 0
    fi

    if [[ -z "${DOMAIN:-}" ]]; then
        echo
        echo "${C_BLD}是否使用域名?${C_END}"
        echo "  有域名 -> 能装全部三种协议 (Reality + Vision + Hy2)"
        echo "  无域名 -> 只能装 Reality"
        read -rp "域名 (留空跳过): " DOMAIN
    fi

    if [[ -n "$DOMAIN" && -z "${EMAIL:-}" ]]; then
        read -rp "Let's Encrypt 注册邮箱 (证书过期通知): " EMAIL
        [[ -n "$EMAIL" ]] || { err "邮箱不能为空"; exit 1; }
    fi

    if [[ -n "$DOMAIN" ]]; then
        # 校验 DNS 是否指向本机
        local server_ip resolved
        server_ip=$(get_public_ip)
        resolved=$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk 'NR==1{print $1}')
        log "本机公网 IP : $server_ip"
        log "域名解析 IP : ${resolved:-<未解析>}"
        if [[ -z "$resolved" || "$resolved" != "$server_ip" ]]; then
            warn "域名 $DOMAIN 的 A 记录与本机公网 IP 不一致"
            read -rp "仍要继续? Let's Encrypt 签发很可能失败 [y/N] " a
            [[ "$a" =~ ^[Yy]$ ]] || exit 1
        fi
    fi
}

# ============================================================================
#  步骤 1: 基础依赖
# ============================================================================
install_base() {
    log "更新 apt 索引 + 安装基础依赖..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq \
        curl wget jq unzip socat cron ca-certificates \
        iptables ufw net-tools dnsutils openssl \
        logrotate gnupg lsb-release >/dev/null
    ok "基础依赖安装完成"
}

# ============================================================================
#  步骤 2: ufw 防火墙
# ============================================================================
setup_ufw() {
    log "配置 ufw 防火墙..."
    ufw --force reset >/dev/null 2>&1 || true
    ufw default deny incoming >/dev/null
    ufw default allow outgoing >/dev/null
    ufw allow 22/tcp comment "SSH" >/dev/null
    ufw allow "${REALITY_PORT}/tcp" comment "VLESS-Reality" >/dev/null
    if [[ -n "${DOMAIN:-}" ]]; then
        ufw allow 80/tcp comment "acme.sh HTTP-01" >/dev/null
        ufw allow "${VISION_PORT}/tcp" comment "VLESS-Vision" >/dev/null
        ufw allow "${HY2_PORT}/udp" comment "Hysteria2" >/dev/null
    fi
    ufw --force enable >/dev/null
    ok "ufw 已启用，规则：$(ufw status | grep ALLOW | wc -l) 条"
}

# ============================================================================
#  步骤 3: 内核网络调优
# ============================================================================
apply_sysctl() {
    log "应用 BBR + 大缓冲内核参数..."
    cat > /etc/sysctl.d/99-network-tune.conf <<'SYS'
# ---- TCP / socket buffer ----
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.rmem_default = 2097152
net.core.wmem_default = 2097152
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
# ---- BBR + fq ----
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
# ---- PMTU / 高吞吐 ----
net.ipv4.tcp_mtu_probing = 1
net.core.netdev_max_backlog = 16384
net.core.somaxconn = 8192
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_notsent_lowat = 131072
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.ip_forward = 1
SYS
    sysctl --system >/dev/null
    local cc
    cc=$(sysctl -n net.ipv4.tcp_congestion_control)
    ok "内核调优完成，当前拥塞控制: $cc"
}

# ============================================================================
#  步骤 4: 签发证书 (仅 DOMAIN 非空)
# ============================================================================
issue_cert() {
    [[ -n "${DOMAIN:-}" ]] || return 0

    log "安装 acme.sh..."
    if [[ ! -x "$HOME/.acme.sh/acme.sh" ]]; then
        curl -fsSL https://get.acme.sh | sh -s email="$EMAIL" >/dev/null
    fi

    local acme="$HOME/.acme.sh/acme.sh"
    "$acme" --set-default-ca --server letsencrypt >/dev/null

    # 临时停止占用 80 端口的服务 (ufw 已放行)
    systemctl stop nginx 2>/dev/null || true
    systemctl stop apache2 2>/dev/null || true

    log "签发 ECC 证书 for $DOMAIN (standalone, 需 80 端口空闲)..."
    "$acme" --issue -d "$DOMAIN" --standalone --keylength ec-256 --force >/dev/null

    mkdir -p "$TLS_DIR"
    "$acme" --install-cert -d "$DOMAIN" --ecc \
        --fullchain-file "$TLS_DIR/${DOMAIN}.crt" \
        --key-file       "$TLS_DIR/${DOMAIN}.key" \
        --reloadcmd      "systemctl reload xray 2>/dev/null; systemctl reload hysteria-server 2>/dev/null; true" \
        >/dev/null
    chmod 600 "$TLS_DIR/${DOMAIN}".*

    # 安装自动续期 cron
    "$acme" --install-cronjob >/dev/null 2>&1 || true
    ok "证书已签发: $TLS_DIR/${DOMAIN}.crt"
}

# ============================================================================
#  步骤 5: 安装 Xray-core
# ============================================================================
install_xray() {
    log "安装 Xray-core (官方 XTLS/Xray-install)..."
    bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install >/dev/null
    mkdir -p "$XRAY_DIR" "$XRAY_CONF_DIR"
    # 让 mack-a-兼容路径也能找到 xray
    ln -sf /usr/local/bin/xray "$XRAY_DIR/xray"

    # 抓 geo 规则 (Loyalsoldier)
    log "下载 geoip / geosite (Loyalsoldier)..."
    local base="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download"
    curl -fsSL -o "$XRAY_DIR/geoip.dat"   "$base/geoip.dat"
    curl -fsSL -o "$XRAY_DIR/geosite.dat" "$base/geosite.dat"
    ok "Xray 已就绪: $(xray version | head -1)"
}

# ============================================================================
#  步骤 6: 生成 Xray 配置
# ============================================================================
gen_reality_keys() {
    # 输出格式: <private>\n<public>
    /usr/local/bin/xray x25519 2>/dev/null | awk -F': ' '{print $2}' | head -2
}

gen_short_id() { openssl rand -hex 8; }
gen_uuid()     { /usr/local/bin/xray uuid; }

write_xray_config() {
    log "生成 Xray 入站配置..."

    REALITY_UUID=$(gen_uuid)
    local keys; keys=$(gen_reality_keys)
    REALITY_PRIVATE_KEY=$(echo "$keys" | sed -n '1p')
    REALITY_PUBLIC_KEY=$(echo "$keys"  | sed -n '2p')
    REALITY_SHORT_ID=$(gen_short_id)

    # 00_log
    cat > "$XRAY_CONF_DIR/00_log.json" <<JSON
{
  "log": {
    "access": "$XRAY_DIR/access.log",
    "error":  "$XRAY_DIR/error.log",
    "loglevel": "warning"
  }
}
JSON

    # 01 Reality
    cat > "$XRAY_CONF_DIR/01_VLESS_Reality_inbound.json" <<JSON
{
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": ${REALITY_PORT},
      "protocol": "vless",
      "tag": "VLESS-Reality",
      "settings": {
        "clients": [
          { "id": "${REALITY_UUID}", "flow": "xtls-rprx-vision" }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${REALITY_DEST}",
          "xver": 0,
          "serverNames": ["${REALITY_SNI}"],
          "privateKey": "${REALITY_PRIVATE_KEY}",
          "shortIds": ["${REALITY_SHORT_ID}"]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"],
        "routeOnly": true
      }
    }
  ]
}
JSON

    # 02 VLESS-Vision (可选)
    if [[ -n "${DOMAIN:-}" ]]; then
        VISION_UUID=$(gen_uuid)
        cat > "$XRAY_CONF_DIR/02_VLESS_Vision_inbound.json" <<JSON
{
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": ${VISION_PORT},
      "protocol": "vless",
      "tag": "VLESS-Vision",
      "settings": {
        "clients": [
          { "id": "${VISION_UUID}", "flow": "xtls-rprx-vision" }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "tls",
        "tlsSettings": {
          "alpn": ["http/1.1"],
          "certificates": [
            {
              "certificateFile": "${TLS_DIR}/${DOMAIN}.crt",
              "keyFile":         "${TLS_DIR}/${DOMAIN}.key"
            }
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls"],
        "routeOnly": true
      }
    }
  ]
}
JSON
    fi

    # 10 outbounds
    cat > "$XRAY_CONF_DIR/10_outbounds.json" <<'JSON'
{
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" },
    { "protocol": "blackhole", "tag": "blocked" }
  ]
}
JSON

    # 11 DNS
    cat > "$XRAY_CONF_DIR/11_dns.json" <<'JSON'
{
  "dns": {
    "servers": [
      "1.1.1.1",
      "8.8.8.8",
      { "address": "223.5.5.5", "domains": ["geosite:cn"] }
    ]
  }
}
JSON

    # 12 Routing
    cat > "$XRAY_CONF_DIR/12_routing.json" <<'JSON'
{
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      { "type": "field", "outboundTag": "blocked", "protocol": ["bittorrent"] },
      { "type": "field", "outboundTag": "blocked", "ip": ["geoip:private"] }
    ]
  }
}
JSON

    # 让 systemd 读取 conf 目录
    mkdir -p /etc/systemd/system/xray.service.d
    cat > /etc/systemd/system/xray.service.d/override.conf <<CONF
[Service]
ExecStart=
ExecStart=/usr/local/bin/xray run -confdir ${XRAY_CONF_DIR}
CONF
    systemctl daemon-reload

    # 验证配置
    if ! /usr/local/bin/xray run -test -confdir "$XRAY_CONF_DIR" >/dev/null 2>&1; then
        err "Xray 配置校验失败"
        /usr/local/bin/xray run -test -confdir "$XRAY_CONF_DIR" || true
        exit 1
    fi

    systemctl restart xray
    sleep 1
    if systemctl is-active --quiet xray; then
        ok "Xray 启动成功，监听 TCP ${REALITY_PORT}${DOMAIN:+ / ${VISION_PORT}}"
    else
        err "Xray 启动失败"; journalctl -u xray -n 30 --no-pager; exit 1
    fi
}

# ============================================================================
#  步骤 7: 安装 Hysteria2
# ============================================================================
install_hy2() {
    [[ -n "${DOMAIN:-}" ]] || { warn "未提供域名，跳过 Hysteria2"; return 0; }

    log "安装 Hysteria2 (官方 get.hy2.sh)..."
    bash <(curl -fsSL https://get.hy2.sh/) >/dev/null 2>&1

    HY2_PASSWORD=$(head -c 18 /dev/urandom | base64 | tr '+/' '-_' | tr -d '=')

    mkdir -p "$HY_CONFIG_DIR"
    cat > "$HY_CONFIG" <<YAML
listen: :${HY2_PORT}

tls:
  cert: ${TLS_DIR}/${DOMAIN}.crt
  key:  ${TLS_DIR}/${DOMAIN}.key

auth:
  type: password
  password: ${HY2_PASSWORD}

bandwidth:
  up: 500 mbps
  down: 500 mbps

ignoreClientBandwidth: false

masquerade:
  type: proxy
  proxy:
    url: ${HY2_MASQ}
    rewriteHost: true

udpIdleTimeout: 60s

quic:
  initStreamReceiveWindow: 8388608
  maxStreamReceiveWindow: 8388608
  initConnReceiveWindow: 20971520
  maxConnReceiveWindow: 20971520
  maxIdleTimeout: 30s
  maxIncomingStreams: 1024
  disablePathMTUDiscovery: false
YAML
    chmod 640 "$HY_CONFIG"
    chown root:hysteria "$HY_CONFIG" 2>/dev/null || true

    systemctl daemon-reload
    systemctl enable --now hysteria-server.service >/dev/null 2>&1 || systemctl restart hysteria-server
    sleep 2
    if systemctl is-active --quiet hysteria-server; then
        ok "Hysteria2 启动成功，监听 UDP ${HY2_PORT}"
    else
        err "Hysteria2 启动失败"; journalctl -u hysteria-server -n 30 --no-pager; exit 1
    fi
}

# ============================================================================
#  步骤 8: logrotate + geo 周更 cron
# ============================================================================
setup_logrotate_and_cron() {
    log "配置 logrotate 和 geo 周更..."
    cat > /etc/logrotate.d/xray <<'LR'
/etc/v2ray-agent/xray/*.log {
    weekly
    rotate 4
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
}
LR
    cat > /etc/logrotate.d/hysteria <<'LR'
/var/log/hysteria/*.log {
    weekly
    rotate 4
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
}
LR

    cat > /usr/local/bin/v2ray-geo-update.sh <<'GEO'
#!/usr/bin/env bash
set -e
base="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download"
curl -fsSL --retry 3 -o /tmp/geoip.dat   "$base/geoip.dat"
curl -fsSL --retry 3 -o /tmp/geosite.dat "$base/geosite.dat"
[ "$(stat -c%s /tmp/geoip.dat)"   -gt 1048576 ] || { echo "[geo] bad geoip";  exit 1; }
[ "$(stat -c%s /tmp/geosite.dat)" -gt 1048576 ] || { echo "[geo] bad geosite"; exit 1; }
mv /tmp/geoip.dat   /etc/v2ray-agent/xray/geoip.dat
mv /tmp/geosite.dat /etc/v2ray-agent/xray/geosite.dat
systemctl restart xray
echo "[geo] updated at $(date -Is)"
GEO
    chmod +x /usr/local/bin/v2ray-geo-update.sh

    if ! crontab -l 2>/dev/null | grep -q 'v2ray-geo-update.sh'; then
        ( crontab -l 2>/dev/null; echo "0 4 * * 1 /usr/local/bin/v2ray-geo-update.sh >> /var/log/init-server.log 2>&1" ) | crontab -
    fi
    ok "logrotate + 周度 geo 更新 cron 已配置"
}

# ============================================================================
#  步骤 9: 输出客户端连接信息
# ============================================================================
emit_credentials() {
    local ip; ip=$(get_public_ip)
    local host="${DOMAIN:-$ip}"

    {
        echo "========================================================"
        echo "  代理服务器部署完成 - $(date -Is)"
        echo "========================================================"
        echo
        echo "服务器 IP  : $ip"
        [[ -n "${DOMAIN:-}" ]] && echo "域名       : $DOMAIN"
        echo
        echo "--- [1] VLESS + Reality ---"
        echo "地址       : $ip"
        echo "端口       : ${REALITY_PORT}"
        echo "UUID       : ${REALITY_UUID}"
        echo "Flow       : xtls-rprx-vision"
        echo "传输       : tcp"
        echo "安全       : reality"
        echo "SNI        : ${REALITY_SNI}"
        echo "Dest       : ${REALITY_DEST}"
        echo "PublicKey  : ${REALITY_PUBLIC_KEY}"
        echo "ShortId    : ${REALITY_SHORT_ID}"
        echo "Fingerprint: chrome"
        echo
        echo "URI:"
        echo "vless://${REALITY_UUID}@${ip}:${REALITY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${REALITY_PUBLIC_KEY}&sid=${REALITY_SHORT_ID}&type=tcp#Reality-${ip}"
        echo

        if [[ -n "${DOMAIN:-}" ]]; then
            echo "--- [2] VLESS + XTLS-Vision + TLS ---"
            echo "地址       : $DOMAIN"
            echo "端口       : ${VISION_PORT}"
            echo "UUID       : ${VISION_UUID}"
            echo "Flow       : xtls-rprx-vision"
            echo "传输       : tcp"
            echo "安全       : tls"
            echo "SNI        : ${DOMAIN}"
            echo "ALPN       : http/1.1"
            echo "Fingerprint: chrome"
            echo
            echo "URI:"
            echo "vless://${VISION_UUID}@${DOMAIN}:${VISION_PORT}?encryption=none&flow=xtls-rprx-vision&security=tls&sni=${DOMAIN}&fp=chrome&alpn=http%2F1.1&type=tcp#Vision-${DOMAIN}"
            echo

            echo "--- [3] Hysteria2 ---"
            echo "地址       : $DOMAIN"
            echo "端口       : ${HY2_PORT} (UDP)"
            echo "密码       : ${HY2_PASSWORD}"
            echo "SNI        : ${DOMAIN}"
            echo "伪装站点   : ${HY2_MASQ}"
            echo
            echo "URI:"
            echo "hysteria2://${HY2_PASSWORD}@${DOMAIN}:${HY2_PORT}/?sni=${DOMAIN}#Hy2-${DOMAIN}"
            echo
        fi

        echo "========================================================"
        echo "  Mihomo / Clash.Meta YAML 片段"
        echo "========================================================"
        cat <<YAML

proxies:
  - name: "Reality-${host}"
    type: vless
    server: ${ip}
    port: ${REALITY_PORT}
    uuid: ${REALITY_UUID}
    network: tcp
    udp: true
    tls: true
    flow: xtls-rprx-vision
    servername: ${REALITY_SNI}
    reality-opts:
      public-key: ${REALITY_PUBLIC_KEY}
      short-id: ${REALITY_SHORT_ID}
    client-fingerprint: chrome
YAML
        if [[ -n "${DOMAIN:-}" ]]; then
            cat <<YAML

  - name: "Vision-${DOMAIN}"
    type: vless
    server: ${DOMAIN}
    port: ${VISION_PORT}
    uuid: ${VISION_UUID}
    network: tcp
    udp: true
    tls: true
    flow: xtls-rprx-vision
    servername: ${DOMAIN}
    client-fingerprint: chrome
    alpn:
      - http/1.1

  - name: "Hy2-${DOMAIN}"
    type: hysteria2
    server: ${DOMAIN}
    port: ${HY2_PORT}
    password: ${HY2_PASSWORD}
    sni: ${DOMAIN}
    skip-cert-verify: false
    up: "50 Mbps"
    down: "300 Mbps"
YAML
        fi
        echo
    } | tee "$INFO_FILE"

    chmod 600 "$INFO_FILE"
    echo
    ok "凭证已保存到 $INFO_FILE (仅 root 可读)"
}

# ============================================================================
#  主流程
# ============================================================================
main() {
    require_root
    check_os

    echo "${C_BLD}================================================${C_END}"
    echo "${C_BLD}  VPS 一键部署: Xray (Reality/Vision) + Hy2${C_END}"
    echo "${C_BLD}================================================${C_END}"

    prompt_inputs

    install_base
    setup_ufw
    apply_sysctl
    issue_cert
    install_xray
    write_xray_config
    install_hy2
    setup_logrotate_and_cron
    emit_credentials

    ok "全部完成。重启一次服务器让 BBR 完全生效 (可选)。"
}

main "$@"
