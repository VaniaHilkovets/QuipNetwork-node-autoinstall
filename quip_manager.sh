#!/bin/bash
# Quip Network Node Manager 

INSTALL_DIR="$HOME/quip-node"
REPO_URL="https://gitlab.com/quip.network/nodes.quip.network.git"
CONFIG_FILE="$INSTALL_DIR/data/config.toml"
PROFILE_FILE="$HOME/.quip_profile"
STATS_FILE="$HOME/.quip_stats"
CPU_FILE="$HOME/.quip_cpu_cores"
GPU_UTIL_FILE="$HOME/.quip_gpu_utilization"
GPU_YIELD_FILE="$HOME/.quip_gpu_yielding"

C='\033[0;36m'; B='\033[1;36m'; DIM='\033[2m'; R='\033[0;31m'
Y='\033[1;33m'; G='\033[0;32m'; N='\033[0m'; BOLD='\033[1m'

load_profile() { NODE_PROFILE=$(cat "$PROFILE_FILE" 2>/dev/null || echo "cpu"); }
save_profile() { echo "$1" > "$PROFILE_FILE"; }
load_saved_cpus() { tr -d '[:space:]' < "$CPU_FILE" 2>/dev/null; }
save_cpus() { echo "$1" > "$CPU_FILE"; }
load_saved_gpu_util() { tr -d '[:space:]' < "$GPU_UTIL_FILE" 2>/dev/null; }
save_gpu_util() { echo "$1" > "$GPU_UTIL_FILE"; }
load_saved_gpu_yield() { tr -d '[:space:]' < "$GPU_YIELD_FILE" 2>/dev/null; }
save_gpu_yield() { echo "$1" > "$GPU_YIELD_FILE"; }
load_profile

dc() { docker compose --profile "$NODE_PROFILE" "$@"; }

get_wallet()    { grep '^node_name' "$CONFIG_FILE" 2>/dev/null | grep -oE '0x[0-9a-fA-F]{40}' | head -1; }
get_node_name() { grep '^node_name' "$CONFIG_FILE" 2>/dev/null | cut -d'"' -f2; }
get_secret()    { grep '^secret'    "$CONFIG_FILE" 2>/dev/null | cut -d'"' -f2; }
get_host()      { grep 'public_host' "$CONFIG_FILE" 2>/dev/null | cut -d'"' -f2; }
get_cpus() {
    awk '
        /^\[cpu\]$/ { in_cpu=1; next }
        /^\[/ { in_cpu=0 }
        in_cpu && $0 ~ /^[[:space:]]*num_cpus[[:space:]]*=/ {
            sub(/.*=[[:space:]]*/, "", $0)
            gsub(/[[:space:]]/, "", $0)
            print
            exit
        }
    ' "$CONFIG_FILE" 2>/dev/null
}
get_gpu_value() {
    local key="$1"
    awk -v key="$key" '
        /^\[gpu\]$/ { in_gpu=1; next }
        /^\[/ { in_gpu=0 }
        in_gpu && $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
            sub(/.*=[[:space:]]*/, "", $0)
            gsub(/[[:space:]]/, "", $0)
            print
            exit
        }
    ' "$CONFIG_FILE" 2>/dev/null
}
get_gpu_utilization() { get_gpu_value "utilization"; }
get_gpu_yielding() { get_gpu_value "yielding"; }
get_effective_gpu_utilization() {
    local value
    value=$(get_gpu_utilization)
    if ! echo "$value" | grep -qE '^[0-9]+$' || [ "$value" -lt 1 ] || [ "$value" -gt 100 ]; then
        value=$(load_saved_gpu_util)
    fi
    if ! echo "$value" | grep -qE '^[0-9]+$' || [ "$value" -lt 1 ] || [ "$value" -gt 100 ]; then
        value=100
    fi
    echo "$value"
}
get_effective_gpu_yielding() {
    local value
    value=$(get_gpu_yielding)
    case "$value" in
        true|false)
            ;;
        *)
            value=$(load_saved_gpu_yield)
            ;;
    esac
    case "$value" in
        true|false)
            ;;
        *)
            value=false
            ;;
    esac
    echo "$value"
}

REST_PORT=20050
REST_HOST="127.0.0.1"
REST_BIND_HOST="0.0.0.0"

enable_rest_api() {
    local cfg="$1"
    if grep -q "^rest_host" "$cfg"; then
        sed -i "s|^rest_host = .*|rest_host = \"${REST_BIND_HOST}\"|" "$cfg"
    elif grep -q "^# rest_host" "$cfg"; then
        sed -i "s|^# rest_host = .*|rest_host = \"${REST_BIND_HOST}\"|" "$cfg"
    else
        sed -i "/^\[global\]/a rest_host = \"${REST_BIND_HOST}\"" "$cfg"
    fi
    if grep -q "^rest_port" "$cfg"; then
        sed -i "s|^rest_port = .*|rest_port = -1|" "$cfg"
    elif grep -q "^# rest_port" "$cfg"; then
        sed -i "s|^# rest_port = .*|rest_port = -1|" "$cfg"
    else
        sed -i "/^\[global\]/a rest_port = -1" "$cfg"
    fi
    if grep -q "^rest_insecure_port" "$cfg"; then
        sed -i "s|^rest_insecure_port = .*|rest_insecure_port = ${REST_PORT}|" "$cfg"
    elif grep -q "^# rest_insecure_port" "$cfg"; then
        sed -i "s|^# rest_insecure_port = .*|rest_insecure_port = ${REST_PORT}|" "$cfg"
    else
        sed -i "/^\[global\]/a rest_insecure_port = ${REST_PORT}" "$cfg"
    fi
}

enable_rest_in_compose() {
    local compose="$INSTALL_DIR/docker-compose.yml"
    [ ! -f "$compose" ] && return
    sed -i '/127\.0\.0\.1:20050:20050/d' "$compose"
    sed -i '/20049:20049/a\      - "127.0.0.1:20050:20050"' "$compose"
    echo -e "  ${DIM}rest api port synced in docker-compose${N}"
}

enable_cuda_in_compose() {
    local compose="$INSTALL_DIR/docker-compose.yml"
    [ ! -f "$compose" ] && return
    grep -q '^  cuda:$' "$compose" || return

    sed -i '/^    gpus: all$/d' "$compose"
    sed -i '/^    container_name: quip-cuda$/a\    gpus: all' "$compose"
    echo -e "  ${DIM}cuda service synced with gpus: all${N}"
}

set_num_cpus() {
    local cfg="$1" ncpus="$2" tmp
    if [ -z "$cfg" ] || [ -z "$ncpus" ] || [ ! -f "$cfg" ]; then
        return 1
    fi
    tmp=$(mktemp) || return 1
    awk -v ncpus="$ncpus" '
        BEGIN { in_cpu=0; saw_cpu=0; wrote=0 }
        /^\[cpu\]$/ {
            in_cpu=1
            saw_cpu=1
            print
            next
        }
        in_cpu && /^\[/ {
            if (!wrote) {
                print "num_cpus = " ncpus
                wrote=1
            }
            in_cpu=0
        }
        in_cpu && $0 ~ /^[[:space:]]*#?[[:space:]]*num_cpus[[:space:]]*=/ {
            if (!wrote) {
                print "num_cpus = " ncpus
                wrote=1
            }
            next
        }
        { print }
        END {
            if (in_cpu && !wrote) {
                print "num_cpus = " ncpus
                wrote=1
            }
            if (!saw_cpu) {
                print ""
                print "[cpu]"
                print "num_cpus = " ncpus
            }
        }
    ' "$cfg" > "$tmp" && mv "$tmp" "$cfg"
}

set_gpu_value() {
    local cfg="$1" key="$2" value="$3" tmp
    if [ -z "$cfg" ] || [ -z "$key" ] || [ -z "$value" ] || [ ! -f "$cfg" ]; then
        return 1
    fi
    tmp=$(mktemp) || return 1
    awk -v key="$key" -v value="$value" '
        BEGIN { in_gpu=0; saw_gpu=0; wrote=0 }
        /^\[gpu\]$/ {
            in_gpu=1
            saw_gpu=1
            print
            next
        }
        in_gpu && /^\[/ {
            if (!wrote) {
                print key " = " value
                wrote=1
            }
            in_gpu=0
        }
        in_gpu {
            pattern = "^[[:space:]]*#?[[:space:]]*" key "[[:space:]]*="
            if ($0 ~ pattern) {
                if (!wrote) {
                    print key " = " value
                    wrote=1
                }
                next
            }
        }
        { print }
        END {
            if (in_gpu && !wrote) {
                print key " = " value
                wrote=1
            }
            if (!saw_gpu) {
                print ""
                print "[gpu]"
                print key " = " value
            }
        }
    ' "$cfg" > "$tmp" && mv "$tmp" "$cfg"
}

cpu_count_is_valid() {
    local value="$1" total="$2"
    echo "$value" | grep -qE '^[0-9]+$' && [ "$value" -ge 1 ] && [ "$value" -le "$total" ]
}

sync_cpu_config() {
    [ "$NODE_PROFILE" != "cpu" ] && return 0
    [ ! -f "$CONFIG_FILE" ] && return 0

    local total desired current
    total=$(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo 2>/dev/null || echo 1)
    desired="${1:-$(load_saved_cpus)}"
    current=$(get_cpus)

    if cpu_count_is_valid "$desired" "$total"; then
        [ "$current" = "$desired" ] || set_num_cpus "$CONFIG_FILE" "$desired"
        save_cpus "$desired"
        return 0
    fi

    if cpu_count_is_valid "$current" "$total"; then
        save_cpus "$current"
    fi
}

prompt_cpu_cores() {
    local total="$1"
    local input value
    read -p "  cpu cores [enter = all / ${total}]: " input
    if [ -z "$input" ] || [ "$input" = "all" ]; then
        value="$total"
    elif echo "$input" | grep -qE '^[0-9]+$' && [ "$input" -ge 1 ] && [ "$input" -le "$total" ]; then
        value="$input"
    else
        echo -e "  ${Y}invalid, using all (${total})${N}" >&2
        value="$total"
    fi
    echo "$value"
}

prompt_gpu_settings() {
    local current_util="$1" current_yield="$2" input

    if ! echo "$current_util" | grep -qE '^[0-9]+$' || [ "$current_util" -lt 1 ] || [ "$current_util" -gt 100 ]; then
        current_util=$(load_saved_gpu_util)
    fi
    if ! echo "$current_util" | grep -qE '^[0-9]+$' || [ "$current_util" -lt 1 ] || [ "$current_util" -gt 100 ]; then
        current_util=100
    fi

    case "$current_yield" in
        true|false) ;;
        *)
            current_yield=$(load_saved_gpu_yield)
            ;;
    esac
    case "$current_yield" in
        true|false) ;;
        *)
            current_yield=false
            ;;
    esac

    echo ""
    echo -e "  ${DIM}gpu settings${N}"
    echo -e "  ${DIM}utilization = GPU load ceiling (1-100, 100 = max load)${N}"
    echo -e "  ${DIM}yielding    = give GPU time to other apps when needed${N}"

    while true; do
        read -p "  gpu utilization [${current_util}]: " input
        [ -z "$input" ] && input="$current_util"
        if echo "$input" | grep -qE '^[0-9]+$' && [ "$input" -ge 1 ] && [ "$input" -le 100 ]; then
            SELECTED_GPU_UTILIZATION="$input"
            break
        fi
        echo -e "  ${Y}invalid, enter 1-100${N}"
    done

    while true; do
        if [ "$current_yield" = "true" ]; then
            read -p "  yielding [Y/n]: " input
            case "$input" in
                ""|y|Y|yes|YES)
                    SELECTED_GPU_YIELDING="true"
                    break
                    ;;
                n|N|no|NO)
                    SELECTED_GPU_YIELDING="false"
                    break
                    ;;
            esac
        else
            read -p "  yielding [y/N]: " input
            case "$input" in
                ""|n|N|no|NO)
                    SELECTED_GPU_YIELDING="false"
                    break
                    ;;
                y|Y|yes|YES)
                    SELECTED_GPU_YIELDING="true"
                    break
                    ;;
            esac
        fi
        echo -e "  ${Y}invalid, use y or n${N}"
    done
}

load_stats() {
    STATS_BASELINE=0; STATS_TOTAL=0
    if [ -f "$STATS_FILE" ]; then
        STATS_BASELINE=$(cut -d' ' -f1 "$STATS_FILE" 2>/dev/null || echo 0)
        STATS_TOTAL=$(cut -d' ' -f2 "$STATS_FILE" 2>/dev/null || echo 0)
    fi
}

save_stats() { echo "${1} ${2}" > "$STATS_FILE"; }

get_rest_stats_json() {
    local c="quip-${NODE_PROFILE}"
    local result=""

    docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${c}$" || { echo ""; return; }

    result=$(curl -sf --max-time 2 "http://${REST_HOST}:${REST_PORT}/api/v1/stats" 2>/dev/null)
    if [ -n "$result" ]; then
        echo "$result"
        return
    fi

    docker exec "$c" python3 -c "
import json, sys, urllib.request
try:
    with urllib.request.urlopen('http://127.0.0.1:${REST_PORT}/api/v1/stats', timeout=2) as r:
        data = r.read().decode('utf-8', 'replace')
    json.loads(data)
    print(data)
except Exception:
    sys.exit(1)
" 2>/dev/null
}

get_api_won() {
    local result
    result=$(get_rest_stats_json)
    [ -z "$result" ] && { echo ""; return; }
    echo "$result" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)['data']['mining']
    print('{won}|{session_won}|{att}|{rate:.0f}|{mining}'.format(
        won=d.get('total_blocks_won',0),
        session_won=d.get('total_blocks_won',0),
        att=d.get('total_blocks_attempted',0),
        rate=d.get('win_rate',0)*100,
        mining='1' if d.get('is_mining') else '0'))
except:
    print('')
" 2>/dev/null
}

update_won_counter() {
    load_stats
    local api_result
    api_result=$(get_api_won)
    [ -z "$api_result" ] && echo "" && return
    local current_won
    current_won=$(echo "$api_result" | cut -d'|' -f1)
    if [ "$current_won" -lt "$STATS_BASELINE" ] 2>/dev/null; then
        STATS_TOTAL=$((STATS_TOTAL + current_won))
        STATS_BASELINE=$current_won
    else
        local diff=$((current_won - STATS_BASELINE))
        if [ "$diff" -gt 0 ]; then
            STATS_TOTAL=$((STATS_TOTAL + diff))
            STATS_BASELINE=$current_won
        fi
    fi
    save_stats "$STATS_BASELINE" "$STATS_TOTAL"
    echo "${STATS_TOTAL}|$(echo "$api_result" | cut -d'|' -f2)|$(echo "$api_result" | cut -d'|' -f3)|$(echo "$api_result" | cut -d'|' -f4)|$(echo "$api_result" | cut -d'|' -f5)"
}

node_status() {
    local c="quip-${NODE_PROFILE}"
    if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${c}$"; then
        echo -e "${DIM}offline${N}"; return
    fi
    local result
    result=$(get_rest_stats_json)
    if [ -n "$result" ]; then
        local mining
        mining=$(echo "$result" | python3 -c "
import sys,json
try:
    print('1' if json.load(sys.stdin)['data']['mining']['is_mining'] else '0')
except: print('0')
" 2>/dev/null)
        [ "$mining" = "1" ] && echo -e "${G}⛏  mining${N}" || echo -e "${C}●  online${N}"
    else
        echo -e "${C}●  online${N}"
    fi
}

header() {
    clear
    echo -e "${B}"
    echo "  ┌─────────────────────────────────────────┐"
    echo "  │         QUIP NETWORK NODE MANAGER       │"
    echo "  └─────────────────────────────────────────┘"
    echo -e "${N}"
    local w h cpus
    w=$(get_wallet); h=$(get_host); cpus=$(get_cpus)
    echo -e "  ${DIM}status   ${N}$(node_status)"
    echo -e "  ${DIM}profile  ${N}${C}${NODE_PROFILE^^}${N}"
    [ -n "$h" ]    && echo -e "  ${DIM}host     ${N}${C}${h}:20049${N}"
    [ -n "$w" ]    && echo -e "  ${DIM}wallet   ${N}${C}${w}${N}"
    [ -n "$cpus" ] && echo -e "  ${DIM}cpus     ${N}${C}${cpus}${N}"
    local stats
    stats=$(update_won_counter)
    if [ -n "$stats" ]; then
        local total session_won attempted rate mining
        total=$(echo "$stats"     | cut -d'|' -f1)
        session_won=$(echo "$stats" | cut -d'|' -f2)
        attempted=$(echo "$stats" | cut -d'|' -f3)
        rate=$(echo "$stats"      | cut -d'|' -f4)
        mining=$(echo "$stats"    | cut -d'|' -f5)
        local mine_icon=""
        [ "$mining" = "1" ] && mine_icon="  ${G}⛏${N}"
        echo -e "  ${DIM}blocks   ${N}${G}${BOLD}${total} won${N}${mine_icon}"
        echo -e "  ${DIM}session  ${N}${G}${BOLD}${session_won} won${N} ${DIM}(${attempted} tried / ${rate}%)${N}"
    fi
    echo -e "  ${DIM}─────────────────────────────────────────${N}"
    echo ""
}

install_nvidia_toolkit() {
    echo -e "  ${C}installing nvidia container toolkit...${N}"
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | \
        gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
        sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
        tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
    apt-get update -qq && apt-get install -y -qq nvidia-container-toolkit
    nvidia-ctk runtime configure --runtime=docker
    systemctl restart docker; sleep 3
}

check_gpu() {
    if ! command -v nvidia-smi &>/dev/null; then
        echo -e "  ${R}nvidia driver not found${N}"; return 1
    fi
    if ! docker run --rm --gpus all nvidia/cuda:12.0-base-ubuntu22.04 nvidia-smi &>/dev/null 2>&1; then
        echo -e "  ${Y}nvidia container toolkit missing${N}"
        read -p "  install? [y/N]: " a
        [ "$a" != "y" ] && [ "$a" != "Y" ] && return 1
        install_nvidia_toolkit || return 1
    fi
    return 0
}

do_install() {
    header
    [ "$EUID" -ne 0 ] && { echo -e "  ${R}run as root: sudo bash $0${N}"; read -p "  "; return; }

    echo -e "  ${C}1${N}  cpu"
    echo -e "  ${C}2${N}  cuda"
    read -p "  type [1]: " p
    case "$p" in 2) NODE_PROFILE="cuda";; *) NODE_PROFILE="cpu";; esac
    save_profile "$NODE_PROFILE"; echo ""

    [ "$NODE_PROFILE" = "cuda" ] && { check_gpu || { read -p "  "; return; }; }

    local wallet=""
    while true; do
        read -p "  wallet (0x...): " wallet
        echo "$wallet" | grep -qE '^0x[0-9a-fA-F]{40}$' && break
        echo -e "  ${Y}invalid${N}"
    done

    read -p "  node name [quip-${wallet:0:8}]: " NODE_NAME
    NODE_NAME="${NODE_NAME:-quip-${wallet}}"
    echo "$NODE_NAME" | grep -qE '0x[0-9a-fA-F]{40}' || NODE_NAME="${NODE_NAME}-${wallet}"

    local NODE_SECRET=""
    [ -f "$CONFIG_FILE" ] && NODE_SECRET=$(grep '^secret' "$CONFIG_FILE" | cut -d'"' -f2)
    [ -z "$NODE_SECRET" ] || [ "$NODE_SECRET" = "CHANGE_ME" ] && \
        NODE_SECRET=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || openssl rand -hex 16)

    local PUBLIC_IP
    PUBLIC_IP=$(curl -fsSL --max-time 5 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')
    read -p "  public ip [$PUBLIC_IP]: " PUBLIC_HOST
    PUBLIC_HOST="${PUBLIC_HOST:-$PUBLIC_IP}"

    local TOTAL_CPUS NUM_CPUS current_gpu_utilization current_gpu_yielding
    local SELECTED_GPU_UTILIZATION="" SELECTED_GPU_YIELDING=""
    TOTAL_CPUS=$(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo 2>/dev/null || echo 1)
    if [ "$NODE_PROFILE" = "cpu" ]; then
        echo ""
        NUM_CPUS=$(prompt_cpu_cores "$TOTAL_CPUS")
        echo -e "  ${DIM}using ${NUM_CPUS} of ${TOTAL_CPUS} cores${N}"
    else
        current_gpu_utilization=$(get_gpu_utilization)
        current_gpu_yielding=$(get_gpu_yielding)
        prompt_gpu_settings "$current_gpu_utilization" "$current_gpu_yielding"
        echo -e "  ${DIM}using gpu utilization ${SELECTED_GPU_UTILIZATION}% / yielding ${SELECTED_GPU_YIELDING}${N}"
    fi
    echo ""

    export DEBIAN_FRONTEND=noninteractive
    apt-get remove -y docker.io docker-compose 2>/dev/null || true
    echo -e "  ${DIM}updating system...${N}"
    apt-get update -qq && apt-get upgrade -y -qq

    echo -e "  ${DIM}firewall...${N}"
    command -v ufw &>/dev/null || apt-get install -y -qq ufw
    ufw allow OpenSSH
    ufw allow 20049/tcp
    ufw allow 20049/udp
    ufw allow 80/tcp
    ufw allow 443/tcp
    ufw deny 20050/tcp
    ufw --force enable

    if ! docker compose version &>/dev/null 2>&1; then
        echo -e "  ${DIM}installing docker...${N}"
        curl -fsSL https://get.docker.com | sh
    fi
    if ! docker compose version &>/dev/null 2>&1; then
        mkdir -p /usr/local/lib/docker/cli-plugins
        curl -fsSL "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-$(uname -m)" \
            -o /usr/local/lib/docker/cli-plugins/docker-compose
        chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
    fi
    systemctl enable docker --now 2>/dev/null || service docker start 2>/dev/null || true
    sleep 2

    echo -e "  ${DIM}cloning repo...${N}"
    if [ -d "$INSTALL_DIR/.git" ]; then
        git -C "$INSTALL_DIR" pull --ff-only 2>/dev/null || true
    else
        rm -rf "$INSTALL_DIR"
        git clone "$REPO_URL" "$INSTALL_DIR" || { echo -e "  ${R}git clone failed${N}"; read -p "  "; return; }
    fi
    cd "$INSTALL_DIR" || { echo -e "  ${R}cannot cd to $INSTALL_DIR${N}"; read -p "  "; return; }
    mkdir -p data

    echo -e "  ${DIM}config...${N}"
    cp "data/config.${NODE_PROFILE}.toml" "$CONFIG_FILE"
    sed -i "s|node_name = .*|node_name = \"${NODE_NAME}\"|" "$CONFIG_FILE"
    sed -i "s|secret = .*|secret = \"${NODE_SECRET}\"|" "$CONFIG_FILE"
    grep -q "^# public_host" "$CONFIG_FILE" && \
        sed -i "s|# public_host = .*|public_host = \"${PUBLIC_HOST}\"|" "$CONFIG_FILE" || \
    grep -q "^public_host" "$CONFIG_FILE" && \
        sed -i "s|public_host = .*|public_host = \"${PUBLIC_HOST}\"|" "$CONFIG_FILE" || \
        sed -i "/^\[global\]/a public_host = \"${PUBLIC_HOST}\"" "$CONFIG_FILE"

    if [ "$NODE_PROFILE" = "cpu" ] && [ -n "$NUM_CPUS" ]; then
        set_num_cpus "$CONFIG_FILE" "$NUM_CPUS"
        save_cpus "$NUM_CPUS"
    fi
    if [ "$NODE_PROFILE" = "cuda" ]; then
        set_gpu_value "$CONFIG_FILE" "utilization" "$SELECTED_GPU_UTILIZATION"
        set_gpu_value "$CONFIG_FILE" "yielding" "$SELECTED_GPU_YIELDING"
        save_gpu_util "$SELECTED_GPU_UTILIZATION"
        save_gpu_yield "$SELECTED_GPU_YIELDING"
    fi

    echo -e "  ${DIM}enabling local rest api...${N}"
    enable_rest_api "$CONFIG_FILE"

    [ ! -f "$INSTALL_DIR/.env" ] && (cp env.example "$INSTALL_DIR/.env" 2>/dev/null || touch "$INSTALL_DIR/.env")

    echo -e "  ${DIM}updating docker-compose...${N}"
    enable_rest_in_compose
    enable_cuda_in_compose

    echo -e "  ${DIM}pulling image...${N}"
    dc pull
    echo -e "  ${DIM}starting...${N}"
    dc down 2>/dev/null || true
    dc up -d --force-recreate

    (crontab -l 2>/dev/null | grep -v "quip-node"; \
     echo "0 * * * * cd $INSTALL_DIR && docker compose --profile $NODE_PROFILE up -d >> /var/log/quip-update.log 2>&1") | crontab -

    echo ""
    echo -e "  ${C}name    ${N}${NODE_NAME}"
    echo -e "  ${C}host    ${N}${PUBLIC_HOST}:20049"
    echo -e "  ${C}secret  ${N}${NODE_SECRET}"
    [ "$NODE_PROFILE" = "cpu" ] && echo -e "  ${C}cpus    ${N}${NUM_CPUS} / ${TOTAL_CPUS}"
    [ "$NODE_PROFILE" = "cuda" ] && echo -e "  ${C}gpu     ${N}util ${SELECTED_GPU_UTILIZATION}% / yielding ${SELECTED_GPU_YIELDING}"
    echo -e "  ${C}rest    ${N}127.0.0.1:${REST_PORT} (local only, http only)"
    echo ""
    read -p "  enter..."
}

do_start() {
    header
    [ ! -d "$INSTALL_DIR" ] && { echo -e "  ${R}not installed${N}"; read -p "  "; return; }
    [ "$NODE_PROFILE" = "cuda" ] && { check_gpu || { read -p "  "; return; }; }
    sync_cpu_config
    cd "$INSTALL_DIR" && dc up -d --force-recreate
    read -p "  enter..."
}

do_stop() {
    header
    [ ! -d "$INSTALL_DIR" ] && { echo -e "  ${R}not installed${N}"; read -p "  "; return; }
    cd "$INSTALL_DIR" && dc down
    read -p "  enter..."
}

do_logs() {
    [ ! -d "$INSTALL_DIR" ] && { header; echo -e "  ${R}not installed${N}"; read -p "  "; return; }
    cd "$INSTALL_DIR"
    local noisy_logs
    noisy_logs='\[(node_client|peer_ban_list|telemetry)\.py:[0-9]+\]'
    clear
    echo -e "  ${C}1${N}  normal logs"
    echo -e "  ${C}2${N}  miner logs ${DIM}(filtered)${N}"
    echo -e "  ${DIM}0  back${N}"
    echo ""
    read -p "  > " log_mode
    case "$log_mode" in
        1)
            clear
            echo -e "${DIM}  ctrl+c to exit${N}"
            echo ""
            dc logs -f --tail=200
            ;;
        2)
            clear
            echo -e "${DIM}  ctrl+c to exit${N}"
            echo -e "${DIM}  hidden noisy logs: node_client.py, peer_ban_list.py, telemetry.py${N}"
            echo ""
            dc logs -f --tail=200 2>&1 | grep --line-buffered -Ev "$noisy_logs"
            ;;
        *)
            return
            ;;
    esac
}

do_mydata() {
    header
    local name secret host ecdsa cpus gpu_util gpu_yield
    name=$(get_node_name)
    secret=$(get_secret)
    host=$(get_host)
    cpus=$(get_cpus)
    gpu_util=$(get_effective_gpu_utilization)
    gpu_yield=$(get_effective_gpu_yielding)

    ecdsa=$(docker exec "quip-${NODE_PROFILE}" python3 -c "
import json
try:
    d=json.load(open('/data/telemetry/nodes.json'))
    n=d.get('nodes',d)
    [print(v.get('ecdsa_public_key_hex','')) for k,v in n.items() if '${name}' in str(v) or '${host}' in k]
except: pass
" 2>/dev/null | grep -v '^None$' | grep -v '^$' | head -1)

    echo -e "  ${DIM}name    ${N}${name}"
    echo -e "  ${DIM}host    ${N}${host}:20049"
    echo -e "  ${DIM}profile ${N}${NODE_PROFILE^^}"
    [ -n "$cpus" ] && echo -e "  ${DIM}cpus    ${N}${cpus}"
    [ "$NODE_PROFILE" = "cuda" ] && echo -e "  ${DIM}gpu     ${N}util ${gpu_util}% / yielding ${gpu_yield}"
    echo ""
    echo -e "  ${DIM}secret${N}"
    echo -e "  ${C}${secret}${N}"

    if [ -n "$ecdsa" ]; then
        echo ""
        echo -e "  ${DIM}ecdsa${N}"
        echo -e "  ${DIM}${ecdsa}${N}"
    fi

    echo ""
    echo -e "  ${DIM}─────────────────────────────────────────${N}"
    echo -e "  ${BOLD}mining stats${N}"
    echo ""

    local stats_json
    stats_json=$(get_rest_stats_json)
    if [ -n "$stats_json" ]; then
        load_stats
        local current_won
        current_won=$(echo "$stats_json" | python3 -c "
import sys,json
try: print(json.load(sys.stdin)['data']['mining']['total_blocks_won'])
except: print(0)
" 2>/dev/null)

        if [ "$current_won" -lt "$STATS_BASELINE" ] 2>/dev/null; then
            STATS_TOTAL=$((STATS_TOTAL + current_won))
            STATS_BASELINE=$current_won
        else
            local diff=$((current_won - STATS_BASELINE))
            [ "$diff" -gt 0 ] && STATS_TOTAL=$((STATS_TOTAL + diff)) && STATS_BASELINE=$current_won
        fi

        save_stats "$STATS_BASELINE" "$STATS_TOTAL"
        echo -e "  ${G}${BOLD}  total won (all time) : ${STATS_TOTAL}${N}"

        echo "$stats_json" | python3 -c "
import sys, json
try:
    d=json.load(sys.stdin)['data']; m=d['mining']; bc=d['blockchain']; net=d['network']
    print('  \\033[2m  session won          \\033[0m{}'.format(m.get('total_blocks_won',0)))
    print('  \\033[2m  attempted            \\033[0m{}'.format(m.get('total_blocks_attempted',0)))
    print('  \\033[2m  win rate             \\033[0m{:.1f}%'.format(m.get('win_rate',0)*100))
    print('  \\033[2m  avg mine time        \\033[0m{:.3f}s'.format(m.get('average_mining_time',0)))
    print('  \\033[2m  chain length         \\033[0m{}'.format(bc['chain_length']))
    print('  \\033[2m  latest block         \\033[0m#{}'.format(bc['latest_block_index']))
    print('  \\033[2m  peers                \\033[0m{}'.format(net['total_peers']))
    print('  \\033[2m  synchronized         \\033[0m{}'.format(net['synchronized']))
    wins=m.get('wins_per_miner',{})
    if wins:
        print('  \\033[2m  worker wins\\033[0m')
        for k,v in wins.items():
            parts = str(k).split('-')
            label = '-'.join(parts[-2:]) if len(parts) >= 2 else str(k)
            print('      \\033[0;36m{}\\033[0m: \\033[1;32m{}\\033[0m'.format(label,v))
except Exception as e: print('  error: {}'.format(e))
" 2>/dev/null
    else
        echo -e "  ${R}rest api unavailable${N}"
        echo -e "  ${DIM}run option 1 install to fix config${N}"
    fi

    echo ""
    read -p "  enter..."
}

do_update() {
    header
    [ ! -d "$INSTALL_DIR" ] && { echo -e "  ${R}not installed${N}"; read -p "  "; return; }
    cd "$INSTALL_DIR"
    git pull --ff-only 2>/dev/null || true
    sync_cpu_config
    dc pull && dc up -d --force-recreate
    read -p "  enter..."
}

do_switch() {
    header
    [ ! -d "$INSTALL_DIR" ] && { echo -e "  ${R}not installed${N}"; read -p "  "; return; }

    local old="$NODE_PROFILE" selected_cpus="" current_gpu_utilization="" current_gpu_yielding=""
    local SELECTED_GPU_UTILIZATION="" SELECTED_GPU_YIELDING=""
    echo -e "  ${C}1${N}  cpu"
    echo -e "  ${C}2${N}  cuda"
    read -p "  [current: ${old^^}]: " p
    case "$p" in
        2) NODE_PROFILE="cuda" ;;
        *) NODE_PROFILE="cpu" ;;
    esac

    [ "$NODE_PROFILE" = "cuda" ] && { check_gpu || { NODE_PROFILE="$old"; save_profile "$old"; read -p "  "; return; }; }

    if [ "$NODE_PROFILE" = "cpu" ]; then
        local total_cpus_for_prompt current_cpus_for_prompt
        total_cpus_for_prompt=$(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo 2>/dev/null || echo 1)
        current_cpus_for_prompt=$(get_cpus)
        echo ""
        echo -e "  ${DIM}current cpu cores: ${current_cpus_for_prompt:-auto}${N}"
        selected_cpus=$(prompt_cpu_cores "$total_cpus_for_prompt")
        echo -e "  ${DIM}using ${selected_cpus} of ${total_cpus_for_prompt} cores${N}"
        echo ""
    else
        current_gpu_utilization=$(get_gpu_utilization)
        current_gpu_yielding=$(get_gpu_yielding)
        [ -n "$current_gpu_utilization" ] && save_gpu_util "$current_gpu_utilization"
        [ -n "$current_gpu_yielding" ] && save_gpu_yield "$current_gpu_yielding"
        prompt_gpu_settings "$current_gpu_utilization" "$current_gpu_yielding"
        echo -e "  ${DIM}using gpu utilization ${SELECTED_GPU_UTILIZATION}% / yielding ${SELECTED_GPU_YIELDING}${N}"
        echo ""
    fi

    save_profile "$NODE_PROFILE"
    cd "$INSTALL_DIR"
    docker compose --profile "$old" down 2>/dev/null || true

    local name secret host saved_cpus preferred_cpus total_cpus
    name=$(grep 'node_name' "$CONFIG_FILE" 2>/dev/null | cut -d'"' -f2)
    secret=$(grep '^secret' "$CONFIG_FILE" 2>/dev/null | cut -d'"' -f2)
    host=$(grep 'public_host' "$CONFIG_FILE" 2>/dev/null | cut -d'"' -f2)
    saved_cpus=$(get_cpus)
    preferred_cpus=$(load_saved_cpus)

    cp "data/config.${NODE_PROFILE}.toml" "$CONFIG_FILE"
    [ -n "$name"   ] && sed -i "s|node_name = .*|node_name = \"${name}\"|" "$CONFIG_FILE"
    [ -n "$secret" ] && sed -i "s|secret = .*|secret = \"${secret}\"|" "$CONFIG_FILE"
    [ -n "$host"   ] && sed -i "s|public_host = .*|public_host = \"${host}\"|" "$CONFIG_FILE"

    if [ "$NODE_PROFILE" = "cpu" ]; then
        total_cpus=$(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo 2>/dev/null || echo 1)
        if cpu_count_is_valid "$selected_cpus" "$total_cpus"; then
            set_num_cpus "$CONFIG_FILE" "$selected_cpus"
            save_cpus "$selected_cpus"
        elif cpu_count_is_valid "$preferred_cpus" "$total_cpus"; then
            set_num_cpus "$CONFIG_FILE" "$preferred_cpus"
            save_cpus "$preferred_cpus"
        elif cpu_count_is_valid "$saved_cpus" "$total_cpus"; then
            set_num_cpus "$CONFIG_FILE" "$saved_cpus"
            save_cpus "$saved_cpus"
        else
            set_num_cpus "$CONFIG_FILE" "$total_cpus"
            save_cpus "$total_cpus"
        fi
    else
        set_gpu_value "$CONFIG_FILE" "utilization" "$SELECTED_GPU_UTILIZATION"
        set_gpu_value "$CONFIG_FILE" "yielding" "$SELECTED_GPU_YIELDING"
        save_gpu_util "$SELECTED_GPU_UTILIZATION"
        save_gpu_yield "$SELECTED_GPU_YIELDING"
    fi

    enable_rest_api "$CONFIG_FILE"
    enable_rest_in_compose
    enable_cuda_in_compose

    (crontab -l 2>/dev/null | grep -v "quip-node"; \
     echo "0 * * * * cd $INSTALL_DIR && docker compose --profile $NODE_PROFILE up -d >> /var/log/quip-update.log 2>&1") | crontab -

    dc pull && dc up -d
    read -p "  enter..."
}

do_remove() {
    header
    read -p "  type 'yes': " c
    [ "$c" != "yes" ] && { read -p "  "; return; }

    [ -d "$INSTALL_DIR" ] && cd "$INSTALL_DIR" && \
        for pr in cpu cuda; do docker compose --profile "$pr" down 2>/dev/null || true; done

    (crontab -l 2>/dev/null | grep -v "quip-node") | crontab - 2>/dev/null || true
    rm -rf "$INSTALL_DIR" "$PROFILE_FILE" "$STATS_FILE" "$CPU_FILE" "$GPU_UTIL_FILE" "$GPU_YIELD_FILE"
    read -p "  enter..."
}

while true; do
    header
    echo -e "  ${C}1${N}  install"
    echo -e "  ${C}2${N}  start"
    echo -e "  ${C}3${N}  stop"
    echo -e "  ${C}4${N}  logs"
    echo -e "  ${C}5${N}  node info"
    echo -e "  ${C}6${N}  update"
    echo -e "  ${C}7${N}  switch profile  ${DIM}(${NODE_PROFILE^^})${N}"
    echo -e "  ${C}8${N}  remove"
    echo -e "  ${DIM}0  exit${N}"
    echo ""
    printf "  ${DIM}+--------------- ${BOLD}${C}TELEGRAM${N}${DIM} ----------------+${N}\n"
    printf "  ${DIM}|${N} ${BOLD}${C}%-8s${N} ${B}%-31s${N}${DIM}|${N}\n" "CHANNEL" "https://t.me/SotochkaZela"
    printf "  ${DIM}|${N} ${BOLD}${C}%-8s${N} ${B}%-31s${N}${DIM}|${N}\n" "CHAT" "https://t.me/sotochkachat"
    printf "  ${DIM}+-----------------------------------------+${N}\n"
    echo ""
    read -p "  > " choice
    case "$choice" in
        1) do_install ;;
        2) do_start ;;
        3) do_stop ;;
        4) do_logs ;;
        5) do_mydata ;;
        6) do_update ;;
        7) do_switch ;;
        8) do_remove ;;
        0) exit 0 ;;
        *) sleep 0.3 ;;
    esac
done
