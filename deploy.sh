#!/bin/bash

set -e

REPO_SLUG="guxi666/x-ui"
RAW_BASE_URL="https://raw.githubusercontent.com/${REPO_SLUG}/main"
ARCHIVE_URL="https://github.com/${REPO_SLUG}/archive/refs/heads/main.tar.gz"
INSTALL_DIR="/usr/local/x-ui"
SERVICE_FILE="/etc/systemd/system/x-ui.service"
BIN_LINK="/usr/bin/x-ui"
TMP_ROOT=""

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

cleanup() {
    if [[ -n "${TMP_ROOT}" && -d "${TMP_ROOT}" ]]; then
        rm -rf "${TMP_ROOT}"
    fi
}

trap cleanup EXIT

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
            goarch="amd64"
            ;;
        aarch64|arm64)
            arch="arm64"
            goarch="arm64"
            ;;
        s390x)
            arch="s390x"
            goarch="s390x"
            ;;
        *)
            log_error "暂不支持的系统架构: ${raw_arch}"
            exit 1
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
        yum install -y curl wget tar git golang gcc gcc-c++ make
    else
        apt-get update -y
        apt-get install -y curl wget tar git golang-go gcc g++ make
    fi
}

get_target_version() {
    if [[ -n "$1" ]]; then
        target_version="$1"
        return
    fi

    target_version="$(curl -fsSL "${RAW_BASE_URL}/LATEST_VERSION" | tr -d '\r')"
    if [[ -z "${target_version}" ]]; then
        log_error "读取最新版本失败"
        exit 1
    fi
}

prepare_workspace() {
    TMP_ROOT="$(mktemp -d -t xui-deploy-XXXXXX)"
    src_archive="${TMP_ROOT}/source.tar.gz"
    runtime_archive="${TMP_ROOT}/runtime.tar.gz"

    log_info "下载仓库源码"
    curl -fsSL "${ARCHIVE_URL}" -o "${src_archive}"
    tar zxf "${src_archive}" -C "${TMP_ROOT}"
    src_dir="${TMP_ROOT}/x-ui-main"

    if [[ ! -d "${src_dir}" ]]; then
        log_error "源码目录不存在，下载内容异常"
        exit 1
    fi

    runtime_url="https://raw.githubusercontent.com/${REPO_SLUG}/main/release-assets/${target_version}/x-ui-linux-${arch}.tar.gz"
    log_info "下载运行时文件"
    curl -fsSL "${runtime_url}" -o "${runtime_archive}"
    tar zxf "${runtime_archive}" -C "${TMP_ROOT}"
    runtime_dir="${TMP_ROOT}/x-ui"

    if [[ ! -d "${runtime_dir}" ]]; then
        log_error "运行时目录不存在，发布包内容异常"
        exit 1
    fi
}

build_panel() {
    log_info "编译面板主程序"
    cd "${src_dir}"
    export GO111MODULE=on
    export GOOS=linux
    export GOARCH="${goarch}"
    export CGO_ENABLED=1
    go build -o x-ui main.go
}

install_files() {
    log_info "停止旧服务"
    systemctl stop x-ui >/dev/null 2>&1 || true

    rm -rf "${INSTALL_DIR}"
    mkdir -p "${INSTALL_DIR}/bin"

    cp "${src_dir}/x-ui" "${INSTALL_DIR}/x-ui"
    cp "${src_dir}/x-ui.sh" "${INSTALL_DIR}/x-ui.sh"
    cp "${src_dir}/x-ui.service" "${INSTALL_DIR}/x-ui.service"
    cp "${runtime_dir}/bin/xray-linux-${arch}" "${INSTALL_DIR}/bin/xray-linux-${arch}"
    cp "${runtime_dir}/bin/geosite.dat" "${INSTALL_DIR}/bin/geosite.dat"
    cp "${runtime_dir}/bin/geoip.dat" "${INSTALL_DIR}/bin/geoip.dat"

    chmod +x "${INSTALL_DIR}/x-ui"
    chmod +x "${INSTALL_DIR}/x-ui.sh"
    chmod +x "${INSTALL_DIR}/bin/xray-linux-${arch}"

    cp -f "${INSTALL_DIR}/x-ui.service" "${SERVICE_FILE}"
    cp -f "${INSTALL_DIR}/x-ui.sh" "${BIN_LINK}"
    chmod +x "${BIN_LINK}"
}

configure_after_install() {
    echo
    read -r -p "是否现在配置面板账号、密码和端口？[y/N]: " answer
    if [[ ! "${answer}" =~ ^[Yy]$ ]]; then
        log_warn "跳过初始化配置，请尽快手动修改默认信息"
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
    echo "x-ui              打开管理菜单"
    echo "x-ui status       查看面板状态"
    echo "x-ui restart      重启面板"
    echo "x-ui update       更新面板"
}

main() {
    require_root
    detect_release
    detect_arch
    check_bits
    install_base
    get_target_version "$1"
    prepare_workspace
    build_panel
    install_files
    configure_after_install
    start_service
    print_summary
}

main "$@"
