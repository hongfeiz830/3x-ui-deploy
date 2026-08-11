#!/bin/bash
# ============================================================
# 3x-ui 一键部署脚本（参数化）
# 协议：VLESS + Reality
# 访问：纯 IP + 443 端口
# 使用：curl -sL <脚本地址> | bash -s -- --username=xxx --password=xxx
# 或：bash deploy-3xui.sh --username=xxx --password=xxx
# ============================================================

set -e

# ---- 默认参数 ----
PANEL_PORT=10601
PANEL_PATH="xui"
USERNAME="admin"
PASSWORD=""
VLESS_PORT=443
REALITY_DOMAIN="www.microsoft.com"
VLESS_UUID=""
SSH_PORT=""
CLEAN_INSTALL=false

# ---- 颜色输出 ----
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
step()  { echo -e "${CYAN}[STEP]${NC} $1"; }

# ---- 解析参数 ----
parse_args() {
    for arg in "$@"; do
        case $arg in
            --username=*)    USERNAME="${arg#*=}" ;;
            --password=*)    PASSWORD="${arg#*=}" ;;
            --panel-port=*)  PANEL_PORT="${arg#*=}" ;;
            --panel-path=*)  PANEL_PATH="${arg#*=}" ;;
            --vless-port=*)  VLESS_PORT="${arg#*=}" ;;
            --reality-domain=*) REALITY_DOMAIN="${arg#*=}" ;;
            --ssh-port=*)    SSH_PORT="${arg#*=}" ;;
            --clean)         CLEAN_INSTALL=true ;;
            --help|-h)
                echo "Usage: bash deploy-3xui.sh [OPTIONS]"
                echo ""
                echo "Options:"
                echo "  --username=NAME        面板用户名 (默认: admin)"
                echo "  --password=PASS        面板密码 (必填)"
                echo "  --panel-port=PORT      面板端口 (默认: 10601)"
                echo "  --panel-path=PATH      面板路径 (默认: xui)"
                echo "  --vless-port=PORT      VLESS节点端口 (默认: 443)"
                echo "  --reality-domain=DOM   Reality伪装域名 (默认: www.microsoft.com)"
                echo "  --ssh-port=PORT        SSH端口 (可选，用于防火墙放行)"
                echo "  --clean                清除旧安装，全新覆盖部署"
                echo ""
                echo "Example:"
                echo "  bash deploy-3xui.sh --password=mypassword123"
                echo "  bash deploy-3xui.sh --password=xxx --clean"
                exit 0
                ;;
            *) warn "未知参数: $arg" ;;
        esac
    done

    if [ -z "$PASSWORD" ]; then
        error "必须指定面板密码: --password=你的密码"
    fi
}

# ---- 检查 root ----
check_root() {
    if [ "$(id -u)" != "0" ]; then
        error "请使用 root 用户运行此脚本"
    fi
}

# ---- 检查系统 ----
check_system() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        info "检测到系统: $PRETTY_NAME"
    else
        error "无法识别操作系统，仅支持 Ubuntu/Debian"
    fi

    case "$OS" in
        ubuntu|debian) ;;
        *) warn "系统 $OS 未经验证，脚本可能不兼容" ;;
    esac
}

# ---- 清除旧安装 ----
clean_old_install() {
    step "0/7 清除旧安装"

    # 停止服务
    systemctl stop x-ui 2>/dev/null || true
    systemctl stop x-ui 2>/dev/null || true

    # 卸载旧 3x-ui / x-ui
    if [ -f /usr/local/x-ui/x-ui ]; then
        /usr/local/x-ui/x-ui uninstall 2>/dev/null || true
    fi

    # 强制清除残留
    systemctl disable x-ui 2>/dev/null || true
    rm -rf /usr/local/x-ui/ 2>/dev/null || true
    rm -rf /etc/x-ui/ 2>/dev/null || true
    rm -rf /etc/systemd/system/x-ui.service 2>/dev/null || true
    rm -rf /etc/systemd/system/x-ui.service.d 2>/dev/null || true
    rm -f /usr/local/bin/x-ui 2>/dev/null || true

    # 清除旧 xray
    rm -rf /usr/local/xray/ 2>/dev/null || true

    # 重载 systemd
    systemctl daemon-reload

    # 杀残留进程
    pkill -f x-ui 2>/dev/null || true
    pkill -f xray 2>/dev/null || true

    info "旧安装已清除"
}

# ---- 系统更新 + 依赖安装 ----
install_deps() {
    step "1/7 系统更新与依赖安装"
    apt update -y && apt upgrade -y
    apt install -y curl wget socat tar gzip
    info "依赖安装完成"
}

# ---- 安装 3x-ui ----
install_3xui() {
    step "2/7 安装 3x-ui"
    # 官方安装脚本
    bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)

    # 等待服务启动
    sleep 3
    if systemctl is-active --quiet x-ui; then
        info "3x-ui 服务已启动"
    else
        error "3x-ui 服务启动失败，请检查日志: journalctl -u x-ui -e"
    fi
}

# ---- 生成 UUID ----
gen_uuid() {
    if command -v xray &>/dev/null; then
        xray uuid
    else
        cat /proc/sys/kernel/random/uuid
    fi
}

# ---- 生成 Reality 密钥对 ----
gen_reality_keys() {
    # 生成随机 PrivateKey 和 PublicKey
    local keys
    if command -v xray &>/dev/null; then
        keys=$(xray x25519)
    else
        # 兜底：用 openssl 生成
        keys=$(/usr/local/x-ui/bin/xray-linux-arm64 x25519 2>/dev/null || \
               /usr/local/x-ui/bin/xray-linux-amd64 x25519 2>/dev/null || \
               echo "PRIVATE_KEY=fallback PUBLIC_KEY=fallback")
    fi
    PRIVATE_KEY=$(echo "$keys" | grep -i "private" | awk '{print $NF}')
    PUBLIC_KEY=$(echo "$keys" | grep -i "public" | awk '{print $NF}')
}

# ---- 配置面板 ----
config_panel() {
    step "3/7 配置面板"

    # 生成 UUID
    VLESS_UUID=$(gen_uuid)
    info "生成 UUID: $VLESS_UUID"

    # 生成 Reality 密钥
    gen_reality_keys
    info "Reality PrivateKey: $PRIVATE_KEY"
    info "Reality PublicKey: $PUBLIC_KEY"

    # 设置面板端口、路径、用户名密码
    /usr/local/x-ui/x-ui setting -port "$PANEL_PORT" \
        -path "$PANEL_PATH" \
        -username "$USERNAME" \
        -password "$PASSWORD" 2>/dev/null || true

    # 重启面板使配置生效
    systemctl restart x-ui
    sleep 2
    info "面板配置完成: https://<你的IP>:$PANEL_PORT/$PANEL_PATH"
}

# ---- 防火墙配置 ----
config_firewall() {
    step "4/7 防火墙配置"

    # 放行端口
    for port in "$PANEL_PORT" "$VLESS_PORT" 80 443; do
        if command -v ufw &>/dev/null; then
            ufw allow ${port}/tcp 2>/dev/null && info "UFW 放行端口: $port"
        elif command -v firewall-cmd &>/dev/null; then
            firewall-cmd --permanent --add-port=${port}/tcp 2>/dev/null && info "Firewalld 放行端口: $port"
        fi
    done

    # SSH 端口
    if [ -n "$SSH_PORT" ]; then
        if command -v ufw &>/dev/null; then
            ufw allow ${SSH_PORT}/tcp 2>/dev/null
        elif command -v firewall-cmd &>/dev/null; then
            firewall-cmd --permanent --add-port=${SSH_PORT}/tcp 2>/dev/null
        fi
        info "SSH 端口放行: $SSH_PORT"
    fi

    # 如果 UFW 没有启用，不强制启用（避免锁死 SSH）
    if command -v ufw &>/dev/null; then
        UFW_STATUS=$(ufw status | head -1)
        if echo "$UFW_STATUS" | grep -q "inactive"; then
            warn "UFW 未启用，端口已放行但防火墙未激活。如需启用: ufw enable"
        fi
    fi

    if command -v firewall-cmd &>/dev/null; then
        firewall-cmd --reload 2>/dev/null
    fi
}

# ---- 创建 VLESS + Reality 入站 ----
create_inbound() {
    step "5/7 创建 VLESS + Reality 入站"

    # 获取本机 IP
    SERVER_IP=$(curl -s4 ifconfig.me || curl -s4 ip.sb || echo "YOUR_IP")

    # 构造入站 JSON
    cat > /tmp/vless-reality-inbound.json << EOF
{
  "remark": "vless-reality",
  "enable": true,
  "expiry": 0,
  "listen": "",
  "port": ${VLESS_PORT},
  "protocol": "vless",
  "settings": {
    "clients": [
      {
        "id": "${VLESS_UUID}",
        "alterId": 0,
        "email": "user@3x-ui",
        "limitIp": 0,
        "totalGB": 0,
        "expiryTime": 0,
        "enable": true,
        "tgId": "",
        "subId": ""
      }
    ],
    "decryption": "none",
    "fallbacks": []
  },
  "streamSettings": {
    "network": "tcp",
    "security": "reality",
    "externalProxy": [],
    "realitySettings": {
      "show": false,
      "xver": 0,
      "dest": "${REALITY_DOMAIN}:443",
      "serverNames": [
        "${REALITY_DOMAIN}"
      ],
      "privateKey": "${PRIVATE_KEY}",
      "minClient": "",
      "maxClient": "",
      "maxTimediff": 0,
      "shortIds": [
        ""
      ],
      "settings": {
        "publicKey": "${PUBLIC_KEY}",
        "fingerprint": "chrome",
        "serverName": "",
        "spiderX": "/"
      }
    },
    "tcpSettings": {
      "acceptProxyProtocol": false,
      "header": {
        "type": "none"
      }
    }
  },
  "sniffing": {
    "enabled": true,
    "destOverride": [
      "http",
      "tls",
      "quic"
    ]
  }
}
EOF

    # 通过 3x-ui API 添加入站
    # 先登录获取 cookie
    LOGIN_RESP=$(curl -sk -c /tmp/xui-cookie.txt -X POST \
        "http://127.0.0.1:${PANEL_PORT}/${PANEL_PATH}/login" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "username=${USERNAME}&password=${PASSWORD}")

    # 添加入站
    ADD_RESP=$(curl -sk -b /tmp/xui-cookie.txt -X POST \
        "http://127.0.0.1:${PANEL_PORT}/${PANEL_PATH}/panel/inbound/add" \
        -H "Content-Type: application/json" \
        -d @/tmp/vless-reality-inbound.json)

    # 检查结果
    if echo "$ADD_RESP" | grep -q "true"; then
        info "VLESS + Reality 入站创建成功"
    else
        warn "API 自动创建入站可能失败，请手动在面板中添加"
        warn "API 返回: $ADD_RESP"
        warn "入站配置已保存到: /tmp/vless-reality-inbound.json"
    fi

    rm -f /tmp/xui-cookie.txt
}

# ---- 设置开机自启 ----
enable_autostart() {
    step "6/7 设置开机自启"
    systemctl enable x-ui
    info "3x-ui 已设置为开机自启"
}

# ---- 输出部署信息 ----
print_summary() {
    step "7/7 部署完成"

    SERVER_IP=$(curl -s4 ifconfig.me || echo "YOUR_IP")

    # 生成 VLESS 分享链接
    VLESS_LINK="vless://${VLESS_UUID}@${SERVER_IP}:${VLESS_PORT}?security=reality&encryption=none&pbk=${PUBLIC_KEY}&type=tcp&flow=xtls-rprx-vision&fp=chrome&sni=${REALITY_DOMAIN}&sid=#3xui-reality"

    echo ""
    echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}              3x-ui 部署完成 - 信息汇总${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  ${CYAN}面板信息${NC}"
    echo -e "  ├─ 地址:  https://${SERVER_IP}:${PANEL_PORT}/${PANEL_PATH}"
    echo -e "  ├─ 用户:  ${USERNAME}"
    echo -e "  └─ 密码:  ${PASSWORD}"
    echo ""
    echo -e "  ${CYAN}节点信息 (VLESS + Reality)${NC}"
    echo -e "  ├─ 协议:  VLESS"
    echo -e "  ├─ 地址:  ${SERVER_IP}"
    echo -e "  ├─ 端口:  ${VLESS_PORT}"
    echo -e "  ├─ UUID:  ${VLESS_UUID}"
    echo -e "  ├─ SNI:   ${REALITY_DOMAIN}"
    echo -e "  ├─ 公钥:  ${PUBLIC_KEY}"
    echo -e "  └─ Flow:  xtls-rprx-vision"
    echo ""
    echo -e "  ${CYAN}VLESS 分享链接${NC}"
    echo -e "  ${VLESS_LINK}"
    echo ""
    echo -e "  ${CYAN}常用命令${NC}"
    echo -e "  ├─ 状态:  x-ui"
    echo -e "  ├─ 启动:  systemctl start x-ui"
    echo -e "  ├─ 停止:  systemctl stop x-ui"
    echo -e "  ├─ 重启:  systemctl restart x-ui"
    echo -e "  └─ 日志:  journalctl -u x-ui -f"
    echo ""
    echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
    echo ""

    # 保存部署信息到文件
    cat > /root/3xui-deploy-info.txt << DEPLOY_EOF
# 3x-ui 部署信息
# 部署时间: $(date '+%Y-%m-%d %H:%M:%S')
# 服务器IP: ${SERVER_IP}

## 面板
地址: https://${SERVER_IP}:${PANEL_PORT}/${PANEL_PATH}
用户: ${USERNAME}
密码: ${PASSWORD}

## VLESS Reality 节点
UUID: ${VLESS_UUID}
SNI: ${REALITY_DOMAIN}
PublicKey: ${PUBLIC_KEY}
PrivateKey: ${PRIVATE_KEY}
Flow: xtls-rprx-vision

## 分享链接
${VLESS_LINK}
DEPLOY_EOF

    info "部署信息已保存到: /root/3xui-deploy-info.txt"
}

# ---- 主流程 ----
main() {
    echo ""
    echo -e "${GREEN}╔═══════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║     3x-ui 一键部署 (VLESS + Reality)          ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════════╝${NC}"
    echo ""

    parse_args "$@"
    check_root
    check_system
    if [ "$CLEAN_INSTALL" = true ]; then
        clean_old_install
    fi
    install_deps
    install_3xui
    config_panel
    config_firewall
    create_inbound
    enable_autostart
    print_summary
}

main "$@"
