#!/usr/bin/env bash

# ================= 核心设置 =================
set -uo pipefail
shopt -s nullglob

# ================= 全局变量 =================
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_EXAMPLE="$REPO_ROOT/.env.example"
ENV_FILE="$REPO_ROOT/.env"
TS=$(date +%s)
DEBUG=1

# ================= 日志函数 =================
log_info() { echo -e "\033[0;32m[INFO]\033[0m $*" >&2; }
log_warn() { echo -e "\033[1;33m[WARN]\033[0m $*" >&2; }
log_error() { echo -e "\033[0;31m[ERROR]\033[0m $*" >&2; }
log_debug() { [ "$DEBUG" -eq 1 ] && echo -e "\033[0;34m[DEBUG]\033[0m $*" >&2; }

# ================= 安全的命令执行函数 =================
run_safe() {
    log_debug "Executing: $*"
    set +e
    "$@"
    local ret=$?
    set -e
    if [ $ret -ne 0 ]; then
        log_warn "Command failed (ret=$ret): $*"
    fi
    return $ret
}

# ================= 带重试的 curl =================
curl_retry() {
    local max_attempts=3
    local attempt=1
    local url="$1"
    shift

    while [ $attempt -le $max_attempts ]; do
        log_debug "curl attempt $attempt/$max_attempts: $url"
        set +e
        result=$(curl -fsSL --retry 2 --max-time 15 --connect-timeout 5 "$url" "$@" 2>&1)
        local ret=$?
        set -e

        if [ $ret -eq 0 ]; then
            echo "$result"
            return 0
        else
            log_warn "curl failed (attempt $attempt/$max_attempts): $result"
            attempt=$((attempt + 1))
            [ $attempt -le $max_attempts ] && sleep 2
        fi
    done

    log_error "curl failed after $max_attempts attempts"
    return 1
}

# ================= Usage =================
usage(){
  cat <<EOF
Usage: $(basename "$0") [-h] [-i INDEX] [-p PCI_ADDR]

Detect NVIDIA GPU on the host, update .env with GPU_ID and NVIDIA_VERSION,
and print a recommended docker run command.

Options:
  -h            Show this help
  -i INDEX      Select GPU by index (0-based)
  -p PCI_ADDR   Select GPU by PCI address
  -y            Non-interactive: auto-pick latest
  -v VERSION    Force NVIDIA_VERSION
EOF
}

# ================= 环境文件检查 =================
if [ ! -f "$ENV_EXAMPLE" ]; then
  log_warn ".env.example not found, creating empty file"
  mkdir -p "$(dirname "$ENV_EXAMPLE")"
  cat > "$ENV_EXAMPLE" <<'EOF'
GPU_ID=
NVIDIA_VERSION=
PCI_FULL=
EOF
fi

if [ ! -f "$ENV_FILE" ]; then
  cp "$ENV_EXAMPLE" "$ENV_FILE"
  log_info "Created $ENV_FILE from .env.example"
fi

# ================= 参数解析 =================
SELECT_INDEX=""
SELECT_PCI=""
AUTO_PICK_LATEST=0
FORCE_VERSION=""
while getopts ":hi:p:v:y" opt; do
  case "$opt" in
    h) usage; exit 0;;
    i) SELECT_INDEX="$OPTARG";;
    p) SELECT_PCI="$OPTARG";;
    v) FORCE_VERSION="$OPTARG";;
    y) AUTO_PICK_LATEST=1;;
    :) log_error "Option -$OPTARG requires an argument"; exit 1;;
    \?) log_error "Invalid option: -$OPTARG"; exit 1;;
  esac
done

# ================= GPU 检测 =================
declare -a GPU_INDEX GPU_PCI_FULL GPU_PCI_SHORT GPU_NAME GPU_UUID

detect_with_nvidia_smi(){
  log_debug "Trying to detect with nvidia-smi..."
  if ! command -v nvidia-smi >/dev/null 2>&1; then
    log_debug "nvidia-smi not found"
    return 1
  fi

  local lines=()
  set +e
  mapfile -t lines < <(nvidia-smi --query-gpu=index,pci.bus_id,name,uuid --format=csv,noheader 2>/dev/null)
  local ret=$?
  set -e

  if [ $ret -ne 0 ] || [ ${#lines[@]} -eq 0 ]; then
    log_debug "nvidia-smi returned no results"
    return 1
  fi

  for l in "${lines[@]}"; do
    log_debug "Parsing line: $l"
    local idx pci rest uuid name_and_middle name

    idx=$(echo "$l" | cut -d',' -f1 | tr -d '[:space:]')
    pci=$(echo "$l" | cut -d',' -f2 | tr -d '[:space:]')
    uuid=$(echo "$l" | awk -F',' '{gsub(/[[:space:]]/, "", $NF); print $NF}')
    name=$(echo "$l" | awk -F',' '{for(i=3;i<NF;i++) printf "%s", $i; print ""}' | sed 's/^ *//;s/ *$//')

    local pci_short="${pci#0000:}"

    GPU_INDEX+=("$idx")
    GPU_PCI_FULL+=("$pci")
    GPU_PCI_SHORT+=("$pci_short")
    GPU_NAME+=("$name")
    GPU_UUID+=("$uuid")
  done

  log_info "Detected ${#GPU_INDEX[@]} GPU(s) with nvidia-smi"
  return 0
}

detect_with_lspci(){
  log_debug "Trying to detect with lspci..."
  if ! command -v lspci >/dev/null 2>&1; then
    log_debug "lspci not found"
    return 1
  fi

  local lines=()
  set +e
  mapfile -t lines < <(lspci -D 2>/dev/null | grep -iE 'vga|3d controller|display controller' | grep -i nvidia)
  local ret=$?
  set -e

  if [ $ret -ne 0 ] || [ ${#lines[@]} -eq 0 ]; then
    log_debug "lspci returned no results"
    return 1
  fi

  local idx=0
  for l in "${lines[@]}"; do
    local pci=$(echo "$l" | awk '{print $1}')
    local name=$(echo "$l" | cut -d ' ' -f3-)
    local pci_short="${pci#0000:}"

    GPU_INDEX+=("$idx")
    GPU_PCI_FULL+=("$pci")
    GPU_PCI_SHORT+=("$pci_short")
    GPU_NAME+=("$name")
    GPU_UUID+=("")
    idx=$((idx+1))
  done

  log_info "Detected ${#GPU_INDEX[@]} GPU(s) with lspci"
  return 0
}

log_info "Starting GPU detection..."
detect_success=0
if detect_with_nvidia_smi; then
  detect_success=1
elif detect_with_lspci; then
  detect_success=1
fi

if [ $detect_success -ne 1 ]; then
  log_error "No NVIDIA GPUs detected (neither nvidia-smi nor lspci worked)"
  log_error "Please install NVIDIA drivers or pciutils and try again"
  exit 1
fi

# ================= 打印检测结果 =================
echo
log_info "Detected ${#GPU_INDEX[@]} NVIDIA GPU(s):"
for i in "${!GPU_INDEX[@]}"; do
  echo "  [$i] index=${GPU_INDEX[i]} pci=${GPU_PCI_SHORT[i]} name=${GPU_NAME[i]}"
done

# ================= 选择 GPU =================
chosen_idx=""
if [ -n "$SELECT_INDEX" ]; then
  chosen_idx="$SELECT_INDEX"
elif [ -n "$SELECT_PCI" ]; then
  for i in "${!GPU_PCI_FULL[@]}"; do
    if [ "${GPU_PCI_FULL[i]}" = "$SELECT_PCI" ] || [ "${GPU_PCI_SHORT[i]}" = "$SELECT_PCI" ]; then
      chosen_idx="$i"
      break
    fi
  done
  if [ -z "$chosen_idx" ]; then
    log_error "No GPU matches PCI id $SELECT_PCI"
    exit 1
  fi
else
  if [ "${#GPU_INDEX[@]}" -gt 1 ] && [ -t 0 ]; then
    echo -n "Multiple GPUs found. Enter index to use (default 0): "
    read -r reply || true
    if [ -z "$reply" ]; then
      chosen_idx=0
    else
      chosen_idx="$reply"
    fi
  else
    chosen_idx=0
  fi
fi

if ! [[ "$chosen_idx" =~ ^[0-9]+$ ]]; then
  log_error "Invalid GPU index: $chosen_idx"
  exit 1
fi
if [ "$chosen_idx" -lt 0 ] || [ "$chosen_idx" -ge "${#GPU_INDEX[@]}" ]; then
  log_error "Index out of range: $chosen_idx"
  exit 1
fi

PCI_FULL="${GPU_PCI_FULL[$chosen_idx]}"
PCI_SHORT="${GPU_PCI_SHORT[$chosen_idx]}"
IDX="${GPU_INDEX[$chosen_idx]}"
NAME="${GPU_NAME[$chosen_idx]}"
UUID="${GPU_UUID[$chosen_idx]:-}"

echo
log_info "Selected GPU: index=$IDX pci=$PCI_SHORT name=$NAME"

# ================= 驱动版本检测 =================
DRIVER_VER=""
DRIVER_SOURCE=""

if command -v nvidia-smi >/dev/null 2>&1; then
  log_debug "Getting driver version from nvidia-smi..."
  set +e
  DRIVER_VER=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -n1 | tr -d '[:space:]')
  set -e
  if [ -n "$DRIVER_VER" ]; then
    DRIVER_SOURCE="installed"
    log_debug "Installed driver version: $DRIVER_VER"
  fi
fi

if [ -z "$DRIVER_VER" ] && command -v ubuntu-drivers >/dev/null 2>&1; then
  log_debug "Getting recommended driver from ubuntu-drivers..."
  set +e
  rec_pkg=$(ubuntu-drivers devices 2>/dev/null | grep recommended | head -n1 | grep -Po 'nvidia-driver-[0-9]+' || true)
  set -e
  if [ -n "$rec_pkg" ]; then
    DRIVER_VER="$rec_pkg"
    DRIVER_SOURCE="recommended"
    log_debug "Recommended driver: $DRIVER_VER"
  fi
fi

# ================= 下载版本检测 =================
DOWNLOAD_VERSIONS=()
DOWNLOAD_SORTED=()
DOWNLOAD_VER=""
DOWNLOAD_SOURCE=""

if command -v curl >/dev/null 2>&1; then
  log_info "Fetching available NVIDIA driver versions..."
  set +e
  DOWNLOAD_VERSIONS_RAW=$(curl_retry 'https://download.nvidia.com/XFree86/Linux-x86_64/')
  set -e

  if [ -n "$DOWNLOAD_VERSIONS_RAW" ]; then
    log_debug "Parsing download versions..."
    set +e
    mapfile -t DOWNLOAD_VERSIONS < <(echo "$DOWNLOAD_VERSIONS_RAW" | grep -oE '([0-9]+\.[0-9]+(\.[0-9]+)*)/' | sed 's:/$::' | sort -V -u)
    set -e
    log_debug "Found ${#DOWNLOAD_VERSIONS[@]} downloadable versions"
  fi
fi

if [ ${#DOWNLOAD_VERSIONS[@]} -gt 0 ]; then
  set +e
  mapfile -t DOWNLOAD_SORTED < <(printf "%s\n" "${DOWNLOAD_VERSIONS[@]}" | sort -V -r)
  set -e
fi

# ================= 版本匹配逻辑 =================
if [ -n "${FORCE_VERSION:-}" ]; then
  if [[ "$FORCE_VERSION" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
    DOWNLOAD_VER="$FORCE_VERSION"
    DOWNLOAD_SOURCE="forced"
  else
    log_error "Invalid version format: $FORCE_VERSION"
    exit 1
  fi
elif [ ${#DOWNLOAD_SORTED[@]} -gt 0 ]; then
  if [ -n "$DRIVER_VER" ]; then
    for v in "${DOWNLOAD_SORTED[@]}"; do
      if [ "$v" = "$DRIVER_VER" ]; then
        DOWNLOAD_VER="$v"
        DOWNLOAD_SOURCE="match-installed"
        break
      fi
    done
  fi

  if [ -z "$DOWNLOAD_VER" ] && [ -n "$DRIVER_VER" ]; then
    maj=""
    if [[ "$DRIVER_VER" =~ ^nvidia-driver-([0-9]+)$ ]]; then
      maj="${BASH_REMATCH[1]}"
    elif [[ "$DRIVER_VER" =~ ^([0-9]+)\.[0-9]+ ]]; then
      maj="${BASH_REMATCH[1]}"
    elif [[ "$DRIVER_VER" =~ ^([0-9]+)$ ]]; then
      maj="${BASH_REMATCH[1]}"
    fi

    if [ -n "$maj" ]; then
      for v in "${DOWNLOAD_SORTED[@]}"; do
        if [[ "$v" == "$maj."* ]]; then
          DOWNLOAD_VER="$v"
          DOWNLOAD_SOURCE="mapped-major"
          break
        fi
      done
    fi
  fi

  if [ -z "$DOWNLOAD_VER" ]; then
    DOWNLOAD_VER="${DOWNLOAD_SORTED[0]}"
    DOWNLOAD_SOURCE="latest"
  fi
else
  if [[ "$DRIVER_VER" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
    DOWNLOAD_VER="$DRIVER_VER"
    DOWNLOAD_SOURCE="driver-numeric"
  else
    log_warn "Could not determine exact NVIDIA_VERSION"
    DOWNLOAD_VER="${DRIVER_VER:-}"
    DOWNLOAD_SOURCE="unknown"
  fi
fi

# ================= 更新 .env 文件 =================
log_info "Updating .env file..."
cp "$ENV_FILE" "$ENV_FILE.bak.$TS"

set_env(){
  local key="$1"
  local val="$2"
  local file="$3"

  log_debug "Setting $key=$val in $file"

  if grep -qE "^${key}=" "$file"; then
    local tmpfile=$(mktemp)
    sed -E "s/^(${key})=.*/\1=${val//\//\\/}/" "$file" > "$tmpfile" && mv "$tmpfile" "$file"
  else
    echo "${key}=${val}" >> "$file"
  fi
}

set_env "GPU_ID" "$PCI_SHORT" "$ENV_FILE"
set_env "PCI_FULL" "$PCI_FULL" "$ENV_FILE"
set_env "NVIDIA_VERSION" "${DOWNLOAD_VER:-}" "$ENV_FILE"

# ================= 最终输出 =================
echo
if [ -n "$DOWNLOAD_VER" ]; then
  log_info "Successfully updated $ENV_FILE"
  echo "  GPU_ID=$PCI_SHORT"
  echo "  PCI_FULL=$PCI_FULL"
  echo "  NVIDIA_VERSION=$DOWNLOAD_VER"
  echo "  (source: download=${DOWNLOAD_SOURCE:-unknown}, driver=${DRIVER_SOURCE:-none})"
else
  log_warn "Updated $ENV_FILE with partial information"
  echo "  GPU_ID=$PCI_SHORT"
  echo "  NVIDIA_VERSION=${DRIVER_VER:-<not-detected>}"
fi

echo
cat <<EOF
Docker run example:
  docker run --rm --gpus "device=${PCI_FULL}" \\
    -e GPU_ID=${PCI_SHORT} \\
    -e NVIDIA_VERSION=${DOWNLOAD_VER:-${DRIVER_VER:-}} \\
    <your-image>

Backup created: $ENV_FILE.bak.$TS
EOF

log_info "Done!"
exit 0

