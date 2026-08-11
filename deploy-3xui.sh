#!/bin/bash
set -e
PANEL_PORT=70830
PANEL_PATH="xui"
USERNAME="admin"
PASSWORD=""
VLESS_PORT=443
REALITY_DOMAIN="www.microsoft.com"
VLESS_UUID=""
SSH_PORT=""
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'
info(){ echo -e "${GREEN}[INFO]${NC} $1"; }
warn(){ echo -e "${YELLOW}[WARN]${NC} $1"; }
error(){ echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
step(){ echo -e "${CYAN}[STEP]${NC} $1"; }
parse_args(){
    for arg in "$@"; do
        case $arg in
            --username=*) USERNAME="${arg#*=}";;
            --password=*) PASSWORD="${arg#*=}";;
            --panel-port=*) PANEL_PORT="${arg#*=}";;
            --panel-path=*) PANEL_PATH="${arg#*=}";;
            --vless-port=*) VLESS_PORT="${arg#*=}";;
            --reality-domain=*) REALITY_DOMAIN="${arg#*=}";;
            --ssh-port=*) SSH_PORT="${arg#*=}";;
            --help|-h) echo "Usage: bash deploy-3xui.sh --password=PASS [OPTIONS]"; exit 0;;
            *) warn "未知参数: $arg";;
        esac
    done
    [ -z "$PASSWORD" ] && error "必须指定面板密码: --password=你的密码"
}
check_root(){ [ "$(id -u)" != "0" ] && error "请使用 root 用户运行"; }
check_system(){
    [ -f /etc/os-release ] && . /etc/os-release && OS=$ID && info "系统: $PRETTY_NAME" || error "无法识别系统"
    case "$OS" in ubuntu|debian);; *) warn "系统 $OS 未经验证";; esac
}
install_deps(){
    step "1/7 系统更新与依赖安装"
    apt update -y && apt upgrade -y
    apt install -y curl wget socat tar gzip
    info "依赖安装完成"
}
install_3xui(){
    step "2/7 安装 3x-ui"
    bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)
    sleep 3
    systemctl is-active --quiet x-ui && info "3x-ui 已启动" || error "3x-ui 启动失败: journalctl -u x-ui -e"
}
gen_uuid(){ command -v xray &>/dev/null && xray uuid || cat /proc/sys/kernel/random/uuid; }
gen_reality_keys(){
    local keys
    if command -v xray &>/dev/null; then keys=$(xray x25519);
    else keys=$(/usr/local/x-ui/bin/xray-linux-arm64 x25519 2>/dev/null || /usr/local/x-ui/bin/xray-linux-amd64 x25519 2>/dev/null || echo "PRIVATE_KEY=fallback PUBLIC_KEY=fallback"); fi
    PRIVATE_KEY=$(echo "$keys" | grep -i "private" | awk '{print $NF}')
    PUBLIC_KEY=$(echo "$keys" | grep -i "public" | awk '{print $NF}')
}
config_panel(){
    step "3/7 配置面板"
    VLESS_UUID=$(gen_uuid) && info "UUID: $VLESS_UUID"
    gen_reality_keys && info "PrivateKey: $PRIVATE_KEY" && info "PublicKey: $PUBLIC_KEY"
    /usr/local/x-ui/x-ui setting -port "$PANEL_PORT" -path "$PANEL_PATH" -username "$USERNAME" -password "$PASSWORD" 2>/dev/null || true
    systemctl restart x-ui && sleep 2
    info "面板: https://<IP>:$PANEL_PORT/$PANEL_PATH"
}
config_firewall(){
    step "4/7 防火墙配置"
    for port in "$PANEL_PORT" "$VLESS_PORT" 80 443; do
        command -v ufw &>/dev/null && ufw allow ${port}/tcp 2>/dev/null && info "UFW 放行: $port"
        command -v firewall-cmd &>/dev/null && firewall-cmd --permanent --add-port=${port}/tcp 2>/dev/null && info "Firewalld 放行: $port"
    done
    if [ -n "$SSH_PORT" ]; then
        command -v ufw &>/dev/null && ufw allow ${SSH_PORT}/tcp 2>/dev/null
        command -v firewall-cmd &>/dev/null && firewall-cmd --permanent --add-port=${SSH_PORT}/tcp 2>/dev/null
        info "SSH 放行: $SSH_PORT"
    fi
    command -v firewall-cmd &>/dev/null && firewall-cmd --reload 2>/dev/null
}
create_inbound(){
    step "5/7 创建 VLESS+Reality 入站"
    SERVER_IP=$(curl -s4 ifconfig.me || curl -s4 ip.sb || echo "YOUR_IP")
    cat > /tmp/vless-reality-inbound.json << EOF
{"remark":"vless-reality","enable":true,"expiry":0,"listen":"","port":${VLESS_PORT},"protocol":"vless","settings":{"clients":[{"id":"${VLESS_UUID}","alterId":0,"email":"user@3x-ui","limitIp":0,"totalGB":0,"expiryTime":0,"enable":true,"tgId":"","subId":""}],"decryption":"none","fallbacks":[]},"streamSettings":{"network":"tcp","security":"reality","externalProxy":[],"realitySettings":{"show":false,"xver":0,"dest":"${REALITY_DOMAIN}:443","serverNames":["${REALITY_DOMAIN}"],"privateKey":"${PRIVATE_KEY}","minClient":"","maxClient":"","maxTimediff":0,"shortIds":[""],"settings":{"publicKey":"${PUBLIC_KEY}","fingerprint":"chrome","serverName":"","spiderX":"/"}},"tcpSettings":{"acceptProxyProtocol":false,"header":{"type":"none"}}},"sniffing":{"enabled":true,"destOverride":["http","tls","quic"]}}
EOF
    curl -sk -c /tmp/xui-cookie.txt -X POST "http://127.0.0.1:${PANEL_PORT}/${PANEL_PATH}/login" -H "Content-Type: application/x-www-form-urlencoded" -d "username=${USERNAME}&password=${PASSWORD}" -o /dev/null
    ADD_RESP=$(curl -sk -b /tmp/xui-cookie.txt -X POST "http://127.0.0.1:${PANEL_PORT}/${PANEL_PATH}/panel/inbound/add" -H "Content-Type: application/json" -d @/tmp/vless-reality-inbound.json)
    echo "$ADD_RESP" | grep -q "true" && info "VLESS+Reality 入站创建成功" || { warn "API创建可能失败，请手动添加"; warn "返回: $ADD_RESP"; }
    rm -f /tmp/xui-cookie.txt
}
enable_autostart(){ step "6/7 开机自启"; systemctl enable x-ui; info "已设置开机自启"; }
print_summary(){
    step "7/7 部署完成"
    SERVER_IP=$(curl -s4 ifconfig.me || echo "YOUR_IP")
    VLESS_LINK="vless://${VLESS_UUID}@${SERVER_IP}:${VLESS_PORT}?security=reality&encryption=none&pbk=${PUBLIC_KEY}&type=tcp&flow=xtls-rprx-vision&fp=chrome&sni=${REALITY_DOMAIN}&sid=#3xui-reality"
    echo ""
    echo -e "${GREEN}═══════════════════════════════════════════${NC}"
    echo -e "${GREEN}         3x-ui 部署完成${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════${NC}"
    echo -e "面板: https://${SERVER_IP}:${PANEL_PORT}/${PANEL_PATH}"
    echo -e "用户: ${USERNAME}  密码: ${PASSWORD}"
    echo -e "UUID: ${VLESS_UUID}"
    echo -e "SNI: ${REALITY_DOMAIN}  公钥: ${PUBLIC_KEY}"
    echo -e "分享链接: ${VLESS_LINK}"
    echo -e "${GREEN}═══════════════════════════════════════════${NC}"
    cat > /root/3xui-deploy-info.txt << DEPLOY_EOF
# 3x-ui 部署信息
# 时间: $(date '+%Y-%m-%d %H:%M:%S')
# IP: ${SERVER_IP}
面板: https://${SERVER_IP}:${PANEL_PORT}/${PANEL_PATH}
用户: ${USERNAME}
密码: ${PASSWORD}
UUID: ${VLESS_UUID}
SNI: ${REALITY_DOMAIN}
PublicKey: ${PUBLIC_KEY}
PrivateKey: ${PRIVATE_KEY}
链接: ${VLESS_LINK}
DEPLOY_EOF
    info "部署信息已保存: /root/3xui-deploy-info.txt"
}
main(){
    echo -e "${GREEN}╔═══════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║   3x-ui 一键部署 (VLESS+Reality)          ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════╝${NC}"
    parse_args "$@"
    check_root
    check_system
    install_deps
    install_3xui
    config_panel
    config_firewall
    create_inbound
    enable_autostart
    print_summary
}
main "$@"
