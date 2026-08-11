#!/bin/bash
#
# 3x-ui 一键部署脚本
# 特性：纯 IP 访问 + HTTPS 自签证书 + 自定义端口/账号/根路径
# 适用系统：Ubuntu / Debian / CentOS / Rocky / AlmaLinux
#

set -e

# ============================================================
# 配置区（可按需修改）
# ============================================================
PANEL_PORT="10601"          # 面板监听端口
USERNAME="admin"            # 登录用户名
PASSWORD="000000"           # 登录密码
WEB_BASE_PATH="xui"         # 面板根路径
CERT_DIR="/etc/x-ui/ssl"    # SSL 证书存放目录
CERT_FILE="${CERT_DIR}/panel.crt"
KEY_FILE="${CERT_DIR}/panel.key"
CERT_DAYS="3650"            # 证书有效期（天）

# ============================================================
# 颜色与工具函数
# ============================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }
step()  { echo -e "\n${CYAN}==> $1${NC}"; }

# ============================================================
# 前置检查
# ============================================================
if [ "$EUID" -ne 0 ]; then
    error "请使用 root 用户运行此脚本：sudo bash $0"
    exit 1
fi

# ============================================================
# 获取服务器公网 IP
# ============================================================
step "获取服务器公网 IP"
SERVER_IP=""
for ip_api in "https://api.ipify.org" "https://ifconfig.me" "https://icanhazip.com" "https://ipinfo.io/ip"; do
    SERVER_IP=$(curl -s --connect-timeout 5 "${ip_api}" 2>/dev/null || true)
    if [ -n "${SERVER_IP}" ] && echo "${SERVER_IP}" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
        break
    fi
done

if [ -z "${SERVER_IP}" ]; then
    error "无法自动获取服务器公网 IP，请手动输入："
    read -rp "服务器公网 IP: " SERVER_IP
fi
info "服务器公网 IP: ${SERVER_IP}"

# ============================================================
# 安装系统依赖
# ============================================================
step "安装系统依赖"
if command -v apt-get &>/dev/null; then
    apt-get update -y -qq
    apt-get install -y -qq curl openssl ca-certificates
elif command -v dnf &>/dev/null; then
    dnf install -y curl openssl ca-certificates
elif command -v yum &>/dev/null; then
    yum install -y curl openssl ca-certificates
else
    error "不支持的操作系统，请手动安装 curl 和 openssl 后重试"
    exit 1
fi
info "依赖安装完成"

# ============================================================
# 生成自签 SSL 证书（含 IP SAN，浏览器可识别）
# ============================================================
step "生成自签 SSL 证书"
mkdir -p "${CERT_DIR}"

OPENSSL_CONF=$(mktemp)
cat > "${OPENSSL_CONF}" << EOF
[req]
default_bits       = 2048
prompt             = no
default_md         = sha256
distinguished_name = dn
req_extensions     = req_ext
x509_extensions    = v3_ca

[dn]
C  = CN
ST = Shanghai
L  = Shanghai
O  = 3X-UI Panel
CN = ${SERVER_IP}

[req_ext]
subjectAltName = @alt_names

[v3_ca]
subjectAltName   = @alt_names
basicConstraints = CA:FALSE
keyUsage         = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth

[alt_names]
IP.1   = ${SERVER_IP}
DNS.1  = localhost
EOF

openssl req -x509 -nodes -days "${CERT_DAYS}" -newkey rsa:2048 \
    -keyout "${KEY_FILE}" \
    -out "${CERT_FILE}" \
    -config "${OPENSSL_CONF}" 2>/dev/null

rm -f "${OPENSSL_CONF}"
chmod 600 "${KEY_FILE}"
chmod 644 "${CERT_FILE}"
info "SSL 证书已生成（有效期 ${CERT_DAYS} 天）"
info "  证书: ${CERT_FILE}"
info "  私钥: ${KEY_FILE}"

# ============================================================
# 安装 3x-ui（无人值守模式）
# ============================================================
step "安装 3x-ui 面板"
if command -v x-ui &>/dev/null; then
    warn "检测到 3x-ui 已安装，跳过安装步骤，直接进行配置"
else
    XUI_NONINTERACTIVE=1 bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)
    info "3x-ui 安装完成"
fi

# 等待服务初始化
sleep 3

# ============================================================
# 配置面板参数
# ============================================================
step "配置面板参数"
XUI_BIN="/usr/local/x-ui/x-ui"

info "设置面板端口: ${PANEL_PORT}"
"${XUI_BIN}" setting -port "${PANEL_PORT}"

info "设置用户名: ${USERNAME}"
"${XUI_BIN}" setting -username "${USERNAME}"

info "设置密码: ${PASSWORD}"
"${XUI_BIN}" setting -password "${PASSWORD}"

info "设置根路径: ${WEB_BASE_PATH}"
"${XUI_BIN}" setting -webBasePath "${WEB_BASE_PATH}"

info "设置 SSL 证书路径"
"${XUI_BIN}" setting -webCert "${CERT_FILE}"
"${XUI_BIN}" setting -webCertKey "${KEY_FILE}"

# ============================================================
# 防火墙放行
# ============================================================
step "配置防火墙"
if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "active"; then
    ufw allow "${PANEL_PORT}/tcp"
    info "ufw 已放行 ${PANEL_PORT}/tcp"
elif command -v firewall-cmd &>/dev/null && firewall-cmd --state 2>/dev/null | grep -q "running"; then
    firewall-cmd --permanent --add-port="${PANEL_PORT}/tcp"
    firewall-cmd --reload
    info "firewalld 已放行 ${PANEL_PORT}/tcp"
else
    warn "未检测到活跃的防火墙（ufw/firewalld），请确保云服务商安全组已放行 ${PANEL_PORT} 端口"
fi

# ============================================================
# 重启服务使配置生效
# ============================================================
step "重启 3x-ui 服务"
x-ui restart
sleep 3

# 验证服务状态
if x-ui status 2>/dev/null | grep -qi "running\|active"; then
    info "3x-ui 服务运行正常"
else
    warn "服务状态检测异常，请手动执行 x-ui status 查看"
fi

# ============================================================
# 输出部署结果
# ============================================================
PANEL_URL="https://${SERVER_IP}:${PANEL_PORT}/${WEB_BASE_PATH}"

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║           3x-ui 面板部署完成！                           ║"
echo "╠══════════════════════════════════════════════════════════╣"
echo -e "║  面板地址: ${GREEN}${PANEL_URL}${NC}"
echo "║                                                          ║"
echo -e "║  用户名:   ${GREEN}${USERNAME}${NC}"
echo -e "║  密  码:   ${GREEN}${PASSWORD}${NC}"
echo "║                                                          ║"
echo "║  证书类型: 自签 SSL（有效期 ${CERT_DAYS} 天）             ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo -e "${YELLOW}【重要提示】${NC}"
echo "  由于使用纯 IP + 自签证书，浏览器首次访问会提示安全警告："
echo "  Chrome / Edge: 点击 \"高级\" → \"继续前往 ${SERVER_IP}（不安全）\""
echo "  Firefox:       点击 \"高级\" → \"接受风险并继续\""
echo "  Safari:        点击 \"显示详细信息\" → \"访问此网站\""
echo ""
echo -e "${CYAN}【常用管理命令】${NC}"
echo "  x-ui            进入交互管理菜单"
echo "  x-ui restart    重启面板"
echo "  x-ui status     查看运行状态"
echo "  x-ui setting    查看当前配置"
echo "  x-ui update     升级面板"
echo ""
echo -e "${CYAN}【安全建议】${NC}"
echo "  1. 首次登录后建议立即修改默认密码"
echo "  2. 如有域名，可在面板中替换为 Let's Encrypt 可信证书"
echo "  3. 建议限制面板端口的访问来源 IP"
echo ""
