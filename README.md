# 3x-ui 一键部署脚本

纯 IP 访问 + HTTPS 自签证书 + 自定义端口/账号/根路径的 3x-ui 面板一键部署脚本。

## 特性

- **纯 IP 访问**：无需域名，直接用服务器公网 IP 访问
- **HTTPS 加密**：自动生成含 IP SAN 的自签 SSL 证书，面板链接以 `https://` 开头
- **预配置参数**：端口、用户名、密码、根路径一键设定
- **自动防火墙**：自动放行 ufw / firewalld 端口
- **无人值守**：基于官方 `XUI_NONINTERACTIVE=1` 安装，全程零交互

## 预设配置

| 项目 | 值 |
|------|-----|
| 面板端口 | `10601` |
| 用户名 | `admin` |
| 密码 | `000000` |
| 根路径 | `xui` |
| 证书有效期 | 3650 天（约 10 年） |

## 使用方法

### 一键部署

```bash
bash <(curl -Ls https://raw.githubusercontent.com/hongfeiz830/3x-ui-deploy/main/install.sh)
```

或下载后手动执行：

```bash
curl -O https://raw.githubusercontent.com/hongfeiz830/3x-ui-deploy/main/install.sh
chmod +x install.sh
sudo bash install.sh
```

### 访问面板

部署完成后，脚本会输出面板地址，格式为：

```
https://<服务器IP>:10601/xui
```

> **注意**：由于使用纯 IP + 自签证书，浏览器首次访问会提示安全警告，点击「高级」→「继续访问」即可正常使用。

## 自定义配置

编辑 `install.sh` 顶部的配置区：

```bash
PANEL_PORT="10601"          # 面板监听端口
USERNAME="admin"            # 登录用户名
PASSWORD="000000"           # 登录密码
WEB_BASE_PATH="xui"         # 面板根路径
CERT_DAYS="3650"            # 证书有效期（天）
```

## 管理命令

```bash
x-ui            # 进入交互管理菜单
x-ui restart    # 重启面板
x-ui status     # 查看运行状态
x-ui setting    # 查看当前配置
x-ui update     # 升级面板
```

## 系统要求

- 操作系统：Ubuntu / Debian / CentOS / Rocky / AlmaLinux
- 权限：root
- 网络：可访问 GitHub（用于下载安装脚本）

## 安全建议

1. 首次登录后立即修改默认密码
2. 如有域名，可在面板中替换为 Let's Encrypt 可信证书
3. 建议通过云服务商安全组限制面板端口的访问来源 IP
4. 定期执行 `x-ui update` 保持面板最新

## 相关链接

- 3x-ui 官方仓库：https://github.com/MHSanaei/3x-ui
- 3x-ui 官方文档：https://docs.sanaei.dev/
