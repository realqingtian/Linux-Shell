#!/bin/bash

# ==============================================================================
# 脚本名称: change_timezone.sh
# 脚本功能: 生产级 Linux 系统时区交互式修改脚本（自适应主流发行版与容器环境）
# 支持系统: CentOS/RHEL/Rocky/Alma, Ubuntu/Debian, Alpine, Arch Linux 等
# ==============================================================================

# 发生未定义变量或管道错误时立即退出，确保安全
set -o nounset
set -o pipefail

# 捕获 Ctrl+C (SIGINT) 信号，避免脚本中断留下半配置状态
trap 'echo -e "\n\033[31m[错误] 用户强行终止了脚本。正在退出...\033[0m"; exit 1' INT

# 定义颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# 日志输出函数
log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_err()   { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()  { echo -e "${CYAN}[STEP]${NC} $1"; }

# ------------------------------------------------------------------------------
# 意外情况处理 1: 权限校验
# ------------------------------------------------------------------------------
check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_err "该脚本必须以 root 权限运行。请使用 'sudo ./change_timezone.sh' 或切换到 root 用户。"
        exit 1
    fi
}

# ------------------------------------------------------------------------------
# 意外情况处理 2: 检测只读文件系统
# ------------------------------------------------------------------------------
check_fs_writable() {
    if [ ! -w /etc ]; then
        log_err "/etc 目录不可写！系统可能是只读文件系统（Read-only filesystem），请检查系统状态。"
        exit 1
    fi
}

# ------------------------------------------------------------------------------
# 意外情况处理 3: 自动修复 tzdata 依赖缺失（如极简 Docker 镜像）
# ------------------------------------------------------------------------------
ensure_tzdata() {
    local zoneinfo_dir="/usr/share/zoneinfo"
    if [ ! -d "$zoneinfo_dir" ] || [ -z "$(ls -A "$zoneinfo_dir" 2>/dev/null)" ]; then
        log_warn "检测到系统中缺少时区数据库（tzdata 缺失或为空）。"
        log_step "正在尝试通过系统包管理器自动安装 tzdata..."

        # 识别包管理器并进行安装
        if [ -x "$(command -v apt-get)" ]; then
            apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y tzdata
        elif [ -x "$(command -v yum)" ]; then
            yum install -y tzdata
        elif [ -x "$(command -v dnf)" ]; then
            dnf install -y tzdata
        elif [ -x "$(command -v apk)" ]; then
            apk add --no-cache tzdata
        elif [ -x "$(command -v pacman)" ]; then
            pacman -S --noconfirm tzdata
        else
            log_err "未找到支持的包管理器。请手动安装 'tzdata' 包后再运行此脚本。"
            exit 1
        fi

        # 安装后二次校验
        if [ ! -d "$zoneinfo_dir" ] || [ -z "$(ls -A "$zoneinfo_dir" 2>/dev/null)" ]; then
            log_err "tzdata 安装失败，请检查网络连接或源配置！"
            exit 1
        fi
        log_info "tzdata 安装成功，继续执行。"
    fi
}

# ------------------------------------------------------------------------------
# 意外情况处理 4: 备份旧的时区配置（以便出现问题时可以手动回滚）
# ------------------------------------------------------------------------------
backup_current_timezone() {
    local backup_dir="/var/backups/timezone_backup_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$backup_dir" 2>/dev/null || true
    
    log_step "正在备份当前时区配置至: $backup_dir"
    
    if [ -f /etc/localtime ] || [ -L /etc/localtime ]; then
        cp -pd /etc/localtime "$backup_dir/localtime" 2>/dev/null || true
    fi
    if [ -f /etc/timezone ]; then
        cp -p /etc/timezone "$backup_dir/timezone" 2>/dev/null || true
    fi
    log_info "备份完成。"
}

# 获取大洲列表
get_continents() {
    find /usr/share/zoneinfo -maxdepth 1 -mindepth 1 -type d -exec basename {} \; | grep -E -v 'etc|System|right|posix' | sort
}

# ------------------------------------------------------------------------------
# 核心操作: 应用新时区（自适应 systemd 状态与容器环境）
# ------------------------------------------------------------------------------
apply_timezone() {
    local tz="$1"
    local tz_file="/usr/share/zoneinfo/$tz"

    if [ ! -f "$tz_file" ]; then
        log_err "时区文件 '$tz_file' 不存在，无法应用！"
        return 1
    fi

    # 执行备份
    backup_current_timezone

    log_step "正在应用时区: $tz ..."

    # 兼容性处理 A: 如果是标准 systemd 系统，优先使用 timedatectl
    # 特别注意：在 Docker 容器或未启动 systemd 的系统里，timedatectl 会报错，这里做了容错处理
    local systemd_running=false
    if command -v timedatectl >/dev/null 2>&1 && systemctl is-system-running >/dev/null 2>&1; then
        systemd_running=true
    fi

    if [ "$systemd_running" = true ]; then
        if timedatectl set-timezone "$tz"; then
            log_info "成功通过 [timedatectl] 修改时区。"
            verify_timezone "$tz"
            return 0
        else
            log_warn "timedatectl 执行失败，将降级尝试软链接方式。"
        fi
    fi

    # 兼容性处理 B: 传统模式 / 容器环境 (软链接方式)
    log_info "正在使用软链接方式 (/etc/localtime) 修改时区..."
    
    # 安全删除旧文件，防止物理覆盖失败
    rm -f /etc/localtime
    ln -sf "$tz_file" /etc/localtime

    # 兼容性处理 C: Debian/Ubuntu 系列系统还需要写入 /etc/timezone
    if [ -f /etc/timezone ] || [ -x "$(command -v apt-get)" ] || [ -f /etc/alpine-release ]; then
        echo "$tz" > /etc/timezone
    fi

    # 意外情况处理 5: 硬件时钟同步 (在 Docker 等虚拟化容器中可能无法操作，需容错)
    if [ ! -f /.dockerenv ] && command -v hwclock >/dev/null 2>&1; then
        log_step "正在同步系统时间至硬件时钟 (RTC)..."
        if hwclock --systohc; then
            log_info "硬件时钟同步成功。"
        else
            log_warn "硬件时钟同步失败（这在部分虚拟机/容器环境中属于正常现象）。"
        fi
    fi

    verify_timezone "$tz"
}

# 验证最终效果
verify_timezone() {
    local expected="$1"
    log_step "正在验证时区修改结果..."
    echo -e "------------------------------------------------"
    echo -e "当前系统时间 : $(date)"
    if command -v timedatectl >/dev/null 2>&1; then
        timedatectl status | grep -E 'Time zone|Local time' || true
    fi
    echo -e "------------------------------------------------"
    log_info "时区已成功切换至: $expected !"
}

# ------------------------------------------------------------------------------
# 交互菜单 1: 逐级浏览目录选择
# ------------------------------------------------------------------------------
menu_browse_regions() {
    local continents
    continents=($(get_continents))
    
    echo -e "\n${BLUE}=== 选择大洲/区域 ===${NC}"
    # 使用 PS3 自定义 select 提示符
    PS3="请选择对应的大洲编号 (输入数字，或输入 'q' 退出): "
    
    select continent in "${continents[@]}" "返回主菜单"; do
        if [ "$REPLY" = "q" ]; then
            log_info "退出脚本。"
            exit 0
        elif [ "$continent" = "返回主菜单" ]; then
            return 1
        elif [ -n "$continent" ]; then
            menu_select_city "$continent"
            return $?
        else
            log_warn "输入错误，请输入有效的数字编号！"
        fi
    done
}

menu_select_city() {
    local continent="$1"
    local cities
    # 查找选定大洲下的所有城市/时区
    cities=($(find "/usr/share/zoneinfo/$continent" -type f -o -type l | sed "s|/usr/share/zoneinfo/$continent/||" | sort))
    
    echo -e "\n${BLUE}=== 选择 $continent 区域下的城市 ===${NC}"
    PS3="请选择城市编号 (输入数字，输入 'b' 返回上一级): "
    
    select city in "${cities[@]}" "返回上一级"; do
        if [ "$REPLY" = "b" ]; then
            return 1
        elif [ -n "$city" ]; then
            local selected_tz="$continent/$city"
            read -r -p "确定将系统时区修改为 '$selected_tz' 吗? (y/n): " confirm
            if [[ "$confirm" =~ ^[Yy]$ ]]; then
                apply_timezone "$selected_tz"
                return 0
            else
                log_info "已取消。返回城市列表。"
            fi
        else
            log_warn "输入错误，请输入有效的数字编号！"
        fi
    done
}

# ------------------------------------------------------------------------------
# 交互菜单 2: 关键字模糊搜索
# ------------------------------------------------------------------------------
menu_search_timezone() {
    while true; do
        echo -e "\n${BLUE}=== 模糊搜索时区 ===${NC}"
        read -r -p "请输入要搜索的城市或时区关键字 (例如 'Shanghai', 'Tokyo', 'London', 输入 'q' 返回): " keyword
        
        if [[ "$keyword" == "q" ]]; then
            return 1
        fi
        if [ -z "$keyword" ]; then
            log_warn "关键字不能为空！"
            continue
        fi
        
        log_step "正在搜索含有 '$keyword' 的时区..."
        local matches
        matches=($(find /usr/share/zoneinfo -type f -o -type l | sed 's|/usr/share/zoneinfo/||' | grep -i "$keyword" | sort))
        
        if [ ${#matches[@]} -eq 0 ]; then
            log_warn "未找到匹配的时区，请重新输入！"
            continue
        fi
        
        echo -e "\n${GREEN}发现以下匹配的时区:${NC}"
        PS3="请选择要应用的时区编号 (输入数字，或输入 's' 重新搜索): "
        
        select match in "${matches[@]}" "重新搜索" "返回主菜单"; do
            if [ "$REPLY" = "s" ]; then
                break
            elif [ "$match" = "返回主菜单" ]; then
                return 1
            elif [ -n "$match" ]; then
                read -r -p "确定将系统时区修改为 '$match' 吗? (y/n): " confirm
                if [[ "$confirm" =~ ^[Yy]$ ]]; then
                    apply_timezone "$match"
                    return 0
                else
                    log_info "已取消。"
                fi
            else
                log_warn "输入错误，请输入有效的数字编号！"
            fi
        done
        
        # 如果上一步成功应用了时区，则直接返回0退出
        if [ $? -eq 0 ]; then
            return 0
        fi
    done
}

# ------------------------------------------------------------------------------
# 交互菜单 3: 手动输入时区（高级用户）
# ------------------------------------------------------------------------------
menu_manual_input() {
    while true; do
        echo -e "\n${BLUE}=== 手动输入时区 ===${NC}"
        read -r -p "请输入精确的时区路径 (例如 'Asia/Shanghai', 'UTC', 'America/New_York', 输入 'q' 返回): " manual_tz
        
        if [[ "$manual_tz" == "q" ]]; then
            return 1
        fi
        if [ -z "$manual_tz" ]; then
            continue
        fi
        
        if [ -f "/usr/share/zoneinfo/$manual_tz" ]; then
            read -r -p "确定将系统时区修改为 '$manual_tz' 吗? (y/n): " confirm
            if [[ "$confirm" =~ ^[Yy]$ ]]; then
                apply_timezone "$manual_tz"
                return 0
            else
                log_info "操作已取消。"
                return 1
            fi
        else
            log_err "时区路径 '$manual_tz' 无效！请确保其存在于 /usr/share/zoneinfo 下。"
            read -r -p "是否重新输入? (y/n): " retry
            if [[ ! "$retry" =~ ^[Yy]$ ]]; then
                return 1
            fi
        fi
    done
}

# ------------------------------------------------------------------------------
# 主函数入口
# ------------------------------------------------------------------------------
main() {
    check_root
    check_fs_writable
    ensure_tzdata
    
    echo -e "${CYAN}====================================================="
    echo -e "       Linux 交互式时区修改工具 (运维生产版)          "
    echo -e "=====================================================${NC}"
    echo -e "当前系统时间 : $(date)"
    
    while true; do
        echo -e "\n${BLUE}=== 主菜单 ===${NC}"
        echo -e "1) 逐步浏览选择（大洲 -> 城市）"
        echo -e "2) 搜索时区关键字（快速查找）"
        echo -e "3) 手动输入时区路径"
        echo -e "4) 退出"
        read -r -p "请输入选项 [1-4]: " main_opt
        
        case "$main_opt" in
            1)
                if menu_browse_regions; then
                    break
                fi
                ;;
            2)
                if menu_search_timezone; then
                    break
                fi
                ;;
            3)
                if menu_manual_input; then
                    break
                fi
                ;;
            4)
                log_info "未做任何修改，退出脚本。"
                exit 0
                ;;
            *)
                log_warn "无效选项，请输入数字 1-4 之间的数字。"
                ;;
        esac
    done
}

# 执行主函数
main "$@"
