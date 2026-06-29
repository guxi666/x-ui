#!/bin/bash

set -e

REPO_SLUG="guxi666/x-ui"
RAW_BASE_URL="https://raw.githubusercontent.com/${REPO_SLUG}/main"
ASSET_BASE_URL="${RAW_BASE_URL}/release-assets"
INSTALL_DIR="/usr/local/x-ui"
SERVICE_FILE="/etc/systemd/system/x-ui.service"
BIN_LINK="/usr/bin/x-ui"

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

log_info() {
    echo -e "${green}[INFO]${plain} $1"
}

log_warn() {
    echo -e "${yellow}[WARN]${plain} $1"
}

log_error() {
    echo -e "${red}[ERROR]${plain} $1"
}

require_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "请使用 root 用户运行此脚本"
        exit 1
    fi
}

detect_release() {
    if [[ -f /etc/redhat-release ]]; then
        release="centos"
    elif grep -Eqi "debian" /etc/issue 2>/dev/null || grep -Eqi "debian" /proc/version 2>/dev/null; then
        release="debian"
    elif grep -Eqi "ubuntu" /etc/issue 2>/dev/null || grep -Eqi "ubuntu" /proc/version 2>/dev/null; then
        release="ubuntu"
    elif grep -Eqi "centos|red hat|redhat" /etc/issue 2>/dev/null || grep -Eqi "centos|red hat|redhat" /proc/version 2>/dev/null; then
        release="centos"
    else
        log_error "未识别的系统发行版"
        exit 1
    fi
}

detect_arch() {
    local raw_arch
    raw_arch="$(uname -m)"
    case "$raw_arch" in
        x86_64|x64|amd64)
            arch="amd64"
            ;;
        aarch64|arm64)
            arch="arm64"
            ;;
        s390x)
            arch="s390x"
            ;;
        *)
            log_warn "未识别的架构 ${raw_arch}，回退为 amd64"
            arch="amd64"
            ;;
    esac
}

check_bits() {
    if [[ "$(getconf LONG_BIT)" != "64" ]]; then
        log_error "仅支持 64 位 Linux 系统"
        exit 1
    fi
}

install_base() {
    log_info "安装基础依赖"
    if [[ "${release}" == "centos" ]]; then
        yum install -y curl wget tar
    else
        apt-get update -y
        apt-get install -y curl wget tar
    fi
}

get_target_version() {
    if [[ -n "$1" ]]; then
        target_version="$1"
        return
    fi

    target_version="$(curl -fsSL "${RAW_BASE_URL}/LATEST_VERSION" | tr -d '\r')"
    if [[ -z "${target_version}" ]]; then
        log_error "读取最新版本失败: ${RAW_BASE_URL}/LATEST_VERSION"
        exit 1
    fi
}

download_package() {
    package_name="x-ui-linux-${arch}.tar.gz"
    package_url="${ASSET_BASE_URL}/${target_version}/${package_name}"
    package_path="/usr/local/${package_name}"

    log_info "下载 ${package_url}"
    wget -q --show-progress --no-check-certificate -O "${package_path}" "${package_url}"
}

install_files() {
    local package_path="/usr/local/x-ui-linux-${arch}.tar.gz"

    log_info "停止旧服务"
    systemctl stop x-ui >/dev/null 2>&1 || true

    cd /usr/local
    rm -rf "${INSTALL_DIR}"
    tar zxf "${package_path}"
    rm -f "${package_path}"

    cd "${INSTALL_DIR}"
    chmod +x x-ui "bin/xray-linux-${arch}" x-ui.sh
    cp -f x-ui.service "${SERVICE_FILE}"

    log_info "同步管理脚本"
    wget -q --show-progress --no-check-certificate -O "${BIN_LINK}" "${RAW_BASE_URL}/x-ui.sh"
    chmod +x "${BIN_LINK}"
}

configure_after_install() {
    echo
    read -r -p "是否现在配置面板账号、密码和端口？[y/N]: " answer
    if [[ ! "${answer}" =~ ^[Yy]$ ]]; then
        log_warn "跳过初始化配置，默认信息请尽快手动修改"
        return
    fi

    read -r -p "请输入面板用户名: " panel_user
    read -r -p "请输入面板密码: " panel_password
    read -r -p "请输入面板端口: " panel_port

    if [[ -n "${panel_user}" && -n "${panel_password}" ]]; then
        "${INSTALL_DIR}/x-ui" setting -username "${panel_user}" -password "${panel_password}"
    fi

    if [[ -n "${panel_port}" ]]; then
        "${INSTALL_DIR}/x-ui" setting -port "${panel_port}"
    fi
}

start_service() {
    log_info "启动并设置开机自启"
    systemctl daemon-reload
    systemctl enable x-ui >/dev/null 2>&1
    systemctl restart x-ui
}

print_summary() {
    echo
    log_info "部署完成"
    echo "仓库来源: ${REPO_SLUG}"
    echo "部署版本: ${target_version}"
    echo "系统架构: ${arch}"
    echo
    echo "常用命令:"
    echo "  x-ui              打开管理菜单"
    echo "  x-ui status       查看面板状态"
    echo "  x-ui restart      重启面板"
    echo "  x-ui update       更新面板"
    echo
    echo "专属部署命令:"
    echo "  bash <(curl -Ls ${RAW_BASE_URL}/deploy.sh)"
    echo "指定版本部署:"
    echo "  bash <(curl -Ls ${RAW_BASE_URL}/deploy.sh) ${target_version}"
}

main() {
    require_root
    detect_release
    detect_arch
    check_bits
    install_base
    get_target_version "$1"
    download_package
    install_files
    configure_after_install
    start_service
    print_summary
}

main "$@"
