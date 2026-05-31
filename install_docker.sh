#!/bin/bash

# ==============================================================================
# 脚本名称: install_docker.sh
# 描述: 主流 Linux 系统 Docker & Docker Compose 交互式一键安装脚本
# 支持系统: Debian, Ubuntu, CentOS, Rocky Linux, AlmaLinux 等
# ==============================================================================

# 字体颜色定义
GREEN="\e[32m"
RED="\e[31m"
YELLOW="\e[33m"
BLUE="\e[36m"
PLAIN="\e[0m"

# 日志输出函数
info() { echo -e "${BLUE}[INFO]${PLAIN} $1"; }
success() { echo -e "${GREEN}[SUCCESS]${PLAIN} $1"; }
warn() { echo -e "${YELLOW}[WARN]${PLAIN} $1"; }
error() { echo -e "${RED}[ERROR]${PLAIN} $1"; exit 1; }

# 1. 权限与运行用户检查
REAL_USER=${SUDO_USER:-$USER}
if [ "$REAL_USER" = "root" ]; then
    warn "当前直接以 root 用户运行，非管理员运行配置将直接作用于 root 用户。"
fi

# 确保拥有 sudo 权限
if [ "$EUID" -ne 0 ]; then
    info "检测到当前未以 root 权限运行，尝试获取临时 sudo 权限..."
    sudo -v || error "需要 sudo 权限来执行此脚本！请确保当前用户有 sudo 权限。"
fi

# 2. 检查并安装必要的基础依赖 (curl, wget)
check_dependencies() {
    info "正在检查基础工具 (curl, wget)..."
    for cmd in curl wget; do
        if ! command -v $cmd &> /dev/null; then
            info "正在安装缺失的依赖: $cmd ..."
            if command -v apt-get &> /dev/null; then
                sudo apt-get update && sudo apt-get install -y $cmd
            elif command -v yum &> /dev/null; then
                sudo yum install -y $cmd
            elif command -v dnf &> /dev/null; then
                sudo dnf install -y $cmd
            else
                error "未找到主流包管理器，请手动安装 $cmd 后重试。"
            fi
        fi
    done
    success "基础依赖检查完成。"
}

# 3. 选择网络环境
select_network() {
    if [ -n "$NETWORK" ]; then return; fi # 避免重复触发
    echo -e "\n${BLUE}========================================${PLAIN}"
    echo -e "       请选择您当前服务器的网络环境"
    echo -e "  1) 国内网络环境 (使用阿里云源 & gh-proxy 加速代理)"
    echo -e "  2) 境外网络环境 (使用 Docker 官方默认源)"
    echo -e "${BLUE}========================================${PLAIN}"
    read -p "请输入序号 [1-2] (默认 1): " net_choice
    net_choice=${net_choice:-1}
    if [ "$net_choice" = "1" ]; then
        NETWORK="CN"
        info "已选择：国内网络环境"
    else
        NETWORK="GLOBAL"
        info "已选择：境外网络环境"
    fi
}

# 4. 执行 Docker 核心安装
install_docker() {
    info "开始安装/更新 Docker..."
    if command -v docker &> /dev/null; then
        warn "检测到系统中已存在 Docker:"
        docker --version
        read -p "是否强制重新安装/升级 Docker? [y/N]: " re_install
        if [[ ! "$re_install" =~ ^[Yy]$ ]]; then
            info "已跳过 Docker 安装。"
            return
        fi
    fi

    if [ "$NETWORK" = "CN" ]; then
        info "正在执行国内镜像源安装命令..."
        sudo curl -fsSL https://get.docker.com | bash -s docker --mirror Aliyun
    else
        info "正在执行官方默认源安装命令..."
        sudo curl -fsSL https://get.docker.com | bash -s docker
    fi

    # 启动并开机自启
    info "正在启动 Docker 并设置为开机自启..."
    sudo systemctl enable docker
    sudo systemctl start docker

    if command -v docker &> /dev/null; then
        success "Docker 安装成功！当前版本: $(docker --version)"
    else
        error "Docker 安装失败，请检查网络连接或系统日志。"
    fi
}

# 5. 配置非管理员运行 Docker
config_non_root() {
    if [ "$REAL_USER" = "root" ]; then
        warn "当前是 root 用户，跳过非管理员权限配置。"
        return
    fi

    info "正在将用户 [${REAL_USER}] 加入 docker 组..."
    sudo usermod -aG docker "$REAL_USER"
    success "非管理员配置成功！用户 [${REAL_USER}] 已加入 docker 用户组。"
    warn "注意：此配置通常在重新登录终端或运行 'newgrp docker' 后生效！"
}

# 6. 配置镜像加速源
config_mirror() {
    if [ "$NETWORK" != "CN" ]; then
        read -p "当前选择的是境外环境，是否仍要强制配置国内镜像源? [y/N]: " force_mirror
        if [[ ! "$force_mirror" =~ ^[Yy]$ ]]; then
            info "已跳过镜像源配置。"
            return
        fi
    fi

    info "正在配置国内 Docker 镜像加速源 (https://docker.1ms.run)..."
    sudo mkdir -p /etc/docker
    if [ -f /etc/docker/daemon.json ]; then
        sudo cp /etc/docker/daemon.json /etc/docker/daemon.json.bak
        info "已将原有的配置文件备份至 /etc/docker/daemon.json.bak"
    fi

    sudo tee /etc/docker/daemon.json <<-'EOF'
{
  "registry-mirrors": [
    "https://docker.1ms.run"
  ]
}
EOF

    info "重新加载 daemon 并重启 Docker 使配置生效..."
    sudo systemctl daemon-reload
    sudo systemctl restart docker
    success "Docker 镜像源配置成功并已重启！"
}

# 7. 安装 Docker Compose
install_compose() {
    info "开始安装/更新 Docker Compose..."
    if docker compose version &> /dev/null || command -v docker-compose &> /dev/null; then
        warn "检测到系统中已存在 Docker Compose:"
        docker compose version 2>/dev/null || docker-compose --version
        read -p "是否强制重新下载/升级 Docker Compose? [y/N]: " re_install_compose
        if [[ ! "$re_install_compose" =~ ^[Yy]$ ]]; then
            info "已跳过 Docker Compose 安装。"
            return
        fi
    fi

    local dest="/usr/local/bin/docker-compose"
    if [ "$NETWORK" = "CN" ]; then
        info "正在通过国内 gh-proxy 代理下载最新版 Docker Compose..."
        sudo wget "https://gh-proxy.org/https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -O "$dest"
    else
        info "正在从 GitHub 官方源下载最新版 Docker Compose..."
        sudo wget "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -O "$dest"
    fi

    if [ $? -eq 0 ]; then
        sudo chmod +x "$dest"
        # 兼容 docker compose 命令调用旧版二进制的情况
        if docker compose version &> /dev/null; then
            success "Docker Compose 安装成功！当前版本: $(docker compose version)"
        elif command -v docker-compose &> /dev/null; then
            success "Docker Compose 安装成功！当前版本: $(docker-compose version)"
        else
            warn "Docker Compose 下载完成，但系统环境可能需要您重新登录终端后才能调用。"
        fi
    else
        error "Docker Compose 下载失败，请检查网络或代理是否可用。"
    fi
}

# 8. 汇总信息
show_summary() {
    echo -e "\n${GREEN}====================================================${PLAIN}"
    echo -e "               🎉 所有配置与安装执行完毕！"
    echo -e "${GREEN}====================================================${PLAIN}"
    
    if command -v docker &> /dev/null; then
        echo -e " Docker 状态:    ${GREEN}已成功安装 (${PLAIN}$(docker --version)${GREEN})${PLAIN}"
    else
        echo -e " Docker 状态:    ${RED}未安装/未检测到${PLAIN}"
    fi

    if docker compose version &> /dev/null; then
        echo -e " Compose 状态:   ${GREEN}已成功安装 (${PLAIN}$(docker compose version)${GREEN})${PLAIN}"
    elif command -v docker-compose &> /dev/null; then
        echo -e " Compose 状态:   ${GREEN}已成功安装 (${PLAIN}$(docker-compose version)${GREEN})${PLAIN}"
    else
        echo -e " Compose 状态:   ${RED}未安装/未检测到${PLAIN}"
    fi

    if [ "$REAL_USER" != "root" ]; then
        echo -e "\n${YELLOW}💡 温馨提示: 非管理员用户 [${REAL_USER}] 已加入 docker 组。"
        echo -e "   请在当前终端下运行以下命令激活权限，或重新连接 SSH 终端："
        echo -e "   ${GREEN}newgrp docker${PLAIN}"
    fi
    echo -e "${GREEN}====================================================${PLAIN}\n"
}

# 一键极速安装流程
quick_install() {
    select_network
    check_dependencies
    install_docker
    config_mirror
    config_non_root
    install_compose
    show_summary
}

# 自定义分布安装流程
custom_install() {
    select_network
    check_dependencies

    # 选择是否安装 Docker
    read -p "1. 是否安装 Docker? [Y/n]: " run_docker
    run_docker=${run_docker:-Y}
    if [[ "$run_docker" =~ ^[Yy]$ ]]; then
        install_docker
        
        # 选择是否配置镜像加速源
        read -p "1.1 是否配置 Docker 国内加速镜像源? [Y/n]: " run_mirror
        run_mirror=${run_mirror:-Y}
        if [[ "$run_mirror" =~ ^[Yy]$ ]]; then
            config_mirror
        fi

        # 选择是否配置非管理员运行
        read -p "1.2 是否配置非 root 用户运行 Docker? [Y/n]: " run_non_root
        run_non_root=${run_non_root:-Y}
        if [[ "$run_non_root" =~ ^[Yy]$ ]]; then
            config_non_root
        fi
    fi

    # 选择是否安装 Docker Compose
    read -p "2. 是否安装 Docker Compose? [Y/n]: " run_compose
    run_compose=${run_compose:-Y}
    if [[ "$run_compose" =~ ^[Yy]$ ]]; then
        install_compose
    fi

    show_summary
}

# 主控制菜单
main() {
    clear
    echo -e "${BLUE}====================================================${PLAIN}"
    echo -e "      Docker & Docker Compose 主流 Linux 交互安装脚本"
    echo -e "      支持系统: Ubuntu, Debian, CentOS, Rocky, Alma 等"
    echo -e "${BLUE}====================================================${PLAIN}"
    echo -e "  1. ⚡ 一键极速安装 (自动包含 Docker + 镜像源 + 非Root + Compose)"
    echo -e "  2. ⚙️  自定义分步安装 (手动勾选/确认每一项配置)"
    echo -e "  3. 🐳 仅安装/更新 Docker"
    echo -e "  4. 🐙 仅安装/更新 Docker Compose"
    echo -e "  5. 🔄 仅配置/更新 Docker 国内镜像加速源"
    echo -e "  6. 👤 仅配置非 root 用户运行权限"
    echo -e "  7. ❌ 退出脚本"
    echo -e "${BLUE}====================================================${PLAIN}"
    read -p "请选择操作 [1-7]: " main_choice

    case $main_choice in
        1) quick_install ;;
        2) custom_install ;;
        3) select_network; check_dependencies; install_docker; show_summary ;;
        4) select_network; check_dependencies; install_compose; show_summary ;;
        5) select_network; config_mirror; show_summary ;;
        6) config_non_root; show_summary ;;
        *) info "退出脚本，未执行任何修改。"; exit 0 ;;
    esac
}

main
