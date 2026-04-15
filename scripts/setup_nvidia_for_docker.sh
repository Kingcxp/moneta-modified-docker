#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_EXAMPLE="$REPO_ROOT/.env.example"
ENV_FILE="$REPO_ROOT/.env"
TS=$(date +%s)

die(){
  echo "ERROR: $*" >&2
  exit 1
}

usage(){
  cat <<EOF
Usage: $(basename "$0") [-h] [-i INDEX] [-p PCI_ADDR]

Detect NVIDIA GPU on the host, update .env with GPU_ID and NVIDIA_VERSION,
and print a recommended docker run command passing the GPU into the container.

Options:
  -h            Show this help
  -i INDEX      Select GPU by index (0-based)
  -p PCI_ADDR   Select GPU by PCI address (short or full, e.g. 01:00.0 or 0000:01:00.0)

If neither -i nor -p are provided the script will pick the first detected GPU.
EOF
}

if [ ! -f "$ENV_EXAMPLE" ]; then
  die ".env.example not found at $ENV_EXAMPLE"
fi

if [ ! -f "$ENV_FILE" ]; then
  cp "$ENV_EXAMPLE" "$ENV_FILE"
  echo "Created $ENV_FILE from .env.example"
fi

SELECT_INDEX=""
SELECT_PCI=""
while getopts ":hi:p:" opt; do
  case "$opt" in
    h) usage; exit 0;;
    i) SELECT_INDEX="$OPTARG";;
    p) SELECT_PCI="$OPTARG";;
    :) die "Option -$OPTARG requires an argument";;
    \?) die "Invalid option: -$OPTARG";;
  esac
done

declare -a GPU_INDEX GPU_PCI_FULL GPU_PCI_SHORT GPU_NAME GPU_UUID

detect_with_nvidia_smi(){
  if ! command -v nvidia-smi >/dev/null 2>&1; then
    return 1
  fi
  mapfile -t lines < <(nvidia-smi --query-gpu=index,pci.bus_id,name,uuid --format=csv,noheader 2>/dev/null || true)
  if [ "${#lines[@]}" -eq 0 ]; then
    return 1
  fi
  for l in "${lines[@]}"; do
    # split on first 3 commas: index,pci,name,uuid
    IFS=',' read -r idx pci rest <<< "$l"
    # rest may contain additional commas; get last token as uuid
    # try to extract uuid (it's usually the last comma-separated field)
    uuid="${l##*,}"
    # name is whatever between second comma and last comma
    name_and_middle="${l#*,}"
    name_and_middle="${name_and_middle#*,}"
    name="${name_and_middle%,*}"

    idx="$(echo "$idx" | tr -d '[:space:]')"
    pci="$(echo "$pci" | tr -d '[:space:]')"
    pci_short="${pci#0000:}"
    name="$(echo "$name" | sed 's/^ *//;s/ *$//')"
    uuid="$(echo "$uuid" | tr -d '[:space:]')"

    GPU_INDEX+=("$idx")
    GPU_PCI_FULL+=("$pci")
    GPU_PCI_SHORT+=("$pci_short")
    GPU_NAME+=("$name")
    GPU_UUID+=("$uuid")
  done
  return 0
}

detect_with_lspci(){
  if ! command -v lspci >/dev/null 2>&1; then
    return 1
  fi
  # Only consider display-class devices (VGA / 3D / Display) to avoid matching
  # NVIDIA audio devices (e.g. the HDMI audio function at PCI .1).
  mapfile -t lines < <(lspci -D 2>/dev/null | grep -iE 'vga|3d controller|display controller' | grep -i nvidia || true)
  if [ "${#lines[@]}" -eq 0 ]; then
    return 1
  fi
  idx=0
  for l in "${lines[@]}"; do
    pci="$(printf '%s' "$l" | awk '{print $1}')"
    name="$(printf '%s' "$l" | cut -d ' ' -f3-)"
    pci_short="${pci#0000:}"
    GPU_INDEX+=("$idx")
    GPU_PCI_FULL+=("$pci")
    GPU_PCI_SHORT+=("$pci_short")
    GPU_NAME+=("$name")
    GPU_UUID+=("")
    idx=$((idx+1))
  done
  return 0
}

if ! detect_with_nvidia_smi && ! detect_with_lspci; then
  die "No NVIDIA GPUs detected (no nvidia-smi and no lspci results)"
fi

echo "Detected ${#GPU_INDEX[@]} NVIDIA GPU(s):"
for i in "${!GPU_INDEX[@]}"; do
  printf "  [%s] index=%s pci=%s name=%s\n" "$i" "${GPU_INDEX[i]}" "${GPU_PCI_SHORT[i]}" "${GPU_NAME[i]}"
done

# Choose GPU
if [ -n "$SELECT_INDEX" ]; then
  chosen_idx="$SELECT_INDEX"
elif [ -n "$SELECT_PCI" ]; then
  chosen_idx=""
  for i in "${!GPU_PCI_FULL[@]}"; do
    if [ "${GPU_PCI_FULL[i]}" = "$SELECT_PCI" ] || [ "${GPU_PCI_SHORT[i]}" = "$SELECT_PCI" ]; then
      chosen_idx="$i"; break
    fi
  done
  if [ -z "$chosen_idx" ]; then
    die "No GPU matches PCI id $SELECT_PCI"
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
  die "Invalid GPU index selected: $chosen_idx"
fi
if [ "$chosen_idx" -lt 0 ] || [ "$chosen_idx" -ge "${#GPU_INDEX[@]}" ]; then
  die "Selected index out of range"
fi

PCI_FULL="${GPU_PCI_FULL[$chosen_idx]}"
PCI_SHORT="${GPU_PCI_SHORT[$chosen_idx]}"
IDX="${GPU_INDEX[$chosen_idx]}"
NAME="${GPU_NAME[$chosen_idx]}"
UUID="${GPU_UUID[$chosen_idx]}"

echo
echo "Selected GPU: index=$IDX pci=$PCI_SHORT name=$NAME"

# Driver detection (best-effort)
# Strategy:
# 1) If nvidia-smi is present, read the installed driver full version (e.g. 530.41.43)
# 2) If not installed, try distro tools to get a recommended/available nvidia-driver package
#    (ubuntu-drivers / apt-cache / dnf). We select the highest numeric candidate but DO NOT install it.
DRIVER_VER=""
DRIVER_SOURCE=""
if command -v nvidia-smi >/dev/null 2>&1; then
  DRIVER_VER="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -n1 | tr -d '[:space:]' || true)"
  if [ -n "$DRIVER_VER" ]; then
    DRIVER_SOURCE="installed"
  fi
fi

# Try to get a distro recommended driver (package name like nvidia-driver-535)
if [ -z "$DRIVER_VER" ] && command -v ubuntu-drivers >/dev/null 2>&1; then
  rec_pkg="$(ubuntu-drivers devices 2>/dev/null | grep recommended | head -n1 | grep -Po 'nvidia-driver-[0-9]+' || true)"
  if [ -n "$rec_pkg" ]; then
    DRIVER_VER="$rec_pkg"
    DRIVER_SOURCE="recommended"
  fi
fi

if [ -z "$DRIVER_VER" ] && command -v nvidia-detect >/dev/null 2>&1; then
  DRIVER_VER="$(nvidia-detect 2>/dev/null | head -n1 || true)"
  if [ -n "$DRIVER_VER" ]; then
    DRIVER_SOURCE="detected"
  fi
fi

# Best-effort: find highest available nvidia-driver package from package manager (no install)
find_latest_available_driver(){
  declare -a cand
  local tmp
  if command -v ubuntu-drivers >/dev/null 2>&1; then
    mapfile -t tmp < <(ubuntu-drivers devices 2>/dev/null | grep -Po 'nvidia-driver-[0-9]+' || true)
    for x in "${tmp[@]}"; do cand+=("$x"); done
  fi
  if command -v apt-cache >/dev/null 2>&1; then
    mapfile -t tmp < <(apt-cache search '^nvidia-driver-[0-9]+' 2>/dev/null | grep -Po 'nvidia-driver-[0-9]+' || true)
    for x in "${tmp[@]}"; do cand+=("$x"); done
  fi
  if command -v dnf >/dev/null 2>&1; then
    mapfile -t tmp < <(dnf --quiet list available 'nvidia-driver*' 2>/dev/null | awk '{print $1}' | grep -Po 'nvidia[-._]?driver[-._]?[0-9]+' || true)
    for x in "${tmp[@]}"; do cand+=("$x"); done
  fi

  # dedupe
  if [ "${#cand[@]}" -eq 0 ]; then
    return 1
  fi
  mapfile -t uniqs < <(printf "%s\n" "${cand[@]}" | sort -u)

  best_pkg=""
  best_num=0
  for p in "${uniqs[@]}"; do
    if [[ "$p" =~ ([0-9]{3,4}) ]]; then
      num="${BASH_REMATCH[1]}"
      if [ -z "$best_pkg" ] || ((num > best_num)); then
        best_num="$num"
        best_pkg="$p"
      fi
    fi
  done
  if [ -n "$best_pkg" ]; then
    printf '%s' "$best_pkg"
    return 0
  fi
  # fallback: return first
  printf '%s' "${uniqs[0]}"
  return 0
}

if [ -z "$DRIVER_VER" ]; then
  if cand_pkg="$(find_latest_available_driver 2>/dev/null || true)"; then
    if [ -n "$cand_pkg" ]; then
      DRIVER_VER="$cand_pkg"
      DRIVER_SOURCE="available"
    fi
  fi
fi
# Attempt to find a downloadable NVIDIA driver version on NVIDIA's servers
# We want a version string such that the URL
# https://download.nvidia.com/XFree86/Linux-x86_64/$VERSION/NVIDIA-Linux-x86_64-$VERSION.run
# exists. Fetch the directory index and pick a matching/full version if possible.
DOWNLOAD_VERSIONS_RAW=""
DOWNLOAD_VERSIONS=()
if command -v curl >/dev/null 2>&1; then
  DOWNLOAD_VERSIONS_RAW="$(curl -fsSL --retry 2 --max-time 10 'https://download.nvidia.com/XFree86/Linux-x86_64/' 2>/dev/null || true)"
fi
if [ -n "$DOWNLOAD_VERSIONS_RAW" ]; then
  mapfile -t DOWNLOAD_VERSIONS < <(printf '%s\n' "$DOWNLOAD_VERSIONS_RAW" | grep -oE '([0-9]+\.[0-9]+(\.[0-9]+)*)/' | sed 's:/$::' | sort -V -u)
fi

DOWNLOAD_VER=""
DOWNLOAD_SOURCE=""

check_downloadable(){
  local ver="$1"
  local url="https://download.nvidia.com/XFree86/Linux-x86_64/${ver}/NVIDIA-Linux-x86_64-${ver}.run"
  if command -v curl >/dev/null 2>&1; then
    if curl -sfI -L --max-time 10 "$url" >/dev/null 2>&1; then
      return 0
    fi
  fi
  return 1
}

if [ "${#DOWNLOAD_VERSIONS[@]}" -gt 0 ]; then
  # sort descending
  mapfile -t DOWNLOAD_SORTED < <(printf '%s\n' "${DOWNLOAD_VERSIONS[@]}" | sort -V -r)

  # If we have an exact installed/recommended DRIVER_VER that matches a downloadable
  # version, prefer it. Otherwise, map package-like candidates (nvidia-driver-535)
  # or major-only candidates to the highest matching full version.
  if [ -n "$DRIVER_VER" ]; then
    # exact match
    for v in "${DOWNLOAD_SORTED[@]}"; do
      if [ "$v" = "$DRIVER_VER" ]; then
        DOWNLOAD_VER="$v"
        DOWNLOAD_SOURCE="match-installed-or-candidate"
        break
      fi
    done
    # try package-style or major mapping
    if [ -z "$DOWNLOAD_VER" ]; then
      if [[ "$DRIVER_VER" =~ ^nvidia-driver-([0-9]+)$ ]]; then
        maj="${BASH_REMATCH[1]}"
      elif [[ "$DRIVER_VER" =~ ^([0-9]+)$ ]]; then
        maj="${BASH_REMATCH[1]}"
      elif [[ "$DRIVER_VER" =~ ^([0-9]+)\.[0-9]+ ]]; then
        maj="${BASH_REMATCH[1]}"
      else
        maj=""
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
  fi

  # If still not found, pick latest available
  if [ -z "$DOWNLOAD_VER" ]; then
    DOWNLOAD_VER="${DOWNLOAD_SORTED[0]}"
    DOWNLOAD_SOURCE="latest"
  fi

  # verify downloadable (should be, but double-check)
  if [ -n "$DOWNLOAD_VER" ]; then
    if ! check_downloadable "$DOWNLOAD_VER"; then
      # if the chosen one is not downloadable for some reason, try to find any that is
      for v in "${DOWNLOAD_SORTED[@]}"; do
        if check_downloadable "$v"; then
          DOWNLOAD_VER="$v"
          DOWNLOAD_SOURCE="verified"
          break
        fi
      done
    fi
  fi
fi

# Backup and update .env
cp "$ENV_FILE" "$ENV_FILE.bak.$TS"

set_env(){
  key="$1"
  val="$2"
  file="$3"
  # escape slashes and & for sed
  esc_val="$(printf '%s' "$val" | sed -e 's/[\/&]/\\&/g')"
  if grep -qE "^${key}=" "$file"; then
    sed -E "s/^(${key})=.*/\1=${esc_val}/" "$file" > "$file.tmp" && mv "$file.tmp" "$file"
  else
    echo "${key}=${val}" >> "$file"
  fi
}

set_env "GPU_ID" "$PCI_SHORT" "$ENV_FILE"
if [ -n "$DOWNLOAD_VER" ]; then
  set_env "NVIDIA_VERSION" "$DOWNLOAD_VER" "$ENV_FILE"
else
  # fallback: use whatever driver string we found earlier
  if [ -n "$DRIVER_VER" ]; then
    set_env "NVIDIA_VERSION" "$DRIVER_VER" "$ENV_FILE"
  fi
fi

echo
if [ -n "$DOWNLOAD_VER" ]; then
  echo "Updated $ENV_FILE -> GPU_ID=$PCI_SHORT NVIDIA_VERSION=$DOWNLOAD_VER (download-source: ${DOWNLOAD_SOURCE:-unknown}, driver-source: ${DRIVER_SOURCE:-none})"
else
  echo "Updated $ENV_FILE -> GPU_ID=$PCI_SHORT NVIDIA_VERSION=${DRIVER_VER:-<not-detected>} (no downloadable match found)"
fi

cat <<EOF

Docker run example (requires nvidia-container-toolkit / NVIDIA Container Runtime):

  docker run --rm --gpus "device=${PCI_FULL}" \
    -e GPU_ID=${PCI_SHORT} \
    -e NVIDIA_VERSION=${DRIVER_VER:-} \
    <your-image>

Notes:
  - Many images read NVIDIA_VISIBLE_DEVICES / GPU env vars. You can also use
    -e NVIDIA_VISIBLE_DEVICES=${PCI_FULL} when using docker-compose.
  - The script updated .env (backup: ${ENV_FILE}.bak.${TS}). Double-check values if needed.

EOF

exit 0
