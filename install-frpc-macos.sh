#!/usr/bin/env bash
# install-frpc-macos.sh — 在 macOS 本机装一个用户级 frpc（全程不需要 sudo）
#
# 用在「让自己这台 Mac 上的服务也通过 frps 出公网」的场景：
#   - frpc 二进制装到 ~/.local/share/easyfrp/frpc
#   - 主配置 ~/.local/share/easyfrp/frpc.toml，映射放 ~/.local/share/easyfrp/proxies/*.toml
#   - ~/Library/LaunchAgents/<label>.plist 托管，登录后自动运行、挂掉自动拉起
#   - 不写任何系统目录、不开「远程登录」，卸载就是删掉上面两处
#
# 用法：
#   bash install-frpc-macos.sh --server-addr <公网IP> --token <token>
#
# 可选：
#   --server-port <p>   frps 通信端口，默认 7000
#   --version <v>       frp 版本，默认 0.71.0
#   --dir <path>        安装目录，默认 ~/.local/share/easyfrp
#   --label <l>         launchd 标签，默认 com.easyfrp.frpc
#   --no-gh-proxy       直连 GitHub 下载（默认走 gh-proxy 加速）
#   --uninstall         卸载（逐步 y 确认：停服务、删服务、删目录）

set -eo pipefail

[ -n "$FRP_VERSION" ] || FRP_VERSION=0.71.0
[ -n "$SERVER_PORT" ] || SERVER_PORT=7000
[ -n "$FRPC_DIR" ] || FRPC_DIR="$HOME/.local/share/easyfrp"
[ -n "$LABEL" ] || LABEL=com.easyfrp.frpc
[ -n "$GH_PROXY" ] || GH_PROXY=https://gh-proxy.org/
UNINSTALL=0

while [ $# -gt 0 ]; do
  case "$1" in
    --server-addr) SERVER_ADDR="$2"; shift 2;;
    --token) AUTH_TOKEN="$2"; shift 2;;
    --server-port) SERVER_PORT="$2"; shift 2;;
    --version) FRP_VERSION="$2"; shift 2;;
    --dir) FRPC_DIR="$2"; shift 2;;
    --label) LABEL="$2"; shift 2;;
    --no-gh-proxy) GH_PROXY=""; shift 1;;
    --uninstall) UNINSTALL=1; shift 1;;
    *) echo "未知参数: $1"; exit 1;;
  esac
done

[ "$(uname -s)" = "Darwin" ] || { echo "本脚本只用于 macOS（Linux 请用 install-frpc.sh）"; exit 1; }

case "$(uname -m)" in
  x86_64|amd64) ARCH=amd64;;
  arm64|aarch64) ARCH=arm64;;
  *) echo "不支持的架构: $(uname -m)"; exit 1;;
esac

PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LAUNCH_DOMAIN="gui/$(id -u)"

confirm() {
  local ans=""
  printf "%s [y/N]: " "$1"
  read -r ans < /dev/tty 2>/dev/null || return 1
  [ "$ans" = "y" ] || [ "$ans" = "Y" ]
}

do_uninstall() {
  echo "===== 卸载本机 frpc ====="
  if [ -f "$PLIST" ]; then
    if confirm "停止并删除 frpc 的 LaunchAgent（${LABEL}）？"; then
      launchctl bootout "$LAUNCH_DOMAIN/$LABEL" 2>/dev/null || true
      rm -f "$PLIST"
      echo "  已删除 LaunchAgent"
    else
      echo "  跳过服务删除"
    fi
  else
    echo "  未找到 LaunchAgent"
  fi
  if [ -d "$FRPC_DIR" ]; then
    if confirm "删除目录 ${FRPC_DIR}（含二进制、配置与所有映射）？"; then
      rm -rf "$FRPC_DIR"
      echo "  已删除 $FRPC_DIR"
    else
      echo "  跳过目录删除"
    fi
  else
    echo "  未找到目录 $FRPC_DIR"
  fi
  echo "卸载流程结束"
}

if [ "$UNINSTALL" = "1" ]; then
  do_uninstall
  exit 0
fi

[ -n "$SERVER_ADDR" ] || { echo "错误：缺少 --server-addr"; exit 1; }
[ -n "$AUTH_TOKEN" ] || { echo "错误：缺少 --token"; exit 1; }

echo "==> 安装 frpc v$FRP_VERSION (darwin/$ARCH) 到 $FRPC_DIR"
mkdir -p "$FRPC_DIR/proxies"
TMP="$(mktemp -d)"
URL="$GH_PROXY""https://github.com/fatedier/frp/releases/download/v$FRP_VERSION/frp_""$FRP_VERSION""_darwin_""$ARCH"".tar.gz"
echo "==> 下载 $URL"
curl -fsSL "$URL" -o "$TMP/frp.tar.gz"
tar -xzf "$TMP/frp.tar.gz" -C "$TMP" --strip-components=1
install -m 755 "$TMP/frpc" "$FRPC_DIR/frpc"
rm -rf "$TMP"

cat > "$FRPC_DIR/frpc.toml" <<EOF
# EasyFrp 本机 frpc 主配置（由 install-frpc-macos.sh 生成）
serverAddr = "$SERVER_ADDR"
serverPort = $SERVER_PORT

auth.method = "token"
auth.token = "$AUTH_TOKEN"

includes = ["$FRPC_DIR/proxies/*.toml"]

log.to = "$FRPC_DIR/frpc.log"
log.level = "info"
log.maxDays = 7
EOF

mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$FRPC_DIR/frpc</string>
        <string>-c</string>
        <string>$FRPC_DIR/frpc.toml</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ProcessType</key>
    <string>Background</string>
    <key>StandardOutPath</key>
    <string>$FRPC_DIR/frpc.launchd.log</string>
    <key>StandardErrorPath</key>
    <string>$FRPC_DIR/frpc.launchd.log</string>
</dict>
</plist>
EOF

echo "==> 启动 launchd 服务 $LABEL"
launchctl bootout "$LAUNCH_DOMAIN/$LABEL" 2>/dev/null || true
launchctl bootstrap "$LAUNCH_DOMAIN" "$PLIST"
launchctl kickstart -k "$LAUNCH_DOMAIN/$LABEL" 2>/dev/null || true
sleep 2
echo "--- frpc.log ---"
tail -n 5 "$FRPC_DIR/frpc.log" 2>/dev/null || echo "（日志还没生成，稍后再看）"

HOSTNAME_SHORT="$(hostname -s | tr -cd 'A-Za-z0-9_-')"
echo ""
echo "================ 本机 frpc 安装完成 ================"
echo "系统:        macOS ($ARCH)"
echo "目录:        $FRPC_DIR"
echo "映射目录:    $FRPC_DIR/proxies（一个映射一个 toml）"
echo "launchd:     ${LABEL}（登录后自动运行，挂掉自动拉起）"
echo "日志:        $FRPC_DIR/frpc.log"
echo ""
echo "在本机 EasyFrp 的 config.toml 追加以下配置即可管理本机："
echo ""
echo "[[machines]]"
echo "name = \"$HOSTNAME_SHORT\""
echo "local = true"
echo "proxies_dir = \"$FRPC_DIR/proxies\""
echo "frpc_toml = \"$FRPC_DIR/frpc.toml\""
echo ""
echo "然后： frp -m $HOSTNAME_SHORT"
