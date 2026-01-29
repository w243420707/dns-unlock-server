#!/bin/bash
# =============================================================================
# DNS 解锁服务器一键安装脚本 (Ubuntu)
# 功能: 安装并配置 Dnsmasq + SNI Proxy，用于流媒体解锁
# 支持系统: Ubuntu 18.04 / 20.04 / 22.04
# =============================================================================

# 版本信息
VERSION="2.0.0"
LAST_UPDATE="2026-01-29"
CHANGELOG="全面支持流媒体测试脚本中的所有主流项目 (数十个平台全覆盖)"

set -e

# 默认设置
LOG_LEVEL="info"
PROXY_ENGINE="sniproxy" 
WARP_SOCKS="127.0.0.1:40000"
GEOSITE_CATEGORIES="openai,gemini,netflix,disney" # Geosite 备选分类
CUSTOM_DOMAINS="" # 用户手动输入的额外域名

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

# 选择代理引擎
select_proxy_engine() {
    echo ""
    echo -e "${BLUE}请选择代理引擎:${NC}"
    echo -e "  ${GREEN}1)${NC} SNI Proxy - 传统模式（适合大多数场景，不兼容全局 WARP）"
    echo -e "  ${GREEN}2)${NC} GOST      - 转发模式（推荐，配合 WARP SOCKS5 延迟低，无冲突）"
    echo ""
    
    if [ -t 0 ]; then
        read -p "请输入选项 [1-2] (默认: 1): " engine_choice
    elif [ -e /dev/tty ]; then
        read -p "请输入选项 [1-2] (默认: 1): " engine_choice < /dev/tty
    else
        engine_choice="1"
    fi
    
    if [[ "$engine_choice" == "2" ]]; then
        PROXY_ENGINE="gost"
        log_info "已选择代理引擎: GOST"
        
        # 询问 WARP SOCKS5 地址
        echo ""
        if [ -t 0 ]; then
            read -p "请输入 WARP SOCKS5 地址 [直接回车使用 $WARP_SOCKS]: " user_warp_socks
        elif [ -e /dev/tty ]; then
            read -p "请输入 WARP SOCKS5 地址 [直接回车使用 $WARP_SOCKS]: " user_warp_socks < /dev/tty
        else
            user_warp_socks=""
        fi
        
        if [[ -n "$user_warp_socks" ]]; then
            WARP_SOCKS="$user_warp_socks"
        fi
        log_info "将连接 WARP SOCKS5: ${GREEN}$WARP_SOCKS${NC}"
    else
        PROXY_ENGINE="sniproxy"
        log_info "已选择代理引擎: SNI Proxy"
    fi
}

# 检查是否为 root 用户
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "请使用 root 用户运行此脚本 (sudo bash $0)"
        exit 1
    fi
}

    log_info "使用入口 IP: ${GREEN}$PUBLIC_IP${NC}"
}

# 从 Geosite 下载并生成规则 (优化版)
fetch_geosite_category() {
    local category=$1
    local output_file=$2
    local source_url="https://raw.githubusercontent.com/v2fly/domain-list-community/master/data/${category}"
    
    log_info "正在从 Geosite 获取分类: ${YELLOW}${category}${NC} (这可能包含数千个域名)..."
    
    local tmp_data=$(curl -s "$source_url")
    if [[ -z "$tmp_data" || "$tmp_data" == "404: Not Found" ]]; then
        log_warn "分类 ${category} 未找到或内容为空，跳过"
        return
    fi
    
    # 使用 awk 高效处理大批量域名
    echo "$tmp_data" | awk -v ip="$PUBLIC_IP" '
    !/^#/ && !/^$/ {
        domain = ""
        if ($0 ~ /^full:/) {
            domain = substr($0, 6)
        } else if ($0 !~ /:/) {
            domain = $0
        }
        if (domain != "" && domain !~ /^$/) {
            # 输出 IPv4 劫持和 IPv6 阻断
            printf "address=/%s/%s\n", domain, ip
            printf "address=/%s/::\n", domain
        }
    }' >> "$output_file"
}

# 选择解锁范围
select_unlock_scope() {
    echo ""
    echo -e "${BLUE}请选择解锁域名范围:${NC}"
    echo -e "  ${GREEN}1)${NC} 常用关键词列表 (推荐：Netflix/Disney+/Gemini/OpenAI 等)"
    echo -e "  ${GREEN}2)${NC} Geosite 分类全量模式 (进阶：通过分类动态下载)"
    echo ""
    
    if [ -t 0 ]; then
        read -p "请输入选项 [1-2] (默认: 1): " scope_choice
    elif [ -e /dev/tty ]; then
        read -p "请输入选项 [1-2] (默认: 1): " scope_choice < /dev/tty
    else
        scope_choice="1"
    fi
    
    if [[ "$scope_choice" == "2" ]]; then
        UNLOCK_MODE="geosite"
        echo ""
        echo -e "${YELLOW}请输入要解锁的 Geosite 分类（逗号分隔）${NC}"
        if [ -t 0 ]; then
            read -p "分类列表 [默认: $GEOSITE_CATEGORIES]: " user_categories
        elif [ -e /dev/tty ]; then
            read -p "分类列表 [默认: $GEOSITE_CATEGORIES]: " user_categories < /dev/tty
        else
            user_categories=""
        fi
        
        if [[ -n "$user_categories" ]]; then
            GEOSITE_CATEGORIES="$user_categories"
        fi
        log_info "已选择 Geosite 模式，分类: ${GREEN}$GEOSITE_CATEGORIES${NC}"
    else
        UNLOCK_MODE="basic"
        log_info "已选择常用关键词模式"
        
        # 允许用户追加自定义域名
        echo ""
        echo -e "${YELLOW}是否需要追加额外的解锁域名？（如: bahamut.com.tw, hinet.net）${NC}"
        if [ -t 0 ]; then
            read -p "追加域名 (逗号分隔，无则直接回车): " user_custom
        elif [ -e /dev/tty ]; then
            read -p "追加域名 (逗号分隔，无则直接回车): " user_custom < /dev/tty
        else
            user_custom=""
        fi
        
        if [[ -n "$user_custom" ]]; then
            CUSTOM_DOMAINS="$user_custom"
            log_info "将额外追加域名: ${GREEN}$CUSTOM_DOMAINS${NC}"
        fi
    fi
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

# 安装 GOST
install_gost() {
    if command -v gost &> /dev/null; then
        log_info "GOST 已安装，跳过安装"
        return
    fi
    
    log_info "开始安装 GOST..."
    
    # 下载 GOST (v2.11.5)
    cd /tmp
    wget -q https://github.com/ginuerzh/gost/releases/download/v2.11.5/gost-linux-amd64-2.11.5.gz
    gunzip -f gost-linux-amd64-2.11.5.gz
    mv gost-linux-amd64-2.11.5 /usr/local/bin/gost
    chmod +x /usr/local/bin/gost
    
    log_info "GOST 安装完成"
}

# 配置 GOST
configure_gost() {
    log_info "配置 GOST..."
    
    # 停止并清理可能冲突的服务
    systemctl stop sniproxy 2>/dev/null || true
    systemctl disable sniproxy 2>/dev/null || true
    
    # 检查端口 80 和 443
    for port in 80 443; do
        if ss -tlnp 2>/dev/null | grep -q ":$port "; then
            systemctl stop nginx 2>/dev/null || true
            systemctl stop apache2 2>/dev/null || true
            systemctl stop httpd 2>/dev/null || true
            pkill -9 gost 2>/dev/null || true
            sleep 1
        fi
    done

    # 设置日志标志
    GOST_LOG_FLAG=""
    if [[ "$LOG_LEVEL" == "debug" ]]; then
        GOST_LOG_FLAG="-V"
    fi

    # 创建 systemd 服务
    cat > /etc/systemd/system/gost-unlock.service << EOF
[Unit]
Description=GOST Unlock Service (SNI over SOCKS5)
After=network.target

[Service]
Type=simple
# 监听 80/443，使用 sni 模式，转发给 WARP SOCKS5
ExecStart=/usr/local/bin/gost $GOST_LOG_FLAG -L "sni://:80?bypass=127.0.0.1" -L "sni://:443?bypass=127.0.0.1" -F "socks5://$WARP_SOCKS"
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable gost-unlock
    
    if systemctl restart gost-unlock; then
        log_info "GOST 配置完成并已启动"
    else
        log_error "GOST 启动失败，请检查端口占用及 $WARP_SOCKS 是否可用"
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

# 强制使用外部 DNS 解析目标 IP，防止死循环
resolver {
    nameserver 8.8.8.8
    mode ipv4_only
}

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
cache-size=20480
dns-forward-max=1024

# 允许任意 IP 查询（重要：解锁服务器必须开启）
listen-address=0.0.0.0
bind-interfaces

$DNSMASQ_LOG_CONFIG

# 引入流媒体解锁规则
conf-dir=/etc/dnsmasq.d/,*.conf
EOF

    # 创建流媒体解锁规则目录
    mkdir -p /etc/dnsmasq.d
    
    # 写入流媒体域名解析规则
    if [[ "$UNLOCK_MODE" == "geosite" ]]; then
        log_info "开始从 Geosite 动态生成规则..."
        echo "# ============ Geosite 解锁规则 ($GEOSITE_CATEGORIES) ============" > /etc/dnsmasq.d/unlock.conf
        IFS=',' read -ra ADDR <<< "$GEOSITE_CATEGORIES"
        for cat in "${ADDR[@]}"; do
            fetch_geosite_category "$cat" "/etc/dnsmasq.d/unlock.conf"
        done
        
        # 补齐 IP 检测网站
        cat >> /etc/dnsmasq.d/unlock.conf << EOF

# ============ IP 检测网站 ============
address=/ip.sb/$PUBLIC_IP
address=/ip.sb/::
address=/ip.gs/$PUBLIC_IP
address=/ip.gs/::
address=/ip.me/$PUBLIC_IP
address=/ip.me/::
address=/ipinfo.io/$PUBLIC_IP
address=/ipinfo.io/::
address=/fast.com/$PUBLIC_IP
address=/fast.com/::
address=/speedtest.net/$PUBLIC_IP
address=/speedtest.net/::
EOF
    else
        # 基础列表模式
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

# ============ TikTok (International) ============
address=/tiktok.com/$PUBLIC_IP
address=/tiktokv.com/$PUBLIC_IP
address=/tiktokcdn.com/$PUBLIC_IP
address=/byteoversea.com/$PUBLIC_IP
address=/ibyteimg.com/$PUBLIC_IP
address=/ipstatp.com/$PUBLIC_IP
address=/muscdn.com/$PUBLIC_IP
address=/musical.ly/$PUBLIC_IP

# ============ Spotify ============
address=/spotify.com/$PUBLIC_IP
address=/scdn.co/$PUBLIC_IP
address=/spotifycdn.com/$PUBLIC_IP

# ============ Bilibili (港澳台) ============
address=/bilibili.com/$PUBLIC_IP
address=/bilivideo.com/$PUBLIC_IP
address=/biliapi.net/$PUBLIC_IP

# ============ iQIYI (International) ============
address=/iq.com/$PUBLIC_IP
address=/iqiyi.com/$PUBLIC_IP
address=/iqiyipic.com/$PUBLIC_IP

# ============ TVB (Anywhere) ============
address=/tvb.com/$PUBLIC_IP
address=/tvboxnow.com/$PUBLIC_IP
address=/tvbanywhere.com/$PUBLIC_IP
address=/tvbanywhere.com.sg/$PUBLIC_IP
address=/mytvsuper.com/$PUBLIC_IP

# ============ Now TV / Now E ============
address=/now.com/$PUBLIC_IP
address=/nowe.com/$PUBLIC_IP
address=/nowtv.com/$PUBLIC_IP

# ============ Viu (HK) ============
address=/viu.com/$PUBLIC_IP
address=/viu.tv/$PUBLIC_IP
address=/viu.now.com/$PUBLIC_IP

# ============ 巴哈姆特 (动画疯) ============
address=/gamer.com.tw/$PUBLIC_IP
address=/bahamut.com.tw/$PUBLIC_IP
address=/hinet.net/$PUBLIC_IP

# ============ AbemaTV (JP) ============
address=/abema.tv/$PUBLIC_IP
address=/abema.io/$PUBLIC_IP
address=/ameba.jp/$PUBLIC_IP
address=/hayabusa.io/$PUBLIC_IP

# ============ DAZN ============
address=/dazn.com/$PUBLIC_IP
address=/dazn-api.com/$PUBLIC_IP
address=/daznedge.net/$PUBLIC_IP

# ============ BBC iPlayer ============
address=/bbc.co.uk/$PUBLIC_IP
address=/bbci.co.uk/$PUBLIC_IP

# ============ ITV / Channel 4 / My5 ============
address=/itv.com/$PUBLIC_IP
address=/channel4.com/$PUBLIC_IP
address=/my5.tv/$PUBLIC_IP

# ============ Sky Go / Now TV (UK) ============
address=/sky.com/$PUBLIC_IP
address=/skygo.com/$PUBLIC_IP

# ============ Discovery+ ============
address=/discovery.com/$PUBLIC_IP
address=/discoveryplus.com/$PUBLIC_IP

# ============ Paramount+ / Peacock ============
address=/paramountplus.com/$PUBLIC_IP
address=/cbsvids.com/$PUBLIC_IP
address=/pplusnative.com/$PUBLIC_IP
address=/peacocktv.com/$PUBLIC_IP

# ============ Hotstar / JioCinema ============
address=/hotstar.com/$PUBLIC_IP
address=/jiocinema.com/$PUBLIC_IP

# ============ Starz / Showtime / AMC+ ============
address=/starz.com/$PUBLIC_IP
address=/sho.com/$PUBLIC_IP
address=/showtime.com/$PUBLIC_IP
address=/amc.com/$PUBLIC_IP
address=/amcplus.com/$PUBLIC_IP

# ============ OpenAI (ChatGPT) ============
address=/chat.com/$PUBLIC_IP
address=/chat.com/::
address=/chatgpt.com/$PUBLIC_IP
address=/chatgpt.com/::
address=/oaistatic.com/$PUBLIC_IP
address=/oaistatic.com/::
address=/oaiusercontent.com/$PUBLIC_IP
address=/oaiusercontent.com/::
address=/openai.com/$PUBLIC_IP
address=/openai.com/::
address=/sora.com/$PUBLIC_IP
address=/sora.com/::

# ============ Claude AI (Anthropic) ============
address=/anthropic.com/$PUBLIC_IP
address=/anthropic.com/::
address=/claude.ai/$PUBLIC_IP
address=/claude.ai/::

# ============ AI Extensions (Poe/Perplexity/Copilot) ============
address=/poe.com/$PUBLIC_IP
address=/poe.com/::
address=/perplexity.ai/$PUBLIC_IP
address=/perplexity.ai/::
address=/bing.com/$PUBLIC_IP
address=/bing.com/::

# ============ Google Gemini ============
address=/gemini.google.com/$PUBLIC_IP
address=/gemini.google.com/::
address=/bard.google.com/$PUBLIC_IP
address=/bard.google.com/::
address=/aistudio.google.com/$PUBLIC_IP
address=/aistudio.google.com/::
address=/deepmind.com/$PUBLIC_IP
address=/deepmind.com/::
address=/deepmind.google/$PUBLIC_IP
address=/deepmind.google/::
address=/generativelanguage.googleapis.com/$PUBLIC_IP
address=/generativelanguage.googleapis.com/::
address=/alkalimessages-pa.googleapis.com/$PUBLIC_IP
address=/alkalimessages-pa.googleapis.com/::

# ============ IP 检测网站 ============
address=/ip.sb/$PUBLIC_IP
address=/ip.sb/::
address=/ip.gs/$PUBLIC_IP
address=/ip.gs/::
address=/ip.me/$PUBLIC_IP
address=/ip.me/::
address=/ipinfo.io/$PUBLIC_IP
address=/ipinfo.io/::
address=/fast.com/$PUBLIC_IP
address=/fast.com/::
address=/speedtest.net/$PUBLIC_IP
address=/speedtest.net/::
EOF
    fi

    # 处理追加的自定义域名
    if [[ -n "$CUSTOM_DOMAINS" ]]; then
        log_info "正在追加自定义域名规则..."
        echo -e "\n# ============ Custom Domains ============" >> /etc/dnsmasq.d/unlock.conf
        IFS=',' read -ra C_ADDR <<< "$CUSTOM_DOMAINS"
        for dom in "${C_ADDR[@]}"; do
            dom_clean=$(echo "$dom" | xargs) # 去除空格
            if [[ -n "$dom_clean" ]]; then
                echo "address=/${dom_clean}/$PUBLIC_IP" >> /etc/dnsmasq.d/unlock.conf
                echo "address=/${dom_clean}/::" >> /etc/dnsmasq.d/unlock.conf
            fi
        done
    fi

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
    if [[ "$PROXY_ENGINE" == "gost" ]]; then
        echo -e "  - GOST (Eng): $(systemctl is-active gost-unlock)"
    else
        echo -e "  - SNI Proxy: $(systemctl is-active sniproxy)"
    fi
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
    if [[ "$PROXY_ENGINE" == "gost" ]]; then
        echo -e "  重启 GOST:      systemctl restart gost-unlock"
    else
        echo -e "  重启 SNI Proxy: systemctl restart sniproxy"
    fi
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
    echo "  --status            显示当前服务状态"
    echo "  --update-domains    更新 Geosite 解锁域名列表"
    echo "  --log-level LEVEL   调整日志等级 (debug/info/warn)"
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
    if [ -f /etc/sniproxy.conf ]; then
        sed -i "s/priority .*/priority $SNIPROXY_LOG_PRIORITY/" /etc/sniproxy.conf
        systemctl restart sniproxy 2>/dev/null || true
        log_info "SNI Proxy 日志等级已更新"
    fi
    
    log_info "日志等级调整完成: $LOG_LEVEL"
}

# 更新域名规则
update_domains() {
    log_info "正在更新解锁域名规则..."
    
    # 获取入口 IP
    if [ -f /etc/dnsmasq.d/unlock.conf ]; then
        PUBLIC_IP=$(grep -oE "[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+" /etc/dnsmasq.d/unlock.conf | head -1)
    fi
    
    if [[ -z "$PUBLIC_IP" ]]; then
        PUBLIC_IP=$(curl -s https://api.ipify.org || curl -s https://ifconfig.me || echo "127.0.0.1")
    fi
    
    # 重新确定模式
    if grep -q "Geosite 解锁规则" /etc/dnsmasq.d/unlock.conf 2>/dev/null; then
        UNLOCK_MODE="geosite"
        # 尝试提取之前的分类
        GEOSITE_CATEGORIES=$(grep -oP "\(.*?\)" /etc/dnsmasq.d/unlock.conf | head -1 | tr -d '()')
    else
        UNLOCK_MODE="basic"
    fi
    
    log_info "当前模式: $UNLOCK_MODE, 入口 IP: $PUBLIC_IP"
    configure_dnsmasq
    log_info "域名规则已更新并重启服务"
}

# 显示服务状态
show_status() {
    echo ""
    echo -e "${BLUE}============================================${NC}"
    echo -e "${BLUE}      DNS 解锁服务器状态${NC}"
    echo -e "${BLUE}============================================${NC}"
    echo ""
    echo -e "Dnsmasq 状态:   $(systemctl is-active dnsmasq 2>/dev/null || echo '未安装')"
    if systemctl is-active gost-unlock &>/dev/null; then
        echo -e "GOST 状态:      ${GREEN}active${NC}"
    elif systemctl is-active sniproxy &>/dev/null; then
        echo -e "SNI Proxy 状态: ${GREEN}active${NC}"
    else
        echo -e "代理引擎状态:   ${RED}未运行 (SNI Proxy/GOST)${NC}"
    fi
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
            --update-domains)
                check_root
                update_domains
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
    select_proxy_engine
    select_unlock_scope
    stop_conflicting_services
    install_dependencies
    
    if [[ "$PROXY_ENGINE" == "gost" ]]; then
        install_gost
        configure_gost
    else
        install_sniproxy
        configure_sniproxy
    fi
    
    configure_dnsmasq
    configure_firewall
    show_result
}

main "$@"
