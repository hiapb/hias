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

install_deps(){
  apt update -y
  apt install -y curl tar
}

install_sing_box(){
  if command -v "$SBOX_BIN" >/dev/null 2>&1; then
    return
  fi
  ARCH=$(uname -m)
  case "$ARCH" in
    x86_64) ARCH_TAG="amd64" ;;
    aarch64|arm64) ARCH_TAG="arm64" ;;
    *) echo "不支持架构: $ARCH"; exit 1 ;;
  esac
  VERSION="1.9.0"
  URL="https://github.com/SagerNet/sing-box/releases/download/v${VERSION}/sing-box-${VERSION}-linux-${ARCH_TAG}.tar.gz"
  cd /tmp
  curl -L -o sb.tar.gz "$URL"
  tar xzf sb.tar.gz
  mv "sing-box-${VERSION}-linux-${ARCH_TAG}/sing-box" "$SBOX_BIN"
  chmod +x "$SBOX_BIN"
}

# DB 复用格式解析：
# ID | IN_PORT | PROTOCOL(原SS加密) | PASS | OUT_SERVER | OUT_PORT | OUT_USER | OUT_PASS | OUT_PROTO(可选, http或socks, 默认socks)
# 当 PROTOCOL 为 socks 或 http 时，OUT_USER 作为入站账号，PASS 作为入站密码。
gen_config(){
  local ID IN_PORT PROTOCOL PASS OUT_SERVER OUT_PORT OUT_USER OUT_PASS OUT_PROTO
  local first

  if [ ! -s "$DB_FILE" ]; then
    cat > "$CONFIG_FILE" <<EOF
{"log":{"level":"info","timestamp":true},"inbounds":[],"outbounds":[{"type":"direct","tag":"direct"}],"route":{"final":"direct","rules":[]}}
EOF
    return
  fi

  {
    echo -n '{"log":{"level":"info","timestamp":true},"inbounds":['
    first=1
    while IFS='|' read -r ID IN_PORT PROTOCOL PASS OUT_SERVER OUT_PORT OUT_USER OUT_PASS OUT_PROTO; do
      [ -z "$ID" ] && continue
      if [ $first -eq 0 ]; then echo -n ','; fi
      first=0
      
      # 动态生成不同类型的 Inbound
      if [ "$PROTOCOL" = "socks" ] || [ "$PROTOCOL" = "http" ]; then
        echo -n '{"type":"'"$PROTOCOL"'","tag":"in-'"$ID"'","listen":"::","listen_port":'"$IN_PORT"
        if [ "$OUT_USER" != "-" ]; then
          echo -n ',"users":[{"username":"'"$OUT_USER"'","password":"'"$PASS"'"}]'
        fi
        echo -n '}'
      else
        # 默认 SS 逻辑
        echo -n '{"type":"shadowsocks","tag":"in-'"$ID"'","listen":"::","listen_port":'"$IN_PORT"',"method":"'"$PROTOCOL"'","password":"'"$PASS"'"}'
      fi
    done < "$DB_FILE"

    echo -n '],"outbounds":['
    first=1
    while IFS='|' read -r ID IN_PORT PROTOCOL PASS OUT_SERVER OUT_PORT OUT_USER OUT_PASS OUT_PROTO; do
      [ -z "$ID" ] && continue
      [ "$OUT_SERVER" = "-" ] && continue
      if [ $first -eq 0 ]; then echo -n ','; fi
      first=0
      
      # 识别出站协议，默认为 socks
      local ACTUAL_OUT_PROTO="${OUT_PROTO:-socks}"
      ACTUAL_OUT_PROTO=$(echo "$ACTUAL_OUT_PROTO" | tr -d '\r') # 清理可能的回车符

      if [ "$OUT_USER" != "-" ] && [ "$PROTOCOL" != "socks" ] && [ "$PROTOCOL" != "http" ]; then
        # 只有在非纯入口模式下，才将 OUT_USER 解析为 S5/HTTP 出口的认证信息
        echo -n '{"type":"'"$ACTUAL_OUT_PROTO"'","server":"'"$OUT_SERVER"'","server_port":'"$OUT_PORT"',"username":"'"$OUT_USER"'","password":"'"$OUT_PASS"'","tag":"s5-'"$ID"'"}'
      else
        echo -n '{"type":"'"$ACTUAL_OUT_PROTO"'","server":"'"$OUT_SERVER"'","server_port":'"$OUT_PORT"'","tag":"s5-'"$ID"'"}'
      fi
    done < "$DB_FILE"

    if [ $first -eq 0 ]; then echo -n ','; fi
    echo -n '{"type":"direct","tag":"direct"}],'

    echo -n '"route":{"final":"direct","rules":['
    first=1
    while IFS='|' read -r ID IN_PORT PROTOCOL PASS OUT_SERVER OUT_PORT OUT_USER OUT_PASS OUT_PROTO; do
      [ -z "$ID" ] && continue
      [ "$OUT_SERVER" = "-" ] && continue
      if [ $first -eq 0 ]; then echo -n ','; fi
      first=0
      echo -n '{"inbound":["in-'"$ID"'"],"outbound":"s5-'"$ID"'"}'
    done < "$DB_FILE"
    echo ']}}'
  } > "$CONFIG_FILE"
}

create_service(){
  if [ ! -x "$SBOX_BIN" ]; then
    echo "未安装 sing-box，请先执行安装"
    return
  fi
  if [ ! -f "$SERVICE_FILE" ]; then
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
  else
    systemctl daemon-reload
  fi
  systemctl restart sing-box || true
}

check_ready(){
  if [ ! -x "$SBOX_BIN" ] || [ ! -f "$SERVICE_FILE" ]; then
    echo "未安装或未初始化，请先选择 1"
    return 1
  fi
  return 0
}

list_entries(){
  if [ ! -s "$DB_FILE" ]; then
    echo "当前无映射"
    return
  fi
  echo "ID | 端口 | 入站协议 | 入站认证信息 | 出站模式 | 出站目标"
  echo "------------------------------------------------------------------------"
  while IFS='|' read -r ID IN_PORT PROTOCOL PASS OUT_SERVER OUT_PORT OUT_USER OUT_PASS OUT_PROTO; do
    [ -z "$ID" ] && continue

    # 解析入站
    if [ "$PROTOCOL" = "socks" ] || [ "$PROTOCOL" = "http" ]; then
      IN_PROTO=$(echo "$PROTOCOL" | tr 'a-z' 'A-Z')
      if [ "$OUT_USER" = "-" ]; then
        IN_AUTH="无认证(高危)"
      else
        IN_AUTH="${OUT_USER}"
      fi
    else
      IN_PROTO="SS"
      IN_AUTH="${PROTOCOL}" # SS显示加密方式
    fi

    # 解析出站
    if [ "$OUT_SERVER" = "-" ]; then
      OUT_MODE="直连"
      OUT_DEST="-"
    else
      local OUT_P=$(echo "${OUT_PROTO:-socks}" | tr -d '\r')
      if [ "$OUT_P" = "http" ]; then
        OUT_MODE="走HTTP"
      else
        OUT_MODE="走S5"
      fi
      OUT_DEST="${OUT_SERVER}:${OUT_PORT}"
    fi

    echo "${ID} | ${IN_PORT} | ${IN_PROTO} | ${IN_AUTH} | ${OUT_MODE} | ${OUT_DEST}"
  done < "$DB_FILE"
}

add_ss_only(){
  check_ready || return
  echo ">>> 添加 SS（直连出口）"
  read -p "SS 端口: " SS_PORT
  [ -z "$SS_PORT" ] && { echo "端口不能为空"; return; }
  if grep -q "|${SS_PORT}|" "$DB_FILE"; then echo "该端口已存在"; return; fi
  read -p "SS 密码: " SS_PASS
  [ -z "$SS_PASS" ] && { echo "密码不能为空"; return; }
  read -p "SS 加密方式(默认 aes-256-gcm): " SS_METHOD
  SS_METHOD=${SS_METHOD:-aes-256-gcm}

  NEW_ID=$(get_next_id)
  echo "${NEW_ID}|${SS_PORT}|${SS_METHOD}|${SS_PASS}|-|0|-|-" >> "$DB_FILE"
  
  gen_and_reload "SS" "$SS_PORT" "" "$SS_METHOD" "$SS_PASS"
}

add_ss_to_s5(){
  check_ready || return
  echo ">>> 添加 SS -> S5 级联"
  read -p "SS 端口: " SS_PORT
  [ -z "$SS_PORT" ] && { echo "端口不能为空"; return; }
  if grep -q "|${SS_PORT}|" "$DB_FILE"; then echo "该端口已存在"; return; fi
  read -p "SS 密码: " SS_PASS
  [ -z "$SS_PASS" ] && { echo "密码不能为空"; return; }
  read -p "SS 加密方式(默认 aes-256-gcm): " SS_METHOD
  SS_METHOD=${SS_METHOD:-aes-256-gcm}

  read -p "S5 目标地址(IP): " S5_SERVER
  read -p "S5 目标端口: " S5_PORT
  read -p "S5 目标是否需要认证?(y/n): " A
  S5_USER="-"
  S5_PASSW="-"
  if [ "$A" = "y" ] || [ "$A" = "Y" ]; then
    read -p "S5 用户: " S5_USER
    read -p "S5 密码: " S5_PASSW
  fi

  NEW_ID=$(get_next_id)
  echo "${NEW_ID}|${SS_PORT}|${SS_METHOD}|${SS_PASS}|${S5_SERVER}|${S5_PORT}|${S5_USER}|${S5_PASSW}|socks" >> "$DB_FILE"
  
  gen_and_reload "SS -> S5" "$SS_PORT" "" "$SS_METHOD" "$SS_PASS"
}

add_ss_to_http(){
  check_ready || return
  echo ">>> 添加 SS -> HTTP 级联"
  read -p "SS 端口: " SS_PORT
  [ -z "$SS_PORT" ] && { echo "端口不能为空"; return; }
  if grep -q "|${SS_PORT}|" "$DB_FILE"; then echo "该端口已存在"; return; fi
  read -p "SS 密码: " SS_PASS
  [ -z "$SS_PASS" ] && { echo "密码不能为空"; return; }
  read -p "SS 加密方式(默认 aes-256-gcm): " SS_METHOD
  SS_METHOD=${SS_METHOD:-aes-256-gcm}

  read -p "HTTP 目标地址(IP): " HTTP_SERVER
  read -p "HTTP 目标端口: " HTTP_PORT
  read -p "HTTP 目标是否需要认证?(y/n): " A
  HTTP_USER="-"
  HTTP_PASSW="-"
  if [ "$A" = "y" ] || [ "$A" = "Y" ]; then
    read -p "HTTP 用户: " HTTP_USER
    read -p "HTTP 密码: " HTTP_PASSW
  fi

  NEW_ID=$(get_next_id)
  # 注意：结尾写了 http 作为隐藏协议标识
  echo "${NEW_ID}|${SS_PORT}|${SS_METHOD}|${SS_PASS}|${HTTP_SERVER}|${HTTP_PORT}|${HTTP_USER}|${HTTP_PASSW}|http" >> "$DB_FILE"
  
  gen_and_reload "SS -> HTTP" "$SS_PORT" "" "$SS_METHOD" "$SS_PASS"
}

add_direct_inbound(){
  local PROTO=$1
  check_ready || return
  echo ">>> 添加 ${PROTO^^} 单协议节点（直连出口）"
  
  read -p "${PROTO^^} 监听端口: " IN_PORT
  [ -z "$IN_PORT" ] && { echo "端口不能为空"; return; }
  if grep -q "|${IN_PORT}|" "$DB_FILE"; then echo "该端口已存在"; return; fi

  read -p "是否需要账号密码认证? [强烈建议选y] (y/n): " A
  local USER="-"
  local PASS="-"
  if [ "$A" = "y" ] || [ "$A" = "Y" ]; then
    read -p "认证用户名: " USER
    [ -z "$USER" ] && USER="admin"
    read -p "认证密  码: " PASS
    [ -z "$PASS" ] && PASS="123456"
  else
    echo "注意：您选择了无认证模式，任何知道该 IP:Port 的人均可使用您的流量。"
  fi

  NEW_ID=$(get_next_id)
  # 结构: ID | 端口 | 协议(socks/http) | 入站密码 | 出站地址(-) | 出站端口(0) | 入站用户 | 出站密码(-) | 默认协议
  echo "${NEW_ID}|${IN_PORT}|${PROTO}|${PASS}|-|0|${USER}|-|-" >> "$DB_FILE"
  
  gen_and_reload "${PROTO^^}" "$IN_PORT" "$USER" "" "$PASS"
}

get_next_id(){
  if [ ! -s "$DB_FILE" ]; then
    echo 1
  else
    awk -F'|' 'BEGIN{m=0}{if($1>m)m=$1}END{print m+1}' "$DB_FILE"
  fi
}

gen_and_reload(){
  local TYPE=$1
  local PORT=$2
  local USER=$3
  local METHOD=$4
  local PASS=$5

  gen_config
  create_service

  IP=$(hostname -I | awk '{print $1}')
  echo "====================================="
  echo "✅ 已成功添加 ${TYPE} 节点，客户端配置："
  echo "服务器 IP : ${IP}"
  echo "连接端口  : ${PORT}"
  
  if [ -n "$METHOD" ]; then echo "加密方式  : ${METHOD}"; fi
  if [ "$USER" != "-" ] && [ -n "$USER" ]; then echo "用 户 名  : ${USER}"; fi
  if [ "$PASS" != "-" ] && [ -n "$PASS" ]; then echo "密    码  : ${PASS}"; fi
  if [ "$USER" = "-" ]; then echo "安全警告  : 当前未开启用户认证！"; fi
  echo "====================================="
}

delete_entry(){
  check_ready || return
  if [ ! -s "$DB_FILE" ]; then echo "当前无映射"; return; fi
  list_entries
  read -p "输入要删除的 ID: " D
  [ -z "$D" ] && { echo "已取消"; return; }
  if ! grep -q "^${D}|" "$DB_FILE"; then echo "未找到该 ID"; return; fi
  sed -i "/^${D}|/d" "$DB_FILE"
  gen_config
  create_service
  echo "已删除 ID=${D} 并平滑重载 sing-box"
}

uninstall_all(){
  read -p "确认彻底卸载 sing-box 并删除所有配置?(y/n): " C
  if [ "$C" != "y" ] && [ "$C" != "Y" ]; then echo "已取消"; return; fi
  systemctl stop sing-box 2>/dev/null || true
  systemctl disable sing-box 2>/dev/null || true
  rm -f "$SERVICE_FILE"
  systemctl daemon-reload
  rm -rf "$CONFIG_DIR"
  rm -f "$SBOX_BIN" "$SCRIPT_PATH"
  echo "清理完毕。"
  exit 0
}

init_env(){
  install_deps
  install_sing_box
  gen_config
  create_service
  echo "初始化与内核编译已就绪。"
}

main_menu(){
  while true; do
    echo
    echo "===== 📎 多协议安全网关管理台 ====="
    echo "1) 安装"
    echo "2) 查看所有节点状态"
    echo "-----------------------------------"
    echo "3) 添加 SS"
    echo "4) 添加 SS -> S5"
    echo "5) 添加 SS -> HTTP"
    echo "6) 添加 SOCKS5"
    echo "7) 添加 HTTP"
    echo "-----------------------------------"
    echo "8) 删除特定节点"
    echo "9) 查看底层服务状态"
    echo "10)追踪实时运行日志"
    echo "11)彻底卸载"
    echo "0) 退出"
    read -p "选择: " CH
    case "$CH" in
      1) init_env ;;
      2) list_entries ;;
      3) add_ss_only ;;
      4) add_ss_to_s5 ;;
      5) add_ss_to_http ;;
      6) add_direct_inbound "socks" ;;
      7) add_direct_inbound "http" ;;
      8) delete_entry ;;
      9) check_ready && systemctl status sing-box --no-pager || true ;;
      10) check_ready && journalctl -u sing-box -f || true ;;
      11) uninstall_all ;;
      0) exit 0 ;;
      *) echo "无效指令" ;;
    esac
  done
}

main_menu
