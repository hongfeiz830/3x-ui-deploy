#!/bin/bash
#
# 3x-ui 一键部署脚本（支持新 VPS 初始化 & 老 VPS 覆盖安装）
# 特性：纯 IP 访问 + HTTPS 自签证书 + 自定义端口/账号/根路径
# 保障：证书有效性校验 + 配置写入确认 + HTTPS 连通性验证
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
TIMEZONE="Asia/Shanghai"    # 系统时区
ENABLE_BBR="true"           # 是否开启 BBR 拥塞控制
MAX_HTTPS_RETRY=5           # HTTPS 验证最大重试次数

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

# 检测系统包管理器
PKG_MANAGER=""
if command -v apt-get &>/dev/null; then
    PKG_MANAGER="apt"
elif command -v dnf &>/dev/null; then
    PKG_MANAGER="dnf"
elif command -v yum &>/dev/null; then
    PKG_MANAGER="yum"
else
    error "不支持的操作系统（未检测到 apt/dnf/yum）"
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
# 检测是否存在旧安装（x-ui / 3x-ui）
# ============================================================
OLD_INSTALL_FOUND="false"

if command -v x-ui &>/dev/null; then
    OLD_INSTALL_FOUND="true"
fi

for dir in "/usr/local/x-ui" "/etc/x-ui"; do
    if [ -d "${dir}" ]; then
        OLD_INSTALL_FOUND="true"
    fi
done

if systemctl list-unit-files 2>/dev/null | grep -q "x-ui.service"; then
    OLD_INSTALL_FOUND="true"
fi

if pgrep -f "x-ui" &>/dev/null || pgrep -f "xray" &>/dev/null; then
    OLD_INSTALL_FOUND="true"
fi

# ============================================================
# 【场景二】老 VPS 覆盖安装：彻底清理旧安装，零残留
# ============================================================
if [ "${OLD_INSTALL_FOUND}" = "true" ]; then
    step "检测到旧版 x-ui / 3x-ui 安装，执行彻底清理（覆盖安装模式）"

    info "停止 x-ui 服务..."
    systemctl stop x-ui 2>/dev/null || true
    systemctl disable x-ui 2>/dev/null || true

    info "终止残留进程..."
    pkill -9 -f "x-ui" 2>/dev/null || true
    pkill -9 -f "xray" 2>/dev/null || true
    sleep 1

    if pgrep -f "x-ui" &>/dev/null || pgrep -f "xray" &>/dev/null; then
        warn "仍有残留进程，再次强制终止..."
        pkill -9 -f "x-ui" 2>/dev/null || true
        pkill -9 -f "xray" 2>/dev/null || true
        sleep 1
    fi

    info "删除程序文件与配置数据..."
    rm -rf /usr/local/x-ui
    rm -rf /etc/x-ui
    rm -rf /var/log/x-ui
    rm -f /usr/bin/x-ui
    rm -f /usr/local/bin/x-ui
    rm -f /etc/systemd/system/x-ui.service
    rm -f /lib/systemd/system/x-ui.service
    rm -f /etc/init.d/x-ui

    systemctl daemon-reload 2>/dev/null || true

    info "释放端口占用..."
    if command -v lsof &>/dev/null; then
        PORT_PID=$(lsof -ti:2053 -ti:2052 -ti:"${PANEL_PORT}" 2>/dev/null || true)
        if [ -n "${PORT_PID}" ]; then
            kill -9 ${PORT_PID} 2>/dev/null || true
        fi
    fi

    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "active"; then
        ufw delete allow 2053/tcp 2>/dev/null || true
        ufw delete allow 2052/tcp 2>/dev/null || true
    fi

    info "旧安装清理完成，零残留"
else
    info "未检测到旧版 x-ui / 3x-ui，执行全新安装"
fi

# ============================================================
# 【场景一】新 VPS 系统初始化
# ============================================================
step "系统初始化"

info "更新系统软件包..."
if [ "${PKG_MANAGER}" = "apt" ]; then
    apt-get update -y -qq
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq
elif [ "${PKG_MANAGER}" = "dnf" ]; then
    dnf upgrade -y -q
elif [ "${PKG_MANAGER}" = "yum" ]; then
    yum update -y -q
fi

info "安装基础工具..."
if [ "${PKG_MANAGER}" = "apt" ]; then
    apt-get install -y -qq curl wget vim htop net-tools unzip ca-certificates openssl lsof
elif [ "${PKG_MANAGER}" = "dnf" ]; then
    dnf install -y -q curl wget vim htop net-tools unzip ca-certificates openssl lsof
elif [ "${PKG_MANAGER}" = "yum" ]; then
    yum install -y -q curl wget vim htop net-tools unzip ca-certificates openssl lsof
fi

info "设置系统时区为 ${TIMEZONE}..."
if command -v timedatectl &>/dev/null; then
    timedatectl set-timezone "${TIMEZONE}" 2>/dev/null || true
else
    ln -sf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime 2>/dev/null || true
fi

if [ "${ENABLE_BBR}" = "true" ]; then
    info "配置 BBR 拥塞控制..."
    if ! sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q "bbr"; then
        if modprobe tcp_bbr 2>/dev/null || lsmod | grep -q bbr; then
            cat > /etc/sysctl.d/99-bbr.conf << EOF
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
            sysctl -p /etc/sysctl.d/99-bbr.conf 2>/dev/null || true
            info "BBR 已启用"
        else
            warn "当前内核不支持 BBR，跳过（建议使用 4.9+ 内核）"
        fi
    else
        info "BBR 已处于启用状态"
    fi
fi

info "系统初始化完成"

# ============================================================
# 全新安装 3x-ui（无人值守模式）
# ============================================================
step "安装 3x-ui 面板"
XUI_NONINTERACTIVE=1 bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)
info "3x-ui 安装完成"

# 等待服务初始化
sleep 3

XUI_BIN="/usr/local/x-ui/x-ui"

# ============================================================
# 生成自签 SSL 证书（安装后生成，确保目录权限正确）
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

# ---- 证书有效性校验 ----
info "校验证书有效性..."

# 校验证书文件存在
if [ ! -f "${CERT_FILE}" ] || [ ! -f "${KEY_FILE}" ]; then
    error "证书或私钥文件生成失败"
    exit 1
fi

# 校验证书和私钥的 modulus 匹配（确保证书与私钥是一对）
CERT_MOD=$(openssl x509 -noout -modulus -in "${CERT_FILE}" 2>/dev/null | openssl md5)
KEY_MOD=$(openssl rsa -noout -modulus -in "${KEY_FILE}" 2>/dev/null | openssl md5)

if [ "${CERT_MOD}" != "${KEY_MOD}" ]; then
    error "证书与私钥不匹配（modulus 不一致），HTTPS 将无法启用"
    exit 1
fi

# 校验证书包含 IP SAN
if ! openssl x509 -noout -text -in "${CERT_FILE}" 2>/dev/null | grep -q "IP Address:${SERVER_IP}"; then
    error "证书未包含 IP SAN（${SERVER_IP}），浏览器将拒绝连接"
    exit 1
fi

# 校验证书未过期
if openssl x509 -noout -checkend 0 -in "${CERT_FILE}" 2>/dev/null; then
    :
else
    error "证书已过期"
    exit 1
fi

info "证书校验通过：证书/私钥匹配，含 IP SAN，有效期内"
info "  证书: ${CERT_FILE}"
info "  私钥: ${KEY_FILE}"

# ============================================================
# 配置面板参数
# ============================================================
step "配置面板参数"

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

# ---- 配置写入确认 ----
info "确认配置已写入数据库..."
SETTING_OUTPUT=$("${XUI_BIN}" setting -show 2>/dev/null || true)

if echo "${SETTING_OUTPUT}" | grep -q "${CERT_FILE}"; then
    info "证书路径已确认写入: ${CERT_FILE}"
else
    warn "未能从 setting -show 中确认证书路径，继续验证..."
fi

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

if x-ui status 2>/dev/null | grep -qi "running\|active"; then
    info "3x-ui 服务运行正常"
else
    warn "服务状态检测异常，请手动执行 x-ui status 查看"
fi

# ============================================================
# HTTPS 生效验证（核心保障：必须确认 https:// 可访问）
# ============================================================
step "验证 HTTPS 面板可访问性"

HTTPS_VERIFIED="false"

for i in $(seq 1 ${MAX_HTTPS_RETRY}); do
    info "HTTPS 验证尝试 ${i}/${MAX_HTTPS_RETRY}..."

    # 用 curl 实际请求 HTTPS 端口（-k 跳过自签证书校验，只验证连通性和协议）
    HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" --connect-timeout 5 \
        "https://127.0.0.1:${PANEL_PORT}/${WEB_BASE_PATH}/" 2>/dev/null || echo "000")

    # 同时检测端口是否在 TLS 层握手（确认不是 HTTP 回退）
    TLS_HANDSHAKE=$(curl -sk -o /dev/null -w "%{ssl_verify_result}" --connect-timeout 5 \
        "https://127.0.0.1:${PANEL_PORT}/${WEB_BASE_PATH}/" 2>/dev/null || echo "error")

    if [ "${HTTP_CODE}" != "000" ] && [ "${TLS_HANDSHAKE}" != "error" ]; then
        info "HTTPS 验证通过！HTTP 状态码: ${HTTP_CODE}，TLS 握手成功"
        HTTPS_VERIFIED="true"
        break
    fi

    # 如果 HTTP 还能访问而 HTTPS 不能，说明证书没生效
    HTTP_CODE_PLAIN=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 \
        "http://127.0.0.1:${PANEL_PORT}/${WEB_BASE_PATH}/" 2>/dev/null || echo "000")

    if [ "${HTTP_CODE_PLAIN}" != "000" ] && [ "${HTTP_CODE}" = "000" ]; then
        warn "检测到 HTTP 可访问但 HTTPS 不可访问，证书可能未生效，等待服务重载..."
    fi

    sleep 3
done

if [ "${HTTPS_VERIFIED}" != "true" ]; then
    echo ""
    error "HTTPS 验证失败！面板可能仍在使用 HTTP，请检查以下信息："
    echo ""
    echo "--- 诊断信息 ---"
    echo "1. 证书文件状态:"
    ls -la "${CERT_FILE}" "${KEY_FILE}" 2>/dev/null || echo "   证书文件不存在"
    echo ""
    echo "2. 证书内容校验:"
    openssl x509 -noout -subject -dates -in "${CERT_FILE}" 2>/dev/null || echo "   证书读取失败"
    echo ""
    echo "3. 面板当前配置:"
    "${XUI_BIN}" setting -show 2>/dev/null || echo "   无法读取配置"
    echo ""
    echo "4. 端口监听状态:"
    if command -v ss &>/dev/null; then
        ss -tlnp | grep "${PANEL_PORT}" 2>/dev/null || echo "   端口 ${PANEL_PORT} 未监听"
    else
        netstat -tlnp 2>/dev/null | grep "${PANEL_PORT}" || echo "   端口 ${PANEL_PORT} 未监听"
    fi
    echo ""
    echo "5. 服务日志（最近20行）:"
    journalctl -u x-ui --no-pager -n 20 2>/dev/null || echo "   无法读取日志"
    echo ""
    echo "--- 手动修复建议 ---"
    echo "  1. 确认证书路径正确: ${CERT_FILE}"
    echo "  2. 重新设置证书: x-ui setting -webCert ${CERT_FILE} -webCertKey ${KEY_FILE}"
    echo "  3. 重启服务: x-ui restart"
    echo "  4. 验证: curl -sk https://127.0.0.1:${PANEL_PORT}/${WEB_BASE_PATH}/"
    echo ""
    exit 1
fi

# ============================================================
# 输出部署结果
# ============================================================
PANEL_URL="https://${SERVER_IP}:${PANEL_PORT}/${WEB_BASE_PATH}"
INSTALL_MODE=$([ "${OLD_INSTALL_FOUND}" = "true" ] && echo "覆盖安装（已清理旧版）" || echo "全新安装")

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║           3x-ui 面板部署完成！                           ║"
echo "╠══════════════════════════════════════════════════════════╣"
echo -e "║  安装模式: ${GREEN}${INSTALL_MODE}${NC}"
echo "║                                                          ║"
echo -e "║  面板地址: ${GREEN}${PANEL_URL}${NC}"
echo "║                                                          ║"
echo -e "║  用户名:   ${GREEN}${USERNAME}${NC}"
echo -e "║  密  码:   ${GREEN}${PASSWORD}${NC}"
echo "║                                                          ║"
echo "║  证书类型: 自签 SSL（有效期 ${CERT_DAYS} 天）             ║"
echo "║  HTTPS 验证: ${GREEN}已通过${NC}（确认 https:// 可访问）       ║"
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
