#!/bin/bash
# Quip Network Node Manager — v0.2 (substrate validator + RPC-client miner)
#
# Two install modes:
#   1) NODE   — full stack: substrate validator (the node) + miner + dashboard + Caddy + postgres.
#   2) MINER  — miner only (no validator/dashboard). Points at a node's RPC.
#               On install it asks for the node IP; press Enter to use a LOCAL node
#               (if one is running on this box), otherwise it warns.
#
# v0.2 notes:
#   - wallet is AUTO-GENERATED (data/keystore.json), self-funded via the testnet
#     faucet and self-registered in QuantumPow.Miners. We read & show it.
#   - cores via .env QUIP_MINER_CPUSET; GPU SM share via QUIP_GPU_UTILIZATION (+NVIDIA MPS).
#   - single front door on :20049 (Caddy): dashboard `/`, telemetry `/api/v1/*`, RPC `/rpc`.
#   - this script does NOT touch your firewall (ufw).

set -o pipefail

INSTALL_DIR="$HOME/quip-node"
REPO_URL="https://gitlab.com/quip.network/nodes.quip.network.git"
REPO_BRANCH="main"
CONFIG_FILE="$INSTALL_DIR/data/config.toml"
ENV_FILE="$INSTALL_DIR/.env"
KEYSTORE="$INSTALL_DIR/data/keystore.json"
PROFILE_FILE="$HOME/.quip_profile"     # cpu | cuda
MODE_FILE="$HOME/.quip_mode"           # node | miner
API="http://127.0.0.1:20049"

C='\033[0;36m'; B='\033[1;36m'; DIM='\033[2m'; R='\033[0;31m'
Y='\033[1;33m'; G='\033[0;32m'; N='\033[0m'; BOLD='\033[1m'

NODE_PROFILE=$(cat "$PROFILE_FILE" 2>/dev/null || echo cpu)
NODE_MODE=$(cat "$MODE_FILE" 2>/dev/null || echo node)
save_profile() { echo "$1" > "$PROFILE_FILE"; NODE_PROFILE="$1"; }
save_mode()    { echo "$1" > "$MODE_FILE";    NODE_MODE="$1"; }

# --- mode-aware docker compose helpers --------------------------------------
# node  : `docker compose --profile <p> ...`  (validator + dashboard + caddy + miner)
# miner : `docker compose <verb> <p>`         (only the cpu|cuda miner service)
c_up()   { cd "$INSTALL_DIR" || return 1
    if [ "$NODE_MODE" = miner ]; then docker compose up -d "$NODE_PROFILE"
    else docker compose --profile "$NODE_PROFILE" up -d "$@"; fi; }
c_down() { cd "$INSTALL_DIR" || return 1
    if [ "$NODE_MODE" = miner ]; then docker compose rm -sf "$NODE_PROFILE"
    else docker compose --profile "$NODE_PROFILE" down; fi; }
c_pull() { cd "$INSTALL_DIR" || return 1
    if [ "$NODE_MODE" = miner ]; then docker compose pull "$NODE_PROFILE"
    else docker compose --profile "$NODE_PROFILE" pull; fi; }

# ---------- helpers ----------------------------------------------------------

set_env_value() {
    local file="$1" key="$2" value="$3"
    [ -f "$file" ] || return
    if grep -qE "^#?[[:space:]]*${key}=" "$file"; then
        sed -i "s|^#*[[:space:]]*${key}=.*|${key}=${value}|" "$file"
    else
        printf '\n%s=%s\n' "$key" "$value" >> "$file"
    fi
}

get_node_name() { grep -E '^[[:space:]]*node_name' "$CONFIG_FILE" 2>/dev/null | head -1 | cut -d'"' -f2; }
get_validators() { grep -E '^[[:space:]]*QUIP_VALIDATORS=' "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2-; }
local_node_running() { docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^quip-validator$'; }

# Miner ss58 address: keystore.json -> miner logs -> status API.
get_wallet() {
    local a=""
    if [ -f "$KEYSTORE" ]; then
        a=$(python3 - "$KEYSTORE" <<'PY' 2>/dev/null
import json,sys
try: d=json.load(open(sys.argv[1]))
except Exception: sys.exit(0)
def find(o):
    if isinstance(o,dict):
        for k in ("ss58","ss58Address","ss58_address","address","accountId","account_id","account"):
            v=o.get(k)
            if isinstance(v,str) and v: return v
        for v in o.values():
            r=find(v)
            if r: return r
    elif isinstance(o,list):
        for v in o:
            r=find(v)
            if r: return r
    return None
print(find(d) or "")
PY
)
    fi
    if [ -z "$a" ] && [ -d "$INSTALL_DIR" ]; then
        a=$(cd "$INSTALL_DIR" && docker compose logs --tail 800 "$NODE_PROFILE" 2>/dev/null | grep -oE '5[1-9A-HJ-NP-Za-km-z]{46,48}' | head -1)
    fi
    echo "$a"
}

api_json() { curl -sf --max-time 3 "$API/api/v1/$1" 2>/dev/null; }

node_status() {
    docker ps --format '{{.Names}}' 2>/dev/null | grep -qE "^quip-(cpu|cuda)$" || { echo -e "${DIM}offline${N}"; return; }
    if [ -n "$(api_json status)" ]; then echo -e "${G}⛏  running${N}"
    else echo -e "${C}●  online${N}  ${DIM}(syncing / bootstrapping)${N}"; fi
}

header() {
    clear
    echo -e "${B}"
    echo "  ┌─────────────────────────────────────────┐"
    echo "  │        QUIP NETWORK NODE MANAGER  v0.2  │"
    echo "  └─────────────────────────────────────────┘"
    echo -e "${N}"
    echo -e "  ${DIM}status   ${N}$(node_status)"
    echo -e "  ${DIM}mode     ${N}${C}$( [ "$NODE_MODE" = miner ] && echo 'MINER (no local node)' || echo 'NODE (full stack)' )${N}"
    echo -e "  ${DIM}backend  ${N}${C}${NODE_PROFILE^^}${N}"
    local name w
    name=$(get_node_name); [ -n "$name" ] && echo -e "  ${DIM}name     ${N}${C}${name}${N}"
    if [ -d "$INSTALL_DIR" ]; then
        w=$(get_wallet); [ -n "$w" ] && echo -e "  ${DIM}wallet   ${N}${C}${w}${N}"
        if [ "$NODE_MODE" = miner ]; then
            echo -e "  ${DIM}node rpc ${N}${C}$(get_validators)${N}"
        else
            echo -e "  ${DIM}dashboard${N}${C} http://localhost:20049/${N}"
        fi
    fi
    echo -e "  ${DIM}─────────────────────────────────────────${N}"
    echo ""
}

# ---------- gpu --------------------------------------------------------------

install_nvidia_toolkit() {
    echo -e "  ${C}installing nvidia container toolkit...${N}"
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | \
        gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
        sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
        tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null
    apt-get update -qq && apt-get install -y -qq nvidia-container-toolkit
    nvidia-ctk runtime configure --runtime=docker
    systemctl restart docker; sleep 3
}

check_gpu() {
    command -v nvidia-smi &>/dev/null || { echo -e "  ${R}nvidia driver not found${N}"; return 1; }
    if ! docker run --rm --gpus all nvidia/cuda:12.4.1-base-ubuntu22.04 nvidia-smi &>/dev/null; then
        echo -e "  ${Y}nvidia container toolkit missing${N}"
        read -p "  install? [y/N]: " a
        [ "$a" = "y" ] || [ "$a" = "Y" ] || return 1
        install_nvidia_toolkit || return 1
    fi
    return 0
}

start_mps() {
    command -v nvidia-cuda-mps-control &>/dev/null || { echo -e "  ${DIM}MPS utils absent — software fallback${N}"; return; }
    grep -qi microsoft /proc/version 2>/dev/null && { echo -e "  ${DIM}WSL2 — MPS unsupported, software fallback${N}"; return; }
    nvidia-cuda-mps-control -d 2>/dev/null && echo -e "  ${DIM}NVIDIA MPS daemon started${N}"
}

# ---------- install ----------------------------------------------------------

do_install() {
    header
    [ "$EUID" -ne 0 ] && { echo -e "  ${R}run as root: sudo bash $0${N}"; read -p "  "; return; }

    echo -e "  ${BOLD}what to install?${N}"
    echo -e "  ${C}1${N}  node   ${DIM}(full: validator + miner + dashboard)${N}"
    echo -e "  ${C}2${N}  miner  ${DIM}(miner only — connects to a node)${N}"
    read -p "  [1]: " m
    case "$m" in 2) save_mode miner;; *) save_mode node;; esac
    echo ""

    echo -e "  ${C}1${N}  cpu"
    echo -e "  ${C}2${N}  cuda (gpu)"
    read -p "  backend [1]: " p
    case "$p" in 2) save_profile cuda;; *) save_profile cpu;; esac
    echo ""
    [ "$NODE_PROFILE" = "cuda" ] && { check_gpu || { read -p "  "; return; }; }

    read -p "  node name (display) [quip-$(hostname -s 2>/dev/null || echo node)]: " NODE_NAME
    NODE_NAME="${NODE_NAME:-quip-$(hostname -s 2>/dev/null || echo node)}"

    # --- miner mode: where is the node? -------------------------------------
    local VALIDATORS=""
    if [ "$NODE_MODE" = "miner" ]; then
        echo ""
        echo -e "  ${DIM}node RPC: enter your node's IP (or full ws:// URL).${N}"
        echo -e "  ${DIM}Enter = use a LOCAL node on this box (if one is running).${N}"
        read -p "  node ip [local]: " nip
        if [ -z "$nip" ]; then
            if local_node_running; then
                VALIDATORS="ws://quip-validator:9944"
                echo -e "  ${G}using local node${N} ${DIM}(ws://quip-validator:9944)${N}"
            else
                echo -e "  ${R}⚠ no local node found on this box.${N}"
                echo -e "  ${Y}install a node first (option 1) or re-run and enter your node's IP.${N}"
                read -p "  "; return
            fi
        else
            case "$nip" in
                ws://*|wss://*) VALIDATORS="$nip" ;;
                *)              VALIDATORS="ws://${nip}:20049/rpc" ;;
            esac
            echo -e "  ${DIM}node rpc = ${VALIDATORS}${N}"
        fi
    fi

    local TOTAL_CPUS CPUSET="" GPU_UTIL="100"
    TOTAL_CPUS=$(nproc 2>/dev/null || echo 1)
    if [ "$NODE_PROFILE" = "cpu" ]; then
        read -p "  cpu cores for miner [enter = all / ${TOTAL_CPUS}]: " nc
        if echo "$nc" | grep -qE '^[0-9]+$' && [ "$nc" -ge 1 ] && [ "$nc" -le "$TOTAL_CPUS" ]; then
            CPUSET="0-$((nc-1))"
        else CPUSET="0-$((TOTAL_CPUS-1))"; fi
        echo -e "  ${DIM}cpuset = ${CPUSET}${N}"
    else
        read -p "  gpu SM utilization 1-100 [100]: " gu
        echo "$gu" | grep -qE '^[0-9]+$' && [ "$gu" -ge 1 ] && [ "$gu" -le 100 ] && GPU_UTIL="$gu"
        echo -e "  ${DIM}gpu utilization = ${GPU_UTIL}%${N}"
    fi
    echo ""

    export DEBIAN_FRONTEND=noninteractive
    echo -e "  ${DIM}base packages...${N}"
    apt-get update -qq
    apt-get install -y -qq git make curl ca-certificates python3 jq 2>/dev/null

    echo -e "  ${DIM}docker...${N}"
    docker compose version &>/dev/null || curl -fsSL https://get.docker.com | sh
    systemctl enable docker --now 2>/dev/null || service docker start 2>/dev/null || true
    sleep 2

    # firewall: NOT touched by this script.
    if [ "$NODE_MODE" = "node" ]; then
        echo -e "  ${Y}open these ports on your firewall (provider / ufw):${N}"
        echo -e "    ${DIM}20049/tcp${N}      dashboard + /api/v1 + /rpc  ${DIM}(required; miners reach the node here)${N}"
        echo -e "    ${DIM}30333/tcp+udp${N}  libp2p peering              ${DIM}(recommended)${N}"
        echo -e "    ${DIM}80,443/tcp${N}     only if you enable HTTPS/TLS"
    else
        echo -e "  ${DIM}miner mode: outbound only — no inbound ports needed.${N}"
        echo -e "  ${DIM}it must be able to reach your node's :20049 (open that on the NODE).${N}"
    fi

    echo -e "  ${DIM}repo (${REPO_BRANCH})...${N}"
    if [ -d "$INSTALL_DIR/.git" ]; then git -C "$INSTALL_DIR" pull --ff-only 2>/dev/null || true
    else rm -rf "$INSTALL_DIR"
        git clone -b "$REPO_BRANCH" "$REPO_URL" "$INSTALL_DIR" 2>/dev/null || \
        git clone "$REPO_URL" "$INSTALL_DIR" || { echo -e "  ${R}git clone failed${N}"; read -p "  "; return; }
    fi
    cd "$INSTALL_DIR" || { echo -e "  ${R}cannot cd $INSTALL_DIR${N}"; read -p "  "; return; }
    mkdir -p data

    # migrate an old v0.1 config if present
    if [ -f "$CONFIG_FILE" ] && [ ! -f "$KEYSTORE" ] && grep -q '^\[global\]' "$CONFIG_FILE" 2>/dev/null && grep -q 'secret' "$CONFIG_FILE" 2>/dev/null; then
        echo -e "  ${DIM}old config — make updateconfig...${N}"
        chown -R "$(id -u):$(id -g)" data 2>/dev/null || true
        make updateconfig 2>/dev/null || make updateconfig-docker 2>/dev/null || true
    fi

    echo -e "  ${DIM}config...${N}"
    [ -f "$CONFIG_FILE" ] || cp "data/config.${NODE_PROFILE}.toml" "$CONFIG_FILE"
    sed -i "s|^\([[:space:]]*node_name[[:space:]]*=\).*|\1 \"${NODE_NAME}\"|" "$CONFIG_FILE"

    echo -e "  ${DIM}env...${N}"
    [ -f "$ENV_FILE" ] || cp env.example "$ENV_FILE"
    set_env_value "$ENV_FILE" "PUID" "${SUDO_UID:-$(id -u)}"
    set_env_value "$ENV_FILE" "PGID" "${SUDO_GID:-$(id -g)}"
    set_env_value "$ENV_FILE" "QUIP_MINER_TAG" "v0.2"
    set_env_value "$ENV_FILE" "QUIP_VALIDATOR_TAG" "v0.2"
    set_env_value "$ENV_FILE" "QUIP_DASHBOARD_TAG" "v0.2"
    set_env_value "$ENV_FILE" "VALIDATOR_NAME" "$NODE_NAME"
    [ "$NODE_MODE" = "node" ] && set_env_value "$ENV_FILE" "QUIP_HOSTNAME" ":20049"
    if [ -n "$VALIDATORS" ]; then
        set_env_value "$ENV_FILE" "QUIP_VALIDATORS" "$VALIDATORS"
        sed -i "s|^\([[:space:]]*validators[[:space:]]*=\).*|\1 [\"${VALIDATORS}\"]|" "$CONFIG_FILE" 2>/dev/null || true
    fi
    if [ "$NODE_PROFILE" = "cpu" ]; then set_env_value "$ENV_FILE" "QUIP_MINER_CPUSET" "$CPUSET"
    else set_env_value "$ENV_FILE" "QUIP_GPU_UTILIZATION" "$GPU_UTIL"; fi

    echo -e "  ${DIM}pulling images...${N}"
    c_pull
    [ "$NODE_PROFILE" = "cuda" ] && start_mps
    echo -e "  ${DIM}starting ($([ "$NODE_MODE" = miner ] && echo 'miner only' || echo 'full node'))...${N}"
    c_up --force-recreate 2>/dev/null || c_up

    [ -f "$INSTALL_DIR/cron.sh" ] && bash "$INSTALL_DIR/cron.sh" --install >/dev/null 2>&1

    echo ""
    echo -e "  ${G}up.${N} generating keystore, funding via faucet, registering on-chain..."
    local w=""
    for _ in $(seq 1 20); do w=$(get_wallet); [ -n "$w" ] && break; sleep 3; done
    echo ""
    echo -e "  ${C}mode     ${N}$( [ "$NODE_MODE" = miner ] && echo 'MINER (only)' || echo 'NODE (full)' )"
    echo -e "  ${C}name     ${N}${NODE_NAME}"
    [ -n "$w" ] && echo -e "  ${C}wallet   ${N}${w}  ${DIM}(back up data/keystore.json!)${N}" || echo -e "  ${Y}wallet not ready yet — see 'node info'${N}"
    [ "$NODE_MODE" = miner ] && echo -e "  ${C}node rpc ${N}${VALIDATORS}" \
        || echo -e "  ${C}dashboard${N} http://$(curl -fsSL --max-time 4 https://api.ipify.org 2>/dev/null || echo localhost):20049/"
    echo ""
    read -p "  enter..."
}

do_start() {
    header
    [ -d "$INSTALL_DIR" ] || { echo -e "  ${R}not installed${N}"; read -p "  "; return; }
    [ "$NODE_PROFILE" = "cuda" ] && { check_gpu || { read -p "  "; return; }; start_mps; }
    c_up
    read -p "  enter..."
}

do_stop() {
    header
    [ -d "$INSTALL_DIR" ] || { echo -e "  ${R}not installed${N}"; read -p "  "; return; }
    c_down
    read -p "  enter..."
}

do_logs() {
    [ -d "$INSTALL_DIR" ] || { header; echo -e "  ${R}not installed${N}"; read -p "  "; return; }
    cd "$INSTALL_DIR" || return
    clear
    echo -e "  ${C}1${N}  miner logs"
    [ "$NODE_MODE" = node ] && echo -e "  ${C}2${N}  validator (node) logs"
    echo -e "  ${DIM}0  back${N}"; echo ""
    read -p "  > " ch
    echo -e "${DIM}  ctrl+c to exit${N}"; echo ""
    case "$ch" in
        1) docker compose logs -f --tail=200 "$NODE_PROFILE" ;;
        2) [ "$NODE_MODE" = node ] && docker compose logs -f --tail=200 quip-validator ;;
        *) return ;;
    esac
}

do_info() {
    header
    [ -d "$INSTALL_DIR" ] || { echo -e "  ${R}not installed${N}"; read -p "  "; return; }
    local w; w=$(get_wallet)
    echo -e "  ${DIM}mode     ${N}$( [ "$NODE_MODE" = miner ] && echo 'MINER (only)' || echo 'NODE (full)' )  ${DIM}backend ${NODE_PROFILE^^}${N}"
    echo -e "  ${DIM}name     ${N}$(get_node_name)"
    [ -n "$w" ] && echo -e "  ${DIM}wallet   ${N}${C}${w}${N}" || echo -e "  ${Y}wallet not generated yet (bootstrapping)${N}"
    if [ "$NODE_MODE" = miner ]; then
        echo -e "  ${DIM}node rpc ${N}$(get_validators)"
        echo -e "  ${DIM}stats    ${N}on your NODE's dashboard (port 20049)"
    else
        echo -e "  ${DIM}dashboard${N} http://localhost:20049/   ${DIM}(rich stats UI)${N}"
    fi
    echo ""
    echo -e "  ${DIM}containers${N}"; docker ps --filter 'name=quip-' --format '    {{.Names}}  {{.Status}}' 2>/dev/null
    echo ""
    local s
    for ep in status stats miner/survey; do
        s=$(api_json "$ep")
        [ -n "$s" ] && { echo -e "  ${BOLD}/api/v1/${ep}${N}"; echo "$s" | jq -C '.' 2>/dev/null | sed 's/^/    /' | head -40 || echo "$s" | head -c 800; break; }
    done
    [ -z "$s" ] && echo -e "  ${DIM}api not reachable here — see node dashboard / miner logs${N}"
    echo ""
    read -p "  enter..."
}

do_update() {
    header
    [ -d "$INSTALL_DIR" ] || { echo -e "  ${R}not installed${N}"; read -p "  "; return; }
    cd "$INSTALL_DIR" || return
    git pull --ff-only 2>/dev/null || true
    [ "$NODE_PROFILE" = "cuda" ] && start_mps
    c_pull && c_up
    read -p "  enter..."
}

do_switch() {
    header
    [ -d "$INSTALL_DIR" ] || { echo -e "  ${R}not installed${N}"; read -p "  "; return; }
    local old="$NODE_PROFILE"
    echo -e "  ${DIM}switch backend (keeps mode + wallet)${N}"
    echo -e "  ${C}1${N}  cpu"
    echo -e "  ${C}2${N}  cuda"
    read -p "  [current: ${old^^}]: " p
    case "$p" in 2) NODE_PROFILE="cuda";; *) NODE_PROFILE="cpu";; esac
    [ "$NODE_PROFILE" = "cuda" ] && { check_gpu || { NODE_PROFILE="$old"; read -p "  "; return; }; }
    cd "$INSTALL_DIR" || return
    if [ "$NODE_MODE" = miner ]; then docker compose rm -sf "$old" 2>/dev/null || true
    else docker compose --profile "$old" down 2>/dev/null || true; fi
    save_profile "$NODE_PROFILE"
    [ "$NODE_PROFILE" = "cuda" ] && start_mps
    c_pull && c_up
    read -p "  enter..."
}

do_remove() {
    header
    echo -e "  ${Y}removes containers + repo. data/ (incl. your wallet keystore) is deleted — back up first!${N}"
    read -p "  type 'yes': " c
    [ "$c" = "yes" ] || { read -p "  "; return; }
    if [ -d "$INSTALL_DIR" ]; then
        cd "$INSTALL_DIR" || return
        for pr in cpu cuda; do docker compose --profile "$pr" down 2>/dev/null; docker compose rm -sf "$pr" 2>/dev/null; done
        [ -f cron.sh ] && bash cron.sh --uninstall >/dev/null 2>&1
    fi
    rm -rf "$INSTALL_DIR" "$PROFILE_FILE" "$MODE_FILE"
    read -p "  enter..."
}

# ---------- menu -------------------------------------------------------------

while true; do
    header
    echo -e "  ${C}1${N}  install   ${DIM}(node or miner)${N}"
    echo -e "  ${C}2${N}  start"
    echo -e "  ${C}3${N}  stop"
    echo -e "  ${C}4${N}  logs"
    echo -e "  ${C}5${N}  node info  ${DIM}(wallet + stats)${N}"
    echo -e "  ${C}6${N}  update"
    echo -e "  ${C}7${N}  switch backend  ${DIM}(${NODE_PROFILE^^})${N}"
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
        5) do_info ;;
        6) do_update ;;
        7) do_switch ;;
        8) do_remove ;;
        0) exit 0 ;;
        *) sleep 0.3 ;;
    esac
done
