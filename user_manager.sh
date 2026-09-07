#!/bin/bash

# ============================================
#  Ubuntu 用户管理脚本
#  功能：创建用户（含sudo） / 删除用户 / 查看用户列表
# ============================================

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# 检查 root 权限
check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}[错误] 请使用 root 权限运行此脚本！${NC}"
        echo "正确用法: sudo bash $0"
        exit 1
    fi
}

# 显示菜单
show_menu() {
    clear
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}       Ubuntu 用户管理工具${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo
    echo -e "  ${CYAN}1.${NC} 创建用户并赋予 sudo 权限"
    echo -e "  ${CYAN}2.${NC} 删除用户"
    echo -e "  ${CYAN}3.${NC} 查看当前系统用户"
    echo -e "  ${CYAN}4.${NC} 退出"
    echo
    echo -ne "${YELLOW}请选择操作 [1-4]: ${NC}"
}

# 创建用户函数
create_user() {
    echo
    echo -e "${GREEN}------ 创建用户 ------${NC}"
    echo

    while true; do
        echo -ne "${BLUE}请输入要创建的用户名: ${NC}"
        read USERNAME
        USERNAME=$(echo "$USERNAME" | xargs)

        if [ -z "$USERNAME" ]; then
            echo -e "${RED}[错误] 用户名不能为空。${NC}"
            continue
        fi

        if ! [[ "$USERNAME" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
            echo -e "${RED}[错误] 用户名不合法！只能包含小写字母、数字、下划线、连字符，并以字母或下划线开头。${NC}"
            continue
        fi

        if id "$USERNAME" &>/dev/null; then
            echo -e "${YELLOW}[提示] 用户 ${USERNAME} 已经存在。${NC}"
            if groups "$USERNAME" | grep -q '\bsudo\b'; then
                echo -e "${GREEN}该用户已拥有 sudo 权限。${NC}"
            else
                echo -ne "${YELLOW}是否为该用户添加 sudo 权限？(y/n): ${NC}"
                read choice
                if [[ "$choice" =~ ^[Yy]$ ]]; then
                    usermod -aG sudo "$USERNAME"
                    echo -e "${GREEN}[成功] 已添加 sudo 权限。${NC}"
                fi
            fi
            read -p "按 Enter 返回菜单..."
            return
        fi
        break
    done

    echo
    echo -e "${YELLOW}即将创建用户: ${GREEN}${USERNAME}${NC}"
    echo -ne "${YELLOW}确认创建吗？(y/n): ${NC}"
    read confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}已取消创建。${NC}"
        read -p "按 Enter 返回菜单..."
        return
    fi

    echo
    echo -e "${YELLOW}接下来进入交互式创建流程，请设置密码等信息（全名等可直接回车跳过）${NC}"
    echo
    adduser "$USERNAME"

    usermod -aG sudo "$USERNAME"

    echo
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}  用户创建成功！${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo -e "用户名 : ${GREEN}${USERNAME}${NC}"
    echo -e "所属组 : $(groups ${USERNAME})"
    echo
    echo -e "${YELLOW}测试命令：${NC}"
    echo "  su - ${USERNAME}"
    echo "  sudo whoami"
    echo
    read -p "按 Enter 返回菜单..."
}

# 删除用户函数
delete_user() {
    echo
    echo -e "${GREEN}------ 删除用户 ------${NC}"
    echo

    while true; do
        echo -ne "${BLUE}请输入要删除的用户名: ${NC}"
        read USERNAME
        USERNAME=$(echo "$USERNAME" | xargs)

        if [ -z "$USERNAME" ]; then
            echo -e "${RED}[错误] 用户名不能为空。${NC}"
            continue
        fi

        if [ "$USERNAME" = "root" ]; then
            echo -e "${RED}[错误] 禁止删除 root 用户！${NC}"
            continue
        fi

        if ! id "$USERNAME" &>/dev/null; then
            echo -e "${RED}[错误] 用户 ${USERNAME} 不存在。${NC}"
            continue
        fi
        break
    done

    echo
    echo -e "${YELLOW}即将删除用户: ${RED}${USERNAME}${NC}"
    echo -e "所属组: $(groups ${USERNAME})"
    echo
    echo -ne "${YELLOW}是否同时删除该用户的家目录和邮件池？(y/n): ${NC}"
    read remove_home

    echo
    echo -e "${RED}警告：此操作不可恢复！${NC}"
    echo -ne "${YELLOW}确认删除用户 ${USERNAME} 吗？(y/n): ${NC}"
    read confirm

    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}已取消删除。${NC}"
        read -p "按 Enter 返回菜单..."
        return
    fi

    if [[ "$remove_home" =~ ^[Yy]$ ]]; then
        deluser --remove-home "$USERNAME"
        echo -e "${GREEN}[成功] 用户 ${USERNAME} 及其家目录已删除。${NC}"
    else
        deluser "$USERNAME"
        echo -e "${GREEN}[成功] 用户 ${USERNAME} 已删除（家目录保留）。${NC}"
    fi

    echo
    read -p "按 Enter 返回菜单..."
}

# 查看用户列表函数
list_users() {
    echo
    echo -e "${GREEN}------ 当前系统用户列表 ------${NC}"
    echo

    echo -e "${CYAN}【普通用户】(UID ≥ 1000)${NC}"
    echo "---------------------------------------------------------------"
    printf "%-16s %-8s %-8s %-20s %-s\n" "用户名" "UID" "GID" "家目录" "Shell"
    echo "---------------------------------------------------------------"

    # 获取普通用户（UID >= 1000 且不是 nobody）
    awk -F: '$3 >= 1000 && $1 != "nobody" {
        printf "%-16s %-8s %-8s %-20s %-s\n", $1, $3, $4, $6, $7
    }' /etc/passwd

    echo
    echo -e "${CYAN}【系统用户】(UID < 1000，仅显示前20个)${NC}"
    echo "---------------------------------------------------------------"
    printf "%-16s %-8s %-8s %-20s %-s\n" "用户名" "UID" "GID" "家目录" "Shell"
    echo "---------------------------------------------------------------"

    awk -F: '$3 < 1000 {
        printf "%-16s %-8s %-8s %-20s %-s\n", $1, $3, $4, $6, $7
    }' /etc/passwd | head -n 20

    echo
    echo -e "${YELLOW}提示：系统用户通常不需要手动管理。${NC}"
    echo
    echo -e "${CYAN}当前拥有 sudo 权限的用户：${NC}"
    getent group sudo | cut -d: -f4 | tr ',' '\n' | sed 's/^/  - /'
    echo
    read -p "按 Enter 返回菜单..."
}

# 主程序
check_root

while true; do
    show_menu
    read choice

    case $choice in
        1)
            create_user
            ;;
        2)
            delete_user
            ;;
        3)
            list_users
            ;;
        4)
            echo
            echo -e "${GREEN}已退出脚本。${NC}"
            echo
            exit 0
            ;;
        *)
            echo -e "${RED}无效选项，请重新选择。${NC}"
            sleep 1
            ;;
    esac
done
