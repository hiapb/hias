#!/bin/bash
set -e
if [ "$EUID" -ne 0 ]; then echo "请用 root 运行"; exit 1; fi
SBOX_BIN="/usr/local/bin/sing-box"
CONFIG_DIR="/etc/sing-box"
CONFIG_FILE="${CONFIG_DIR}/config.json"
DB_FILE="${CONFIG_DIR}/ss_s5_list.db"
SERVICE_FILE="/etc/systemd/system/sing-box.service"
SCRIPT_PATH="$(realpath "$0")"
mkdir -p "$CONFIG_DIR"
touch "$DB_FILE"
install_deps(){ apt update -y; apt install -y curl tar; }
install_sing_box(){
if command -v "$SBOX_BIN" >/dev/null 2>&1; then return; fi
ARCH=$(uname -m)
case "$ARCH" in
x86_64) ARCH_TAG="amd64" ;; aarch64|arm64) ARCH_TAG="arm64" ;; *) echo "不支持架构"; exit 1 ;;
esac
VERSION="1.9.0"
URL="https://github.com/SagerNet/sing-box/releases/download/v${VERSION}/sing-box-${VERSION}-linux-${ARCH_TAG}.tar.gz"
cd /tmp
curl -L -o sb.tar.gz "$URL"
tar xzf sb.tar.gz
mv "sing-box-${VERSION}-linux-${ARCH_TAG}/sing-box" "$SBOX_BIN"
chmod +x "$SBOX_BIN"
}
gen_config(){
if [ ! -s "$DB_FILE" ]; then
cat > "$CONFIG_FILE" <<EOF
{"log":{"level":"info","timestamp":true},"inbounds":[],"outbounds":[{"type":"direct","tag":"direct"}]}
EOF
return
fi
{
echo '{"log":{"level":"info","timestamp":true},"inbounds":['
first=1
while IFS='|' read -r ID SS_PORT SS_METHOD SS_PASS S5_SERVER S5_PORT S5_USER S5_PASS; do
[ -z "$ID" ] && continue
if [ $first -eq 0 ]; then echo ','; fi
first=0
echo -n '{"type":"shadowsocks","listen":"::","listen_port":'"${SS_PORT}"',"method":"'"${SS_METHOD}"'","password":"'"${SS_PASS}"'","detour":"s5-'"${ID}"'"}'
done < "$DB_FILE"
echo '],"outbounds":['
first=1
while IFS='|' read -r ID SS_PORT SS_METHOD SS_PASS S5_SERVER S5_PORT S5_USER S5_PASS; do
[ -z "$ID" ] && continue
if [ $first -eq 0 ]; then echo ','; fi
first=0
if [ "$S5_USER" != "-" ]; then
echo -n '{"type":"socks","server":"'"${S5_SERVER}"'","server_port":'"${S5_PORT}"',"username":"'"${S5_USER}"'","password":"'"${S5_PASS}"'","tag":"s5-'"${ID}"'"}'
else
echo -n '{"type":"socks","server":"'"${S5_SERVER}"'","server_port":'"${S5_PORT}"'","tag":"s5-'"${ID}"'"}'
fi
done < "$DB_FILE"
echo ',{"type":"direct","tag":"direct"}]}'
} > "$CONFIG_FILE"
}
create_service(){
cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=sing-box
After=network.target
[Service]
ExecStart=${SBOX_BIN} run -c ${CONFIG_FILE}
Restart=always
RestartSec=3
User=root
LimitNOFILE=100000
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable sing-box
systemctl restart sing-box || true
}
check_ready(){
if [ ! -x "$SBOX_BIN" ]; then echo "未安装，请先选择 1"; return 1; fi
return 0
}
list_entries(){
if [ ! -s "$DB_FILE" ]; then echo "无记录"; return; fi
echo "ID | SS端口 | 加密 | 密码 | S5地址:端口 | S5用户"
while IFS='|' read -r ID SS_PORT SS_METHOD SS_PASS S5_SERVER S5_PORT S5_USER S5_PASS; do
[ -z "$ID" ] && continue
echo "${ID} | ${SS_PORT} | ${SS_METHOD} | ${SS_PASS} | ${S5_SERVER}:${S5_PORT} | ${S5_USER}"
done < "$DB_FILE"
}
add_entry(){
check_ready || return
read -p "SS 端口: " SS_PORT
if grep -q "|${SS_PORT}|" "$DB_FILE"; then echo "端口已存在"; return; fi
read -p "SS 密码: " SS_PASS
read -p "加密方式(默认 chacha20-ietf-poly1305): " SS_METHOD
SS_METHOD=${SS_METHOD:-chacha20-ietf-poly1305}
read -p "S5 地址: " S5_SERVER
read -p "S5 端口: " S5_PORT
read -p "S5 需要认证？(y/n): " A
S5_USER="-"; S5_PASSW="-"
if [[ "$A" == "y" ]]; then
read -p "S5 用户: " S5_USER
read -p "S5 密码: " S5_PASSW
fi
if [ ! -s "$DB_FILE" ]; then NEW_ID=1; else NEW_ID=$(( $(awk -F'|' 'BEGIN{m=0}{if($1>m)m=$1}END{print m}' "$DB_FILE") + 1 )); fi
echo "${NEW_ID}|${SS_PORT}|${SS_METHOD}|${SS_PASS}|${S5_SERVER}|${S5_PORT}|${S5_USER}|${S5_PASSW}" >> "$DB_FILE"
gen_config
create_service
IP=$(hostname -I | awk '{print $1}')
echo "SS 信息：$IP:$SS_PORT 密码:$SS_PASS 加密:$SS_METHOD"
}
delete_entry(){
check_ready || return
list_entries
read -p "删除 ID: " D
[ -z "$D" ] && return
grep -q "^${D}|" "$DB_FILE" || { echo "无此ID"; return; }
grep -v "^${D}|" "$DB_FILE" > "${DB_FILE}.tmp"
mv "${DB_FILE}.tmp" "$DB_FILE"
gen_config
create_service
}
uninstall_all(){
read -p "确认卸载所有并删除脚本自身？(y/n): " C
[[ "$C" != "y" ]] && return
systemctl stop sing-box 2>/dev/null || true
systemctl disable sing-box 2>/dev/null || true
rm -f "$SERVICE_FILE"
systemctl daemon-reload
rm -rf "$CONFIG_DIR"
rm -f "$SBOX_BIN"
rm -f "$SCRIPT_PATH"
echo "已完全卸载，脚本已删除。"
exit 0
}
main_menu(){
while true; do
echo
echo "===== SS -> S5 管理菜单 ====="
echo "1) 安装/初始化"
echo "2) 查看所有映射"
echo "3) 添加 SS -> S5"
echo "4) 删除映射"
echo "5) 查看服务状态"
echo "6) 查看日志"
echo "7) 卸载全部并删除脚本"
echo "0) 退出"
read -p "选择: " CH
case "$CH" in
1) install_deps; install_sing_box; gen_config; create_service;;
2) list_entries;;
3) add_entry;;
4) delete_entry;;
5) systemctl status sing-box --no-pager;;
6) journalctl -u sing-box -f;;
7) uninstall_all;;
0) exit 0;;
*) echo "无效选择";;
esac
done
}
main_menu
