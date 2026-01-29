# DNS 解锁服务器

一键安装脚本，用于部署 DNS 解锁服务器，支持流媒体内容解锁。

## 功能特性

- 🎬 支持多种流媒体平台解锁（Netflix、Disney+、HBO Max、Hulu、YouTube Premium 等）
- 🚀 一键自动安装配置
- 🔧 基于 Dnsmasq + SNI Proxy 架构
- 📝 可选日志等级（DEBUG / INFO / WARN）
- 🛡️ 自动禁用并持久化关闭系统防火墙 (UFW/Firewalld/Iptables)

## 系统要求

- Ubuntu 18.04 / 20.04 / 22.04
- Root 权限
- 独立公网 IP

## 快速安装

```bash
curl -fsSL https://raw.githubusercontent.com/w243420707/dns-unlock-server/master/dns-unlock-install.sh | sudo bash
```

或者下载后执行：

```bash
wget -O dns-unlock-install.sh https://raw.githubusercontent.com/w243420707/dns-unlock-server/master/dns-unlock-install.sh && chmod +x dns-unlock-install.sh && sudo ./dns-unlock-install.sh
```

## 支持的流媒体平台

| 平台 | 域名 |
|------|------|
| Netflix | netflix.com, nflxvideo.net 等 |
| Disney+ | disneyplus.com, disney.com 等 |
| HBO Max | hbomax.com, hbo.com 等 |
| Hulu | hulu.com |
| Amazon Prime Video | primevideo.com |
| YouTube Premium | youtube.com |
| Spotify | spotify.com |
| Bilibili (港澳台) | bilibili.com |

## 使用方法

安装完成后，在你的代理节点上将 DNS 服务器设置为本服务器的公网 IP。

## 日志等级

安装时可以选择日志记录等级：

| 等级 | 说明 | 适用场景 |
|------|------|----------|
| DEBUG | 记录所有 DNS 查询 + DHCP 信息 | 调试问题 |
| INFO | 记录所有 DNS 查询（默认） | 日常使用 |
| WARN | 仅记录警告和错误 | 生产环境 |

## 配置文件位置

| 配置 | 路径 |
|------|------|
| Dnsmasq 主配置 | `/etc/dnsmasq.conf` |
| 解锁规则 | `/etc/dnsmasq.d/unlock.conf` |
| SNI Proxy 配置 | `/etc/sniproxy/sniproxy.conf` |

## 管理命令

```bash
# 重启 Dnsmasq
systemctl restart dnsmasq

# 重启 SNI Proxy
systemctl restart sniproxy

# 查看 DNS 日志
tail -f /var/log/dnsmasq.log
```

## 开放端口

脚本会自动配置防火墙开放以下端口：

- `53/UDP` - DNS
- `53/TCP` - DNS
- `80/TCP` - HTTP
- `443/TCP` - HTTPS

## 更新日志

| 版本 | 日期 | 更新内容 |
|------|------|----------|
| v1.5.0 | 2026-01-29 | 改用 apt 包安装 SNI Proxy，大幅提高成功率 |
| v1.4.0 | 2026-01-29 | 新增 --log-level 参数调整日志等级 |
| v1.3.3 | 2026-01-29 | 允许外部 IP 查询 DNS，添加 IP 检测网站 |
| v1.3.2 | 2026-01-29 | 修复 SNI Proxy 启动失败，添加端口冲突检测 |
| v1.3.1 | 2026-01-29 | 修复 autoconf 版本过低导致编译失败 |
| v1.3.0 | 2026-01-29 | 自动禁用并持久化关闭系统防火墙 |
| v1.2.1 | 2026-01-29 | 修复管道模式下无法选择日志等级 |
| v1.2.0 | 2026-01-29 | 智能检测依赖，跳过已安装的包 |
| v1.1.0 | 2026-01-29 | 添加日志等级选择功能 |
| v1.0.0 | 2026-01-29 | 初始版本 |

## 许可证

MIT License
