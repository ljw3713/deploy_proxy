#!/usr/bin/env bash
# ============================================================================
#  v2ray-optimize.sh
#  ---------------------------------------------------------------------------
#  用于修复 / 优化 mack-a/v2ray-agent v2.7.7 遗留部署的维护脚本，并集成官方
#  Hysteria2 的安装与配置。设计原则：幂等 / 可重入 / 不破坏已有配置。
#
#  用法：
#     sudo bash v2ray-optimize.sh              # 交互式菜单
#     sudo bash v2ray-optimize.sh --all        # 只跑"通用优化"（不动 hy2）
#     sudo bash v2ray-optimize.sh --hy2        # 只安装/重装 Hysteria2
#     sudo bash v2ray-optimize.sh --full       # 通用优化 + Hysteria2
#     sudo bash v2ray-optimize.sh --status     # 仅显示当前状态
#
#  作者：Cursor
#  目标系统：Debian / Ubuntu (systemd, ufw)
# ============================================================================

set -Eeuo pipefail

# ---------- 常量 ----------
readonly SCRIPT_NAME="$(basename "$0")"
readonly V2RAY_DIR="/etc/v2ray-agent"
readonly XRAY_DIR="${V2RAY_DIR}/xray"
readonly TLS_DIR="${V2RAY_DIR}/tls"
readonly HY_CONFIG_DIR="/etc/hysteria"
readonly HY_CONFIG="${HY_CONFIG_DIR}/config.yaml"
readonly LOG_FILE="/var/log/v2ray-optimize.log"

# 颜色
if [[ -t 1 ]]; then
    readonly C_RED=$'\033[0;31m'
    readonly C_GRN=$'\033[0;32m'
    readonly C_YLW=$'\033[0;33m'
    readonly C_BLU=$'\033[0;34m'
    readonly C_BLD=$'\033[1m'
    readonly C_END=$'\033[0m'
else
    readonly C_RED='' C_GRN='' C_YLW='' C_BLU='' C_BLD='' C_END=''
fi

# ---------- 日志 ----------
log()  { printf '%b\n' "${C_BLU}[*]${C_END} $*" | tee -a "$LOG_FILE" >/dev/null; echo "${C_BLU}[*]${C_END} $*"; }
ok()   { printf '%b\n' "${C_GRN}[OK]${C_END} $*" | tee -a "$LOG_FILE" >/dev/null; echo "${C_GRN}[OK]${C_END} $*"; }
warn() { printf '%b\n' "${C_YLW}[!]${C_END} $*" | tee -a "$LOG_FILE" >/dev/null; echo "${C_YLW}[!]${C_END} $*"; }
err()  { printf '%b\n' "${C_RED}[x]${C_END} $*" | tee -a "$LOG_FILE" >/dev/null; echo "${C_RED}[x]${C_END} $*"; }

trap 'err "脚本在第 $LINENO 行失败（exit=$?）。查看 $LOG_FILE"; exit 1' ERR

# ---------- 前置检查 ----------
require_root() {
    if [[ $EUID -ne 0 ]]; then
        err "请用 root 运行：sudo bash $SCRIPT_NAME"
        exit 1
    fi
}

require_cmd() {
    for c in "$@"; do
        command -v "$c" >/dev/null 2>&1 || {
            err "缺少命令：$c  （请先 apt install）"
            exit 1
        }
    done
}

check_os() {
    if ! grep -qiE 'ubuntu|debian' /etc/os-release 2>/dev/null; then
        warn "此脚本仅在 Debian/Ubuntu 上测试过，继续请自负。"
        read -rp "继续? [y/N] " a && [[ "$a" =~ ^[Yy]$ ]] || exit 0
    fi
}

init() {
    require_root
    require_cmd curl grep awk sed systemctl
    mkdir -p "$(dirname "$LOG_FILE")"
    : >> "$LOG_FILE"
    log "日志写入：$LOG_FILE"
}

# ============================================================================
#  1) 清理残留的坏 cron
# ============================================================================
fix_broken_cron() {
    log "清理失效的 RenewTLS cron..."
    if crontab -l 2>/dev/null | grep -q '/etc/v2ray-agent/install.sh RenewTLS'; then
        crontab -l 2>/dev/null | grep -v '/etc/v2ray-agent/install.sh RenewTLS' | crontab -
        ok "已移除坏掉的 RenewTLS cron"
    else
        ok "无需清理（未发现失效 cron）"
    fi

    # 交给 acme.sh 自带 cron 续证书
    if [[ -x "$HOME/.acme.sh/acme.sh" ]]; then
        "$HOME/.acme.sh/acme.sh" --install-cronjob >/dev/null 2>&1 || true
        ok "acme.sh 自动续期任务已就绪"
    else
        warn "未发现 ~/.acme.sh/acme.sh — 如需自动续证书请手动安装 acme.sh"
    fi

    # 清空已堆积的错误日志
    if [[ -f /etc/v2ray-agent/crontab_tls.log ]]; then
        : > /etc/v2ray-agent/crontab_tls.log
        ok "已清空 /etc/v2ray-agent/crontab_tls.log"
    fi
}

# ============================================================================
#  2) 更新 geoip / geosite，并加周度 cron
# ============================================================================
update_geodata() {
    log "更新 geoip.dat / geosite.dat (Loyalsoldier 规则)..."
    if [[ ! -d "$XRAY_DIR" ]]; then
        warn "未发现 $XRAY_DIR，跳过"
        return 0
    fi

    local base="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download"
    local tmp
    tmp=$(mktemp -d)

    curl -fsSL --retry 3 -o "$tmp/geoip.dat"   "$base/geoip.dat"
    curl -fsSL --retry 3 -o "$tmp/geosite.dat" "$base/geosite.dat"

    # 基本完整性检查（> 1 MiB 才算数）
    for f in geoip.dat geosite.dat; do
        local sz
        sz=$(stat -c%s "$tmp/$f")
        if (( sz < 1048576 )); then
            err "$f 下载文件大小异常：$sz bytes"
            rm -rf "$tmp"
            return 1
        fi
    done

    mv "$tmp/geoip.dat"   "$XRAY_DIR/geoip.dat"
    mv "$tmp/geosite.dat" "$XRAY_DIR/geosite.dat"
    rm -rf "$tmp"
    ok "geo 数据已更新 (geoip $(du -h "$XRAY_DIR/geoip.dat" | cut -f1) / geosite $(du -h "$XRAY_DIR/geosite.dat" | cut -f1))"

    # 加 / 更新 cron（每周一 04:00）
    local cron_line='0 4 * * 1 /usr/local/bin/v2ray-geo-update.sh >> /var/log/v2ray-optimize.log 2>&1'
    cat > /usr/local/bin/v2ray-geo-update.sh <<'GEO'
#!/usr/bin/env bash
set -e
cd /etc/v2ray-agent/xray
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
        ( crontab -l 2>/dev/null; echo "$cron_line" ) | crontab -
        ok "已添加每周 geo 更新 cron (周一 04:00)"
    else
        ok "geo 更新 cron 已存在"
    fi

    systemctl is-active --quiet xray && systemctl restart xray && ok "xray 已重启应用新 geo 数据"
}

# ============================================================================
#  3) 升级 Xray 核心
# ============================================================================
upgrade_xray() {
    log "升级 Xray 到最新版..."
    local current
    current=$("$XRAY_DIR/xray" version 2>/dev/null | awk '/^Xray/ {print $2; exit}')
    log "当前版本：${current:-未知}"

    bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

    # 如果是 mack-a 部署的，可执行文件在 /etc/v2ray-agent/xray/xray（软链到 /usr/local/bin/xray）
    if [[ -f /usr/local/bin/xray && ! -L "$XRAY_DIR/xray" ]]; then
        warn "mack-a 脚本使用 $XRAY_DIR/xray，同步一份..."
        cp -f /usr/local/bin/xray "$XRAY_DIR/xray"
        chmod +x "$XRAY_DIR/xray"
    fi

    systemctl restart xray
    local new
    new=$("$XRAY_DIR/xray" version 2>/dev/null | awk '/^Xray/ {print $2; exit}')
    ok "Xray 已升级：${current:-?} -> ${new:-?}"
}

# ============================================================================
#  4) 配置 logrotate
# ============================================================================
setup_logrotate() {
    log "配置 Xray / Hysteria 日志轮转..."
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
    ok "已写入 /etc/logrotate.d/{xray,hysteria}"
}

# ============================================================================
#  5) 内核网络参数调优 (BBR + 大缓冲)
# ============================================================================
apply_sysctl() {
    log "应用内核网络参数调优..."
    local f=/etc/sysctl.d/99-network-tune.conf
    cat > "$f" <<'SYS'
# ---- TCP / socket buffer (BBR 需要大缓冲才能跑满 BDP) ----
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
    ok "已应用 $f (BBR + fq)"
}

# ============================================================================
#  6) Hysteria2 安装 / 重装
# ============================================================================
gen_password() {
    # 24 字节 url-safe base64
    head -c 18 /dev/urandom | base64 | tr '+/' '-_' | tr -d '='
}

detect_domain() {
    # 优先用 mack-a tls 目录里的域名
    if [[ -d "$TLS_DIR" ]]; then
        local d
        d=$(ls "$TLS_DIR"/*.crt 2>/dev/null | head -1 | xargs -n1 basename 2>/dev/null | sed 's/\.crt$//')
        [[ -n "$d" ]] && { echo "$d"; return; }
    fi
    # 其次用 acme.sh
    if [[ -x "$HOME/.acme.sh/acme.sh" ]]; then
        local d
        d=$("$HOME/.acme.sh/acme.sh" --list 2>/dev/null | awk 'NR>1{print $1; exit}')
        [[ -n "$d" ]] && { echo "$d"; return; }
    fi
    echo ""
}

find_cert_pair() {
    local domain="$1"
    # 1) mack-a 路径
    if [[ -f "$TLS_DIR/${domain}.crt" && -f "$TLS_DIR/${domain}.key" ]]; then
        echo "$TLS_DIR/${domain}.crt|$TLS_DIR/${domain}.key"
        return
    fi
    # 2) acme.sh 默认路径
    local acme_dir="$HOME/.acme.sh/${domain}_ecc"
    [[ -d "$acme_dir" ]] || acme_dir="$HOME/.acme.sh/${domain}"
    if [[ -f "$acme_dir/fullchain.cer" && -f "$acme_dir/${domain}.key" ]]; then
        echo "$acme_dir/fullchain.cer|$acme_dir/${domain}.key"
        return
    fi
    echo ""
}

install_hysteria2() {
    log "开始安装 / 重装 Hysteria2 (官方 get.hy2.sh)..."

    # 1. 官方安装器
    bash <(curl -fsSL https://get.hy2.sh/)
    ok "hysteria 二进制已就绪：$(command -v hysteria)"

    # 2. 域名 & 证书
    local domain="${HY2_DOMAIN:-}"
    [[ -z "$domain" ]] && domain=$(detect_domain)
    if [[ -z "$domain" ]]; then
        read -rp "请输入 Hysteria2 使用的域名 (需已解析到本机并有证书): " domain
    else
        log "自动检测到域名：$domain"
    fi
    [[ -z "$domain" ]] && { err "域名不能为空"; return 1; }

    local pair
    pair=$(find_cert_pair "$domain")
    if [[ -z "$pair" ]]; then
        err "未找到 $domain 的证书。请先用 acme.sh 或原脚本签发证书。"
        return 1
    fi
    local cert="${pair%|*}" key="${pair#*|}"
    ok "证书：$cert"
    ok "私钥：$key"

    # 3. 密码
    local password="${HY2_PASSWORD:-}"
    if [[ -z "$password" ]]; then
        if [[ -f "$HY_CONFIG" ]] && grep -q '^  password:' "$HY_CONFIG"; then
            password=$(awk '/^  password:/ {print $2; exit}' "$HY_CONFIG")
            log "复用已有密码"
        else
            password=$(gen_password)
            log "已生成新密码"
        fi
    fi

    # 4. 端口
    local port="${HY2_PORT:-443}"

    # 5. 带宽（可通过 HY2_UP / HY2_DOWN 环境变量覆盖）
    local up="${HY2_UP:-500 mbps}"
    local down="${HY2_DOWN:-500 mbps}"

    # 6. 伪装站点
    local masq="${HY2_MASQ:-https://www.bing.com/}"

    # 7. 写配置
    mkdir -p "$HY_CONFIG_DIR"
    cat > "$HY_CONFIG" <<YAML
listen: :${port}

tls:
  cert: ${cert}
  key: ${key}

auth:
  type: password
  password: ${password}

bandwidth:
  up: ${up}
  down: ${down}

ignoreClientBandwidth: false

masquerade:
  type: proxy
  proxy:
    url: ${masq}
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
    ok "配置已写入 $HY_CONFIG"

    # 8. 防火墙
    if command -v ufw >/dev/null; then
        ufw allow "${port}/udp" comment "Hysteria2" >/dev/null 2>&1 || true
        ok "ufw 放行 ${port}/udp"
    fi

    # 9. 启动
    systemctl daemon-reload
    systemctl enable --now hysteria-server.service >/dev/null 2>&1 || systemctl restart hysteria-server.service
    sleep 2
    if systemctl is-active --quiet hysteria-server; then
        ok "hysteria-server 启动成功"
    else
        err "hysteria-server 启动失败，最近 20 行日志："
        journalctl -u hysteria-server -n 20 --no-pager || true
        return 1
    fi

    # 10. 输出连接信息
    cat <<INFO

${C_BLD}========== Hysteria2 配置信息 ==========${C_END}
  服务器域名 : ${domain}
  端口       : ${port}/udp
  密码       : ${password}
  SNI        : ${domain}
  伪装站点   : ${masq}

  客户端 URI:
  hysteria2://${password}@${domain}:${port}/?sni=${domain}#hy2-${domain}

  客户端 YAML (Mihomo/Clash Meta):
    - name: "Hy2-${domain}"
      type: hysteria2
      server: ${domain}
      port: ${port}
      password: ${password}
      sni: ${domain}
      skip-cert-verify: false
      up: "50 Mbps"
      down: "300 Mbps"

INFO
}

# ============================================================================
#  7) 状态检查
# ============================================================================
show_status() {
    echo
    echo "${C_BLD}===== 系统基本信息 =====${C_END}"
    uptime
    free -h | head -2
    df -h / | tail -1
    echo

    echo "${C_BLD}===== 服务运行状态 =====${C_END}"
    for svc in xray nginx hysteria-server; do
        if systemctl list-unit-files | grep -q "^${svc}"; then
            local st
            st=$(systemctl is-active "$svc" 2>/dev/null || true)
            [[ "$st" == "active" ]] && ok "$svc: $st" || warn "$svc: $st"
        fi
    done
    echo

    echo "${C_BLD}===== 关键版本 =====${C_END}"
    [[ -x "$XRAY_DIR/xray" ]] && "$XRAY_DIR/xray" version | head -1
    command -v hysteria >/dev/null && hysteria version 2>&1 | head -1
    command -v nginx    >/dev/null && nginx -v 2>&1
    echo

    echo "${C_BLD}===== 监听端口 =====${C_END}"
    ss -tulnp 2>/dev/null | grep -vE '127\.0\.0\.(1|53)|::1\]' | head -15
    echo

    echo "${C_BLD}===== geo 文件 =====${C_END}"
    ls -la "$XRAY_DIR"/geoip.dat "$XRAY_DIR"/geosite.dat 2>/dev/null
    echo

    echo "${C_BLD}===== BBR =====${C_END}"
    sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc 2>/dev/null
    echo

    echo "${C_BLD}===== cron =====${C_END}"
    crontab -l 2>/dev/null | grep -vE '^\s*#|^\s*$' | head -10
    echo
}

# ============================================================================
#  菜单
# ============================================================================
menu() {
    cat <<MENU

${C_BLD}================================================${C_END}
${C_BLD}  v2ray-agent 维护 & Hysteria2 安装脚本${C_END}
${C_BLD}================================================${C_END}

  ${C_GRN}通用优化${C_END}
    1) 清理失效 cron (RenewTLS)
    2) 更新 geoip / geosite + 周度自动更新 cron
    3) 升级 Xray 到最新版
    4) 配置 logrotate (xray / hysteria)
    5) 应用内核网络参数调优 (BBR + 大缓冲)
    6) 一键跑完以上 1-5

  ${C_GRN}Hysteria2${C_END}
    7) 安装 / 重装 Hysteria2

  ${C_GRN}整体${C_END}
    8) 全部执行 (1-5 + 7)
    9) 查看当前状态
    0) 退出

MENU
    read -rp "请选择: " choice
    case "$choice" in
        1) fix_broken_cron ;;
        2) update_geodata ;;
        3) upgrade_xray ;;
        4) setup_logrotate ;;
        5) apply_sysctl ;;
        6) fix_broken_cron; update_geodata; upgrade_xray; setup_logrotate; apply_sysctl ;;
        7) install_hysteria2 ;;
        8) fix_broken_cron; update_geodata; upgrade_xray; setup_logrotate; apply_sysctl; install_hysteria2 ;;
        9) show_status ;;
        0) exit 0 ;;
        *) warn "无效选择"; menu ;;
    esac
}

# ============================================================================
#  main
# ============================================================================
main() {
    init
    check_os

    case "${1:-}" in
        --all)     fix_broken_cron; update_geodata; upgrade_xray; setup_logrotate; apply_sysctl ;;
        --hy2)     install_hysteria2 ;;
        --full)    fix_broken_cron; update_geodata; upgrade_xray; setup_logrotate; apply_sysctl; install_hysteria2 ;;
        --status)  show_status ;;
        --help|-h) sed -n '2,20p' "$0" ;;
        "")        menu ;;
        *)         err "未知参数：$1"; exit 1 ;;
    esac

    ok "完成。"
}

main "$@"
