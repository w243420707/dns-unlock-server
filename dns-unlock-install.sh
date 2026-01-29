#!/bin/bash
# =============================================================================
# DNS 解锁服务器一键安装脚本 (Ubuntu)
# 功能: 安装并配置 Dnsmasq + SNI Proxy，用于流媒体解锁
# 支持系统: Ubuntu 18.04 / 20.04 / 22.04
# =============================================================================

# 版本信息
VERSION="1.1.0"
LAST_UPDATE="2026-01-29"
CHANGELOG="新增日志等级选择功能 (DEBUG/INFO/WARN)"

set -e

# 默认日志等级
LOG_LEVEL="info"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # 无颜色

# 日志函数
log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# 选择日志等级
select_log_level() {
    echo ""
    echo -e "${BLUE}请选择日志记录等级:${NC}"
    echo -e "  ${GREEN}1)${NC} DEBUG - 详细调试信息（包含所有 DNS 查询日志）"
    echo -e "  ${GREEN}2)${NC} INFO  - 标准信息（推荐，记录主要操作）"
    echo -e "  ${GREEN}3)${NC} WARN  - 仅警告和错误（最少日志，适合生产环境）"
    echo ""
    read -p "请输入选项 [1-3] (默认: 2): " choice
    
    case "$choice" in
        1)
            LOG_LEVEL="debug"
            log_info "已选择日志等级: DEBUG"
            ;;
        3)
            LOG_LEVEL="warn"
            log_info "已选择日志等级: WARN"
            ;;
        *)
            LOG_LEVEL="info"
            log_info "已选择日志等级: INFO"
            ;;
    esac
}

# 检查是否为 root 用户
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "请使用 root 用户运行此脚本 (sudo bash $0)"
        exit 1
    fi
}

# 获取服务器公网 IP
get_public_ip() {
    PUBLIC_IP=$(curl -s https://api.ipify.org || curl -s https://ifconfig.me || curl -s https://icanhazip.com)
    if [[ -z "$PUBLIC_IP" ]]; then
        log_error "无法获取公网 IP，请检查网络连接"
        exit 1
    fi
    log_info "检测到公网 IP: ${BLUE}$PUBLIC_IP${NC}"
}

# 停止占用 53 端口的服务
stop_conflicting_services() {
    log_info "检查 53 端口占用情况..."
    
    # 停止 systemd-resolved（Ubuntu 默认的 DNS 解析服务）
    if systemctl is-active --quiet systemd-resolved; then
        log_warn "systemd-resolved 正在占用 53 端口，正在停止..."
        systemctl stop systemd-resolved
        systemctl disable systemd-resolved
        
        # 修复 /etc/resolv.conf
        rm -f /etc/resolv.conf
        echo "nameserver 8.8.8.8" > /etc/resolv.conf
        echo "nameserver 1.1.1.1" >> /etc/resolv.conf
        log_info "已停止 systemd-resolved 并修复 DNS 配置"
    fi
}

# 安装依赖
install_dependencies() {
    log_info "更新软件包列表..."
    apt-get update -y
    
    log_info "安装必要依赖..."
    apt-get install -y dnsmasq git autoconf automake gettext libtool libev-dev libpcre2-dev libcurl4-openssl-dev libudns-dev build-essential curl wget
}

# 安装 SNI Proxy
install_sniproxy() {
    log_info "开始安装 SNI Proxy..."
    
    cd /tmp
    rm -rf sniproxy
    git clone https://github.com/dlundquist/sniproxy.git
    cd sniproxy
    
    ./autogen.sh
    ./configure
    make
    make install
    
    log_info "SNI Proxy 安装完成"
}

# 配置 SNI Proxy
configure_sniproxy() {
    log_info "配置 SNI Proxy..."
    
    mkdir -p /etc/sniproxy
    
    # 根据日志等级设置 SNI Proxy 日志优先级
    case "$LOG_LEVEL" in
        debug)
            SNIPROXY_LOG_PRIORITY="debug"
            ;;
        info)
            SNIPROXY_LOG_PRIORITY="notice"
            ;;
        warn)
            SNIPROXY_LOG_PRIORITY="warning"
            ;;
    esac
    
    cat > /etc/sniproxy/sniproxy.conf << EOF
user daemon
pidfile /var/run/sniproxy.pid

error_log {
    filename /var/log/sniproxy/error.log
    priority $SNIPROXY_LOG_PRIORITY
}

listen 80 {
    proto http
    table http_hosts
    fallback 127.0.0.1:8080
}

listen 443 {
    proto tls
    table https_hosts
    fallback 127.0.0.1:8443
}

table http_hosts {
    .* *:80
}

table https_hosts {
    .* *:443
}
EOF

    mkdir -p /var/log/sniproxy
    
    # 创建 systemd 服务
    cat > /etc/systemd/system/sniproxy.service << 'EOF'
[Unit]
Description=SNI Proxy Service
After=network.target

[Service]
Type=forking
PIDFile=/var/run/sniproxy.pid
ExecStart=/usr/local/sbin/sniproxy -c /etc/sniproxy/sniproxy.conf
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable sniproxy
    systemctl start sniproxy
    
    log_info "SNI Proxy 配置完成并已启动"
}

# 配置 Dnsmasq
configure_dnsmasq() {
    log_info "配置 Dnsmasq..."
    
    # 备份原配置
    if [[ -f /etc/dnsmasq.conf ]]; then
        cp /etc/dnsmasq.conf /etc/dnsmasq.conf.bak
    fi
    
    # 根据日志等级设置 Dnsmasq 日志配置
    case "$LOG_LEVEL" in
        debug)
            DNSMASQ_LOG_CONFIG="log-queries
log-facility=/var/log/dnsmasq.log
log-dhcp"
            ;;
        info)
            DNSMASQ_LOG_CONFIG="log-queries
log-facility=/var/log/dnsmasq.log"
            ;;
        warn)
            DNSMASQ_LOG_CONFIG="log-facility=/var/log/dnsmasq.log
# 仅记录警告和错误，不记录查询"
            ;;
    esac
    
    # 写入主配置
    cat > /etc/dnsmasq.conf << EOF
# DNS 解锁服务器配置
# 日志等级: $LOG_LEVEL
port=53
no-resolv
server=8.8.8.8
server=1.1.1.1
cache-size=10000
$DNSMASQ_LOG_CONFIG

# 引入流媒体解锁规则
conf-dir=/etc/dnsmasq.d/,*.conf
EOF

    # 创建流媒体解锁规则目录
    mkdir -p /etc/dnsmasq.d
    
    # 写入流媒体域名解析规则（指向本机 IP）
    cat > /etc/dnsmasq.d/unlock.conf << EOF
# ============ Netflix ============
address=/netflix.com/$PUBLIC_IP
address=/netflix.net/$PUBLIC_IP
address=/nflximg.net/$PUBLIC_IP
address=/nflxvideo.net/$PUBLIC_IP
address=/nflxso.net/$PUBLIC_IP
address=/nflxext.com/$PUBLIC_IP

# ============ Disney+ ============
address=/disney.com/$PUBLIC_IP
address=/disneyplus.com/$PUBLIC_IP
address=/dssott.com/$PUBLIC_IP
address=/bamgrid.com/$PUBLIC_IP
address=/disney-plus.net/$PUBLIC_IP
address=/disneystreaming.com/$PUBLIC_IP

# ============ HBO Max ============
address=/hbo.com/$PUBLIC_IP
address=/hbomax.com/$PUBLIC_IP
address=/hbonow.com/$PUBLIC_IP
address=/hbogo.com/$PUBLIC_IP

# ============ Hulu ============
address=/hulu.com/$PUBLIC_IP
address=/huluim.com/$PUBLIC_IP
address=/hulustream.com/$PUBLIC_IP

# ============ Amazon Prime Video ============
address=/primevideo.com/$PUBLIC_IP
address=/amazon.com/$PUBLIC_IP
address=/amazonvideo.com/$PUBLIC_IP
address=/aiv-cdn.net/$PUBLIC_IP
address=/aiv-delivery.net/$PUBLIC_IP

# ============ YouTube Premium ============
address=/youtube.com/$PUBLIC_IP
address=/googlevideo.com/$PUBLIC_IP
address=/ytimg.com/$PUBLIC_IP
address=/youtube-nocookie.com/$PUBLIC_IP

# ============ Spotify ============
address=/spotify.com/$PUBLIC_IP
address=/scdn.co/$PUBLIC_IP
address=/spotifycdn.com/$PUBLIC_IP

# ============ Bilibili (港澳台) ============
address=/bilibili.com/$PUBLIC_IP
address=/bilivideo.com/$PUBLIC_IP
address=/biliapi.net/$PUBLIC_IP
EOF

    # 重启 Dnsmasq
    systemctl restart dnsmasq
    systemctl enable dnsmasq
    
    log_info "Dnsmasq 配置完成并已启动"
}

# 配置防火墙
configure_firewall() {
    log_info "配置防火墙规则..."
    
    # 使用 iptables 放行端口
    iptables -I INPUT -p udp --dport 53 -j ACCEPT
    iptables -I INPUT -p tcp --dport 53 -j ACCEPT
    iptables -I INPUT -p tcp --dport 80 -j ACCEPT
    iptables -I INPUT -p tcp --dport 443 -j ACCEPT
    
    # 如果安装了 ufw，也放行一下
    if command -v ufw &> /dev/null; then
        ufw allow 53/udp
        ufw allow 53/tcp
        ufw allow 80/tcp
        ufw allow 443/tcp
    fi
    
    log_info "防火墙规则已配置"
}

# 显示安装结果
show_result() {
    echo ""
    echo -e "${GREEN}============================================${NC}"
    echo -e "${GREEN}      DNS 解锁服务器安装成功！${NC}"
    echo -e "${GREEN}============================================${NC}"
    echo ""
    echo -e "服务器公网 IP: ${BLUE}$PUBLIC_IP${NC}"
    echo ""
    echo -e "服务状态:"
    echo -e "  - Dnsmasq:   $(systemctl is-active dnsmasq)"
    echo -e "  - SNI Proxy: $(systemctl is-active sniproxy)"
    echo -e "  - 日志等级:  ${BLUE}$LOG_LEVEL${NC}"
    echo ""
    echo -e "${YELLOW}在你的代理节点上，将 DNS 配置为:${NC}"
    echo -e "  ${BLUE}$PUBLIC_IP${NC}"
    echo ""
    echo -e "配置文件位置:"
    echo -e "  - Dnsmasq 主配置: /etc/dnsmasq.conf"
    echo -e "  - 解锁规则: /etc/dnsmasq.d/unlock.conf"
    echo -e "  - SNI Proxy 配置: /etc/sniproxy/sniproxy.conf"
    echo ""
    echo -e "${YELLOW}管理命令:${NC}"
    echo -e "  重启 Dnsmasq:   systemctl restart dnsmasq"
    echo -e "  重启 SNI Proxy: systemctl restart sniproxy"
    echo -e "  查看 DNS 日志:  tail -f /var/log/dnsmasq.log"
    echo ""
}

# 主函数
main() {
    echo ""
    echo -e "${BLUE}============================================${NC}"
    echo -e "${BLUE}   DNS 解锁服务器一键安装脚本 (Ubuntu)${NC}"
    echo -e "${BLUE}============================================${NC}"
    echo -e "  版本: ${GREEN}v$VERSION${NC}  更新日期: $LAST_UPDATE"
    echo -e "  ${YELLOW}最近更新: $CHANGELOG${NC}"
    echo ""
    
    check_root
    get_public_ip
    select_log_level
    stop_conflicting_services
    install_dependencies
    install_sniproxy
    configure_sniproxy
    configure_dnsmasq
    configure_firewall
    show_result
}

main "$@"
