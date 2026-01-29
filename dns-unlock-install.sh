#!/bin/bash
# =============================================================================
# DNS 解锁服务器一键安装脚本 (Ubuntu)
# 功能: 安装并配置 Dnsmasq + SNI Proxy，用于流媒体解锁
# 支持系统: Ubuntu 18.04 / 20.04 / 22.04
# =============================================================================

# 版本信息
VERSION="1.5.1"
LAST_UPDATE="2026-01-29"
CHANGELOG="支持手动指定入口 IP，解决 WARP 等场景下 IP 检测错误"

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
    echo -e "  ${GREEN}2)${NC} INFO  - 标准信息（记录主要操作）"
    echo -e "  ${GREEN}3)${NC} WARN  - 仅警告和错误（推荐，最少日志）"
    echo ""
    
    # 检查是否可以从终端读取（支持管道模式）
    if [ -t 0 ]; then
        # 标准输入是终端，可以正常读取
        read -p "请输入选项 [1-3] (默认: 3): " choice
    elif [ -e /dev/tty ]; then
        # 通过管道执行，尝试从 /dev/tty 读取
        read -p "请输入选项 [1-3] (默认: 3): " choice < /dev/tty
    else
        # 无法交互，使用默认值
        log_warn "无法获取用户输入，使用默认日志等级: WARN"
        choice="3"
    fi
    
    case "$choice" in
        1)
            LOG_LEVEL="debug"
            log_info "已选择日志等级: DEBUG"
            ;;
        2)
            LOG_LEVEL="info"
            log_info "已选择日志等级: INFO"
            ;;
        *)
            LOG_LEVEL="warn"
            log_info "已选择日志等级: WARN"
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
    # 自动检测公网 IP
    DETECTED_IP=$(curl -s https://api.ipify.org || curl -s https://ifconfig.me || curl -s https://icanhazip.com)
    
    echo ""
    echo -e "${BLUE}检测到的公网 IP: ${GREEN}${DETECTED_IP}${NC}"
    echo -e "${YELLOW}注意: 如果你使用了 WARP 或其他出口代理，检测到的可能是出口 IP${NC}"
    echo -e "${YELLOW}      你需要输入服务器的入口 IP（用于接收 DNS 请求）${NC}"
    echo ""
    
    # 让用户确认或输入正确的 IP
    if [ -t 0 ]; then
        read -p "请输入服务器入口 IP [直接回车使用 $DETECTED_IP]: " USER_IP
    elif [ -e /dev/tty ]; then
        read -p "请输入服务器入口 IP [直接回车使用 $DETECTED_IP]: " USER_IP < /dev/tty
    else
        USER_IP=""
    fi
    
    if [[ -n "$USER_IP" ]]; then
        PUBLIC_IP="$USER_IP"
    else
        PUBLIC_IP="$DETECTED_IP"
    fi
    
    if [[ -z "$PUBLIC_IP" ]]; then
        log_error "无法获取公网 IP，请检查网络连接"
        exit 1
    fi
    
    log_info "使用入口 IP: ${GREEN}$PUBLIC_IP${NC}"
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

# 检查软件包是否已安装
is_package_installed() {
    dpkg -l "$1" 2>/dev/null | grep -q "^ii"
}

# 安装依赖
install_dependencies() {
    log_info "检查依赖安装状态..."
    
    # 定义需要的软件包列表
    REQUIRED_PACKAGES=(
        "dnsmasq"
        "git"
        "autoconf"
        "automake"
        "gettext"
        "libtool"
        "libev-dev"
        "libpcre2-dev"
        "libcurl4-openssl-dev"
        "libudns-dev"
        "build-essential"
        "curl"
        "wget"
    )
    
    # 检查哪些包需要安装
    MISSING_PACKAGES=()
    for pkg in "${REQUIRED_PACKAGES[@]}"; do
        if is_package_installed "$pkg"; then
            log_info "  ✓ $pkg 已安装"
        else
            log_warn "  ✗ $pkg 未安装"
            MISSING_PACKAGES+=("$pkg")
        fi
    done
    
    # 如果有缺失的包，则安装
    if [ ${#MISSING_PACKAGES[@]} -eq 0 ]; then
        log_info "所有依赖已安装，跳过安装步骤"
    else
        log_info "正在安装缺失的依赖: ${MISSING_PACKAGES[*]}"
        apt-get update -y
        apt-get install -y "${MISSING_PACKAGES[@]}"
        log_info "依赖安装完成"
    fi
}

# 安装 SNI Proxy
install_sniproxy() {
    # 检查 SNI Proxy 是否已安装
    if command -v sniproxy &> /dev/null; then
        log_info "SNI Proxy 已安装，跳过安装"
        return
    fi
    
    log_info "开始安装 SNI Proxy..."
    
    # 使用 apt 包管理器安装（更可靠）
    apt-get update -y >/dev/null 2>&1
    
    # 先删除可能存在的旧编译版本
    rm -f /usr/local/sbin/sniproxy 2>/dev/null || true
    rm -f /etc/systemd/system/sniproxy.service 2>/dev/null || true
    
    # 安装 sniproxy 包
    if apt-get install -y sniproxy 2>/dev/null; then
        log_info "SNI Proxy (apt) 安装完成"
    else
        log_warn "apt 安装失败，尝试从源码编译..."
        # 备用：从源码编译
        apt-get install -y git autoconf automake libtool libev-dev libpcre2-dev libudns-dev build-essential >/dev/null 2>&1
        cd /tmp
        rm -rf sniproxy
        git clone https://github.com/dlundquist/sniproxy.git
        cd sniproxy
        ./autogen.sh 2>/dev/null || true
        ./configure
        make
        make install
        log_info "SNI Proxy (源码) 安装完成"
    fi
}

# 配置 SNI Proxy
configure_sniproxy() {
    log_info "配置 SNI Proxy..."
    
    # 检查端口 80 和 443 是否被占用
    log_info "检查端口占用情况..."
    for port in 80 443; do
        if ss -tlnp 2>/dev/null | grep -q ":$port "; then
            PROCESS=$(ss -tlnp 2>/dev/null | grep ":$port " | head -1)
            log_warn "端口 $port 已被占用: $PROCESS"
            log_info "尝试停止占用端口的服务..."
            # 尝试停止常见的 Web 服务
            systemctl stop nginx 2>/dev/null || true
            systemctl stop apache2 2>/dev/null || true
            systemctl stop httpd 2>/dev/null || true
            systemctl stop sniproxy 2>/dev/null || true
            sleep 2
        fi
    done
    
    mkdir -p /var/log/sniproxy
    chown daemon:daemon /var/log/sniproxy 2>/dev/null || true
    
    # 根据日志等级设置 SNI Proxy 日志优先级
    case "$LOG_LEVEL" in
        debug)
            SNIPROXY_LOG_PRIORITY="debug"
            ;;
        info)
            SNIPROXY_LOG_PRIORITY="notice"
            ;;
        warn|*)
            SNIPROXY_LOG_PRIORITY="warning"
            ;;
    esac
    
    # 写入 SNI Proxy 配置文件（apt 版本使用 /etc/sniproxy.conf）
    cat > /etc/sniproxy.conf << SNICONF
user daemon
pidfile /run/sniproxy.pid

error_log {
    syslog daemon
    priority ${SNIPROXY_LOG_PRIORITY}
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
SNICONF
    
    # 重启 SNI Proxy 服务
    systemctl daemon-reload
    systemctl enable sniproxy 2>/dev/null || true
    
    if systemctl restart sniproxy 2>/dev/null; then
        log_info "SNI Proxy 配置完成并已启动"
    else
        log_warn "SNI Proxy 服务启动失败，尝试手动启动..."
        # 尝试直接运行
        pkill -9 sniproxy 2>/dev/null || true
        sleep 1
        sniproxy 2>/dev/null &
        sleep 2
        if pgrep -x sniproxy > /dev/null; then
            log_info "SNI Proxy 已通过备用方式启动"
        else
            log_error "SNI Proxy 启动失败，请手动检查"
        fi
    fi
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

# 允许任意 IP 查询（重要：解锁服务器必须开启）
listen-address=0.0.0.0
bind-interfaces

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

# ============ IP 检测网站 ============
address=/ip.sb/$PUBLIC_IP
address=/ip.gs/$PUBLIC_IP
address=/ip.me/$PUBLIC_IP
address=/ipinfo.io/$PUBLIC_IP
address=/fast.com/$PUBLIC_IP
address=/speedtest.net/$PUBLIC_IP
EOF

    # 重启 Dnsmasq
    systemctl restart dnsmasq
    systemctl enable dnsmasq
    
    log_info "Dnsmasq 配置完成并已启动"
}

# 配置防火墙 (持久化关闭)
configure_firewall() {
    log_info "开始持久化关闭系统防火墙..."
    
    # 1. 停止并禁用 UFW (Ubuntu/Debian)
    if command -v ufw &> /dev/null; then
        log_info "检测到 UFW，正在禁用..."
        ufw disable >/dev/null 2>&1 || true
        systemctl stop ufw >/dev/null 2>&1 || true
        systemctl disable ufw >/dev/null 2>&1 || true
    fi

    # 2. 停止并禁用 Firewalld (CentOS/RHEL/Ubuntu)
    if systemctl is-active --quiet firewalld || systemctl is-enabled --quiet firewalld; then
        log_info "检测到 Firewalld，正在禁用..."
        systemctl stop firewalld >/dev/null 2>&1 || true
        systemctl disable firewalld >/dev/null 2>&1 || true
    fi

    # 3. 清理 Iptables 规则并设置默认策略为 ACCEPT
    log_info "正在清理 Iptables 规则并设为全放行..."
    iptables -P INPUT ACCEPT
    iptables -P FORWARD ACCEPT
    iptables -P OUTPUT ACCEPT
    iptables -t nat -F
    iptables -t mangle -F
    iptables -F
    iptables -X
    
    # 4. 清理 Ip6tables 规则 (IPv6)
    if command -v ip6tables &> /dev/null; then
        ip6tables -P INPUT ACCEPT
        ip6tables -P FORWARD ACCEPT
        ip6tables -P OUTPUT ACCEPT
        ip6tables -t nat -F
        ip6tables -t mangle -F
        ip6tables -F
        ip6tables -X
    fi

    # 5. 持久化清理 (部分系统可能需要安装 iptables-persistent，但直接清理已运行的即可)
    log_info "防火墙已持久化关闭，所有端口已放行"
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

# 显示帮助信息
show_help() {
    echo ""
    echo -e "${BLUE}DNS 解锁服务器一键安装脚本 v$VERSION${NC}"
    echo ""
    echo "用法: $0 [选项]"
    echo ""
    echo "选项:"
    echo "  --help, -h          显示此帮助信息"
    echo "  --log-level LEVEL   调整日志等级 (debug/info/warn)"
    echo "  --status            显示当前服务状态"
    echo ""
    echo "示例:"
    echo "  $0                  运行完整安装"
    echo "  $0 --log-level warn 仅调整日志等级为 WARN"
    echo "  $0 --status         显示服务状态"
    echo ""
}

# 调整日志等级（不重新安装）
adjust_log_level() {
    local level="$1"
    
    case "$level" in
        debug|DEBUG)
            LOG_LEVEL="debug"
            DNSMASQ_LOG_CONFIG="log-queries
log-facility=/var/log/dnsmasq.log
log-dhcp"
            SNIPROXY_LOG_PRIORITY="debug"
            ;;
        info|INFO)
            LOG_LEVEL="info"
            DNSMASQ_LOG_CONFIG="log-queries
log-facility=/var/log/dnsmasq.log"
            SNIPROXY_LOG_PRIORITY="notice"
            ;;
        warn|WARN)
            LOG_LEVEL="warn"
            DNSMASQ_LOG_CONFIG="log-facility=/var/log/dnsmasq.log
# 仅记录警告和错误，不记录查询"
            SNIPROXY_LOG_PRIORITY="warning"
            ;;
        *)
            log_error "无效的日志等级: $level (可选: debug/info/warn)"
            exit 1
            ;;
    esac
    
    log_info "正在调整日志等级为: $LOG_LEVEL"
    
    # 获取公网 IP
    PUBLIC_IP=$(curl -s https://api.ipify.org || curl -s https://ifconfig.me || echo "127.0.0.1")
    
    # 更新 Dnsmasq 配置
    if [ -f /etc/dnsmasq.conf ]; then
        # 备份原配置
        cp /etc/dnsmasq.conf /etc/dnsmasq.conf.bak.$(date +%s)
        
        # 重新生成配置
        cat > /etc/dnsmasq.conf << EOF
# DNS 解锁服务器配置
# 日志等级: $LOG_LEVEL
port=53
no-resolv
server=8.8.8.8
server=1.1.1.1
cache-size=10000

# 允许任意 IP 查询
listen-address=0.0.0.0
bind-interfaces

$DNSMASQ_LOG_CONFIG

# 引入流媒体解锁规则
conf-dir=/etc/dnsmasq.d/,*.conf
EOF
        systemctl restart dnsmasq
        log_info "Dnsmasq 日志等级已更新"
    else
        log_error "未找到 Dnsmasq 配置文件，请先运行完整安装"
        exit 1
    fi
    
    # 更新 SNI Proxy 配置
    if [ -f /etc/sniproxy/sniproxy.conf ]; then
        sed -i "s/priority .*/priority $SNIPROXY_LOG_PRIORITY/" /etc/sniproxy/sniproxy.conf
        systemctl restart sniproxy 2>/dev/null || true
        log_info "SNI Proxy 日志等级已更新"
    fi
    
    log_info "日志等级调整完成: $LOG_LEVEL"
}

# 显示服务状态
show_status() {
    echo ""
    echo -e "${BLUE}============================================${NC}"
    echo -e "${BLUE}      DNS 解锁服务器状态${NC}"
    echo -e "${BLUE}============================================${NC}"
    echo ""
    echo -e "Dnsmasq 状态:   $(systemctl is-active dnsmasq 2>/dev/null || echo '未安装')"
    echo -e "SNI Proxy 状态: $(systemctl is-active sniproxy 2>/dev/null || echo '未安装')"
    echo ""
    
    if [ -f /etc/dnsmasq.conf ]; then
        CURRENT_LEVEL=$(grep "# 日志等级:" /etc/dnsmasq.conf 2>/dev/null | cut -d: -f2 | tr -d ' ')
        echo -e "当前日志等级: ${GREEN}${CURRENT_LEVEL:-未知}${NC}"
    fi
    echo ""
}

# 主函数
main() {
    # 解析命令行参数
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help|-h)
                show_help
                exit 0
                ;;
            --log-level)
                check_root
                adjust_log_level "$2"
                exit 0
                ;;
            --status)
                show_status
                exit 0
                ;;
            *)
                log_error "未知参数: $1"
                show_help
                exit 1
                ;;
        esac
        shift
    done
    
    # 无参数时运行完整安装
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
