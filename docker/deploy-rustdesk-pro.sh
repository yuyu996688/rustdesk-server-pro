#!/usr/bin/env bash
# RustDesk Server Pro Docker 交互式部署脚本
# 参考: https://rustdesk.com/docs/en/self-host/rustdesk-server-pro/
# 部署方式: Docker (Pro 版) | 操作: 安装 / 卸载 / 启动 / 停止 / 重启 / 更新

set -e

# 默认安装目录
DEFAULT_INSTALL_DIR="/rustdesk"
COMPOSE_FILE="compose.yml"
# 数据卷：不使用 host 网络时使用固定路径
DATA_VOLUME="/conf/rustdesk"
IMAGE_NAME="rustdesk/rustdesk-server-pro:latest"
CONTAINER_HBBS="hbbs"
CONTAINER_HBBR="hbbr"

# 颜色输出
red() { echo -e "\033[31m$*\033[0m"; }
green() { echo -e "\033[32m$*\033[0m"; }
yellow() { echo -e "\033[33m$*\033[0m"; }
blue() { echo -e "\033[34m$*\033[0m"; }

# 检查 Docker 是否可用
check_docker() {
    if ! command -v docker &>/dev/null; then
        red "未检测到 Docker，请先安装: bash <(wget -qO- https://get.docker.com)"
        exit 1
    fi
    if ! docker info &>/dev/null; then
        red "Docker 未运行或无权限，请使用 sudo 或加入 docker 组"
        exit 1
    fi
}

# 修改下载的 pro.yml：./data -> /conf/rustdesk/，去掉 network_mode: host，并添加端口映射
patch_compose_yml() {
    local f="$1"
    local tmp
    tmp=$(mktemp)
    # 替换数据卷路径，删除 network_mode 行（可能需 sudo 读）
    if [[ -r "$f" ]]; then
        sed -e "s|\./data|$DATA_VOLUME|g" -e '/network_mode: "host"/d' "$f" > "$tmp"
    else
        sudo sed -e "s|\./data|$DATA_VOLUME|g" -e '/network_mode: "host"/d' "$f" > "$tmp"
    fi
    # 在 hbbs 的 volumes 后插入 ports（不使用 host 时必须映射端口）
    awk '
        /container_name: hbbs/ { hbbs=1; hbbr=0 }
        /container_name: hbbr/ { hbbs=0; hbbr=1 }
        hbbs && /- \/conf\/rustdesk/ && !hbbs_ports {
            print
            print "    ports:"
            print "      - \"21114:21114\""
            print "      - \"21115:21115\""
            print "      - \"21116:21116\""
            print "      - \"21116:21116/udp\""
            print "      - \"21118:21118\""
            hbbs_ports=1
            next
        }
        hbbr && /- \/conf\/rustdesk/ && !hbbr_ports {
            print
            print "    ports:"
            print "      - \"21117:21117\""
            print "      - \"21119:21119\""
            hbbr_ports=1
            next
        }
        { print }
    ' "$tmp" > "${tmp}.2" && mv "${tmp}.2" "$tmp"
    sudo cp "$tmp" "$f"
    rm -f "$tmp"
}

# 交互输入安装目录
input_install_dir() {
    local dir
    read -rp "请输入安装目录 [默认: ${DEFAULT_INSTALL_DIR}]: " dir
    dir="${dir:-$DEFAULT_INSTALL_DIR}"
    echo "$dir"
}

# 安装
do_install() {
    check_docker
    blue "=== RustDesk Server Pro 安装 ==="

    INSTALL_DIR=$(input_install_dir)
    if [[ ! -d "$INSTALL_DIR" ]]; then
        read -rp "目录 $INSTALL_DIR 不存在，是否创建? [Y/n]: " yn
        yn=${yn:-Y}
        if [[ "${yn,,}" != "n" ]]; then
            sudo mkdir -p "$INSTALL_DIR" || { red "创建目录失败"; exit 1; }
        else
            red "已取消"
            exit 0
        fi
    fi

    echo ""
    read -rp "是否从本地 tar 镜像加载? 若选 n 则从网络 pull [y/N]: " use_tar
    use_tar=${use_tar:-N}

    if [[ "${use_tar,,}" == "y" ]]; then
        read -rp "请输入 tar 镜像文件路径 (如: rustdesk-server-pro.tar): " tar_path
        if [[ -z "$tar_path" || ! -f "$tar_path" ]]; then
            red "文件不存在: $tar_path"
            exit 1
        fi
        yellow "正在加载镜像: $tar_path"
        sudo docker load -i "$tar_path"
    else
        yellow "正在拉取镜像: $IMAGE_NAME"
        sudo docker pull "$IMAGE_NAME"
    fi

    yellow "正在下载 compose 配置: rustdesk.com/pro.yml"
    ( cd "$INSTALL_DIR" && sudo wget -q "https://rustdesk.com/pro.yml" -O "$COMPOSE_FILE" ) || {
        red "下载 pro.yml 失败，请检查网络"
        exit 1
    }

    yellow "正在修改 compose：数据目录 $DATA_VOLUME，不使用 host 网络并映射端口..."
    patch_compose_yml "$INSTALL_DIR/$COMPOSE_FILE"

    if [[ ! -d "$DATA_VOLUME" ]]; then
        yellow "创建数据目录: $DATA_VOLUME"
        sudo mkdir -p "$DATA_VOLUME"
    fi

    yellow "正在启动容器..."
    ( cd "$INSTALL_DIR" && sudo docker compose up -d )
    green "安装完成。Web 控制台: http://<服务器IP>:21114 （默认账号 admin/test1234）"
    green "请开放防火墙端口: TCP 21114-21119, UDP 21116"
}

# 卸载
do_uninstall() {
    check_docker
    blue "=== RustDesk Server Pro 卸载 ==="

    INSTALL_DIR=$(input_install_dir)
    if [[ ! -f "$INSTALL_DIR/$COMPOSE_FILE" ]]; then
        red "未在该目录发现 compose 配置: $INSTALL_DIR/$COMPOSE_FILE"
        exit 1
    fi

    yellow "正在停止并删除容器..."
    ( cd "$INSTALL_DIR" && sudo docker compose down )

    read -rp "是否删除数据目录 $INSTALL_DIR? [y/N]: " del_data
    del_data=${del_data:-N}
    if [[ "${del_data,,}" == "y" ]]; then
        sudo rm -rf "$INSTALL_DIR"
        green "已删除 $INSTALL_DIR"
    fi

    read -rp "是否删除本地镜像 $IMAGE_NAME? [y/N]: " del_image
    del_image=${del_image:-N}
    if [[ "${del_image,,}" == "y" ]]; then
        sudo docker rmi "$IMAGE_NAME" 2>/dev/null || true
        green "已删除镜像"
    fi

    green "卸载完成"
}

# 启动
do_start() {
    check_docker
    blue "=== RustDesk Server Pro 启动 ==="

    INSTALL_DIR=$(input_install_dir)
    if [[ ! -f "$INSTALL_DIR/$COMPOSE_FILE" ]]; then
        red "未发现 $INSTALL_DIR/$COMPOSE_FILE，请先执行安装"
        exit 1
    fi
    ( cd "$INSTALL_DIR" && sudo docker compose up -d )
    green "已启动"
}

# 停止
do_stop() {
    check_docker
    blue "=== RustDesk Server Pro 停止 ==="

    INSTALL_DIR=$(input_install_dir)
    if [[ ! -f "$INSTALL_DIR/$COMPOSE_FILE" ]]; then
        red "未发现 $INSTALL_DIR/$COMPOSE_FILE"
        exit 1
    fi
    ( cd "$INSTALL_DIR" && sudo docker compose stop )
    green "已停止"
}

# 重启
do_restart() {
    check_docker
    blue "=== RustDesk Server Pro 重启 ==="

    INSTALL_DIR=$(input_install_dir)
    if [[ ! -f "$INSTALL_DIR/$COMPOSE_FILE" ]]; then
        red "未发现 $INSTALL_DIR/$COMPOSE_FILE，请先执行安装"
        exit 1
    fi
    ( cd "$INSTALL_DIR" && sudo docker compose restart )
    green "已重启"
}

# 更新
do_update() {
    check_docker
    blue "=== RustDesk Server Pro 更新 ==="

    INSTALL_DIR=$(input_install_dir)
    if [[ ! -f "$INSTALL_DIR/$COMPOSE_FILE" ]]; then
        red "未发现 $INSTALL_DIR/$COMPOSE_FILE，请先执行安装"
        exit 1
    fi

    echo ""
    read -rp "是否从本地 tar 镜像加载? 若选 n 则从网络 pull 最新镜像 [y/N]: " use_tar
    use_tar=${use_tar:-N}

    if [[ "${use_tar,,}" == "y" ]]; then
        read -rp "请输入 tar 镜像文件路径 (如: rustdesk-server-pro.tar): " tar_path
        if [[ -z "$tar_path" || ! -f "$tar_path" ]]; then
            red "文件不存在: $tar_path"
            exit 1
        fi
        yellow "正在加载镜像: $tar_path"
        sudo docker load -i "$tar_path"
    else
        yellow "正在拉取最新镜像: $IMAGE_NAME"
        sudo docker pull "$IMAGE_NAME"
    fi

    read -rp "是否重新下载并应用 compose 配置 (pro.yml)? [y/N]: " redownload_compose
    redownload_compose=${redownload_compose:-N}
    if [[ "${redownload_compose,,}" == "y" ]]; then
        yellow "正在下载 compose 配置: rustdesk.com/pro.yml"
        ( cd "$INSTALL_DIR" && sudo wget -q "https://rustdesk.com/pro.yml" -O "$COMPOSE_FILE" ) || {
            red "下载 pro.yml 失败，请检查网络"
            exit 1
        }
        yellow "正在修改 compose：数据目录 $DATA_VOLUME，不使用 host 网络并映射端口..."
        patch_compose_yml "$INSTALL_DIR/$COMPOSE_FILE"
    fi

    yellow "正在使用新镜像重建并启动容器..."
    ( cd "$INSTALL_DIR" && sudo docker compose up -d --force-recreate )
    green "更新完成"
}

# 主菜单
main_menu() {
    echo ""
    blue "RustDesk Server Pro (Docker) 部署脚本"
    echo "  1) 安装"
    echo "  2) 卸载"
    echo "  3) 启动"
    echo "  4) 停止"
    echo "  5) 重启"
    echo "  6) 更新"
    echo "  0) 退出"
    echo ""
    read -rp "请选择 [0-6]: " choice
    case "$choice" in
        1) do_install ;;
        2) do_uninstall ;;
        3) do_start ;;
        4) do_stop ;;
        5) do_restart ;;
        6) do_update ;;
        0) exit 0 ;;
        *) red "无效选项"; main_menu ;;
    esac
}

# 支持直接参数: install | uninstall | start | stop | restart | update
case "${1:-}" in
    install)   do_install ;;
    uninstall) do_uninstall ;;
    start)     do_start ;;
    stop)      do_stop ;;
    restart)   do_restart ;;
    update)    do_update ;;
    *)         main_menu ;;
esac
