#!/usr/bin/env bash
# ============================================================================
#  renew-hysteria-cert.sh
#  ---------------------------------------------------------------------------
#  Renew and install the Let's Encrypt certificate used by Hysteria2, then fix
#  file permissions and restart the Hysteria systemd service.
#
#  Defaults match the yehen.life / v2ray-agent layout documented in this repo.
#
#  Usage:
#     sudo bash renew-hysteria-cert.sh
#     sudo DOMAIN=example.com bash renew-hysteria-cert.sh
#     sudo STOP_WEB=0 bash renew-hysteria-cert.sh
#     sudo FORCE_RENEW=1 bash renew-hysteria-cert.sh
# ============================================================================

set -Eeuo pipefail

readonly SCRIPT_NAME="$(basename "$0")"

DOMAIN="${DOMAIN:-yehen.life}"
ACME_HOME="${ACME_HOME:-/root/.acme.sh}"
ACME_SH="${ACME_SH:-${ACME_HOME}/acme.sh}"
TLS_DIR="${TLS_DIR:-/etc/v2ray-agent/tls}"
CERT_FILE="${CERT_FILE:-${TLS_DIR}/${DOMAIN}.crt}"
KEY_FILE="${KEY_FILE:-${TLS_DIR}/${DOMAIN}.key}"
HYSTERIA_SERVICE="${HYSTERIA_SERVICE:-hysteria-server}"
HYSTERIA_GROUP="${HYSTERIA_GROUP:-hysteria}"
WEB_SERVICE="${WEB_SERVICE:-nginx}"
STOP_WEB="${STOP_WEB:-1}"
FORCE_RENEW="${FORCE_RENEW:-0}"
LOG_FILE="${LOG_FILE:-/var/log/renew-hysteria-cert.log}"

if [[ -t 1 ]]; then
    C_RED=$'\033[0;31m'; C_GRN=$'\033[0;32m'; C_YLW=$'\033[0;33m'
    C_BLU=$'\033[0;34m'; C_END=$'\033[0m'
else
    C_RED=''; C_GRN=''; C_YLW=''; C_BLU=''; C_END=''
fi

log()  { printf '%b\n' "${C_BLU}[*]${C_END} $*" | tee -a "$LOG_FILE"; }
ok()   { printf '%b\n' "${C_GRN}[OK]${C_END} $*" | tee -a "$LOG_FILE"; }
warn() { printf '%b\n' "${C_YLW}[!]${C_END} $*" | tee -a "$LOG_FILE"; }
err()  { printf '%b\n' "${C_RED}[x]${C_END} $*" | tee -a "$LOG_FILE"; }

require_root() {
    if [[ $EUID -ne 0 ]]; then
        err "请用 root 运行：sudo bash $SCRIPT_NAME"
        exit 1
    fi
}

require_cmd() {
    for cmd in "$@"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            err "缺少命令：$cmd"
            exit 1
        fi
    done
}

web_was_active=0
restore_web_service() {
    if [[ "$STOP_WEB" == "1" && "$web_was_active" == "1" ]]; then
        log "恢复 ${WEB_SERVICE}..."
        systemctl start "$WEB_SERVICE" || warn "${WEB_SERVICE} 启动失败，请手动检查"
        web_was_active=0
    fi
}

trap 'err "脚本在第 $LINENO 行失败（exit=$?），日志：$LOG_FILE"; restore_web_service; exit 1' ERR
trap 'restore_web_service' EXIT

prepare() {
    require_root
    require_cmd systemctl openssl chown chmod mkdir
    mkdir -p "$(dirname "$LOG_FILE")" "$TLS_DIR"
    : >> "$LOG_FILE"

    if [[ ! -x "$ACME_SH" ]]; then
        err "未找到 acme.sh：$ACME_SH"
        err "请先安装 acme.sh，或用 ACME_SH=/path/to/acme.sh 指定路径"
        exit 1
    fi

    if ! getent group "$HYSTERIA_GROUP" >/dev/null 2>&1; then
        err "系统组不存在：$HYSTERIA_GROUP"
        exit 1
    fi
}

stop_web_service_if_needed() {
    if [[ "$STOP_WEB" != "1" ]]; then
        log "STOP_WEB=0，跳过停止 ${WEB_SERVICE}"
        return 0
    fi

    if ! systemctl cat "$WEB_SERVICE" >/dev/null 2>&1; then
        warn "未发现 ${WEB_SERVICE}.service，跳过"
        return 0
    fi

    if systemctl is-active --quiet "$WEB_SERVICE"; then
        web_was_active=1
        log "停止 ${WEB_SERVICE}，释放 TCP 80 给 acme.sh standalone 验证..."
        systemctl stop "$WEB_SERVICE"
    else
        log "${WEB_SERVICE} 当前未运行"
    fi
}

run_acme_cron() {
    log "设置 acme.sh 默认 CA 为 Let's Encrypt..."
    "$ACME_SH" --set-default-ca --server letsencrypt

    if [[ "$FORCE_RENEW" == "1" ]]; then
        warn "FORCE_RENEW=1，本次强制续期"
        "$ACME_SH" --renew -d "$DOMAIN" --ecc --server letsencrypt --force
        return 0
    fi

    log "运行 acme.sh 自动续期检查..."
    "$ACME_SH" --cron --home "$ACME_HOME"
}

install_cert() {
    local reload_cmd
    reload_cmd="chown root:${HYSTERIA_GROUP} '${KEY_FILE}' '${CERT_FILE}' && chmod 640 '${KEY_FILE}' && chmod 644 '${CERT_FILE}' && systemctl restart '${HYSTERIA_SERVICE}'"

    log "安装证书到 Hysteria 路径..."
    "$ACME_SH" --install-cert -d "$DOMAIN" --ecc \
        --key-file "$KEY_FILE" \
        --fullchain-file "$CERT_FILE" \
        --reloadcmd "$reload_cmd"
}

verify() {
    log "检查证书有效期..."
    openssl x509 -in "$CERT_FILE" -noout -subject -issuer -dates

    log "检查 Hysteria 服务状态..."
    systemctl is-active --quiet "$HYSTERIA_SERVICE"
    ok "${HYSTERIA_SERVICE} is active"
}

main() {
    prepare
    stop_web_service_if_needed
    run_acme_cron
    install_cert
    verify
    ok "证书续期流程完成：$DOMAIN"
}

main "$@"
