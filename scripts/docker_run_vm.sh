#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

CONFIRM=0
IMAGE_ARG=""
usage(){
  cat <<EOF
Usage: $(basename "$0") [--confirm] [DOCKER_IMAGE]

Without --confirm the script will check whether IOMMU appears enabled and
will refuse to proceed if not. Re-run with --confirm to accept that IOMMU
is already enabled (or you accept the risk) and to allow the script to
hot-unbind the host GPU, bind it to vfio-pci, run the Docker container, and
then restore the original driver when the container exits.

DOCKER_IMAGE: optional existing image name to run. If omitted and
docker/Dockerfile exists, the script will build image 'moneta-nvidia'.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --confirm|-c) CONFIRM=1; shift;;
    --help|-h) usage; exit 0;;
    *) IMAGE_ARG="$1"; shift;;
  esac
done

echo "[host] Running GPU detection and writing .env (may prompt if multiple GPUs)"
bash scripts/setup_nvidia_for_docker.sh

if [ ! -f ".env" ]; then
  echo "ERROR: .env not found after detection" >&2
  exit 1
fi

set -a
. .env
set +a

if [ -z "${GPU_ID:-}" ]; then
  echo "ERROR: GPU_ID not set in .env" >&2
  exit 1
fi

# Normalize GPU_ID -> PCI_FULL
if [[ "$GPU_ID" =~ ^[0-9a-fA-F]{4}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-9]$ ]]; then
  PCI_FULL="$GPU_ID"
elif [[ "$GPU_ID" =~ ^[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-9]$ ]]; then
  PCI_FULL="0000:$GPU_ID"
else
  echo "ERROR: GPU_ID format not recognized: $GPU_ID" >&2
  exit 1
fi

echo "[host] Target PCI device: $PCI_FULL"

# Check IOMMU
IOMMU_OK=0
if [ -d /sys/kernel/iommu_groups ] && [ -n "$(ls -A /sys/kernel/iommu_groups 2>/dev/null || true)" ]; then
  IOMMU_OK=1
fi

if [ "$IOMMU_OK" -ne 1 ] && [ "$CONFIRM" -ne 1 ]; then
  cat <<MSG
IOMMU does not appear to be enabled on this host.

GPU passthrough requires IOMMU (VT-d / AMD-Vi). To proceed:
- Enable IOMMU in your BIOS/firmware and ensure kernel boot has
  'intel_iommu=on' or 'amd_iommu=on' (or distribution default that enables it),
  then reboot; OR
- If you understand the risks and want to proceed assuming IOMMU is enabled,
  re-run this script with --confirm which will hot-bind the GPU to vfio-pci
  and start the Docker container. After the container exits or is stopped,
  the script will attempt to restore the original driver.

Example:
  ./scripts/docker_run_vm.sh --confirm

MSG
  exit 1
fi

if [ "$IOMMU_OK" -ne 1 ] && [ "$CONFIRM" -eq 1 ]; then
  echo "WARNING: IOMMU not detected, but --confirm supplied: attempting hot-bind anyway. This may fail." >&2
fi

# helper to run privileged commands (uses sudo if not root)
run_as_root(){
  if [ "$(id -u)" -eq 0 ]; then
    bash -c "$1"
  else
    if command -v sudo >/dev/null 2>&1; then
      sudo bash -c "$1"
    else
      echo "ERROR: need root privileges (sudo not available)" >&2
      exit 1
    fi
  fi
}

# Ensure device exists
if [ ! -d "/sys/bus/pci/devices/$PCI_FULL" ]; then
  echo "ERROR: PCI device $PCI_FULL not found under /sys/bus/pci/devices" >&2
  exit 1
fi

# Save original driver/module info for restore
ORIG_DRIVER_NAME=""
ORIG_DRIVER_MODULE=""
if [ -L "/sys/bus/pci/devices/$PCI_FULL/driver" ]; then
  # driver symlink points to /sys/bus/pci/drivers/<drivername>
  ORIG_DRIVER_NAME="$(basename "$(readlink -f "/sys/bus/pci/devices/$PCI_FULL/driver")")"
  if [ -e "/sys/bus/pci/drivers/$ORIG_DRIVER_NAME/module" ]; then
    ORIG_DRIVER_MODULE="$(basename "$(readlink -f "/sys/bus/pci/drivers/$ORIG_DRIVER_NAME/module")")"
  fi
fi

# If the device is already bound to vfio-pci, note it and avoid rebinding
ALREADY_VFIO=0
if [ "$ORIG_DRIVER_NAME" = "vfio-pci" ]; then
  ALREADY_VFIO=1
fi

vendor_hex="$(cat /sys/bus/pci/devices/$PCI_FULL/vendor 2>/dev/null || echo "")"
device_hex="$(cat /sys/bus/pci/devices/$PCI_FULL/device 2>/dev/null || echo "")"
vendor="${vendor_hex#0x}"
device="${device_hex#0x}"

BOUND_BY_SCRIPT=0
cleanup(){
  rc=${1:-0}
  set +e
  # If we bound the device to vfio-pci, unbind it
  if [ "$BOUND_BY_SCRIPT" -eq 1 ]; then
    echo "[cleanup] Unbinding $PCI_FULL from vfio-pci"
    run_as_root "echo $PCI_FULL > /sys/bus/pci/drivers/vfio-pci/unbind" || true
    # try to remove the new_id we added (if supported)
    if [ -w "/sys/bus/pci/drivers/vfio-pci/remove_id" ]; then
      run_as_root "echo $vendor $device > /sys/bus/pci/drivers/vfio-pci/remove_id" || true
    fi
  fi

  # Restore original driver if we recorded one
  if [ -n "$ORIG_DRIVER_NAME" ]; then
    echo "[cleanup] Restoring original driver $ORIG_DRIVER_NAME for $PCI_FULL"
    if [ -n "$ORIG_DRIVER_MODULE" ]; then
      run_as_root "modprobe $ORIG_DRIVER_MODULE || true" || true
    fi
    # register the device id with the original driver and bind
    run_as_root "echo $vendor $device > /sys/bus/pci/drivers/$ORIG_DRIVER_NAME/new_id" || true
    run_as_root "echo $PCI_FULL > /sys/bus/pci/drivers/$ORIG_DRIVER_NAME/bind" || true
    # attempt to remove the new_id from vfio-pci if present
    if [ -w "/sys/bus/pci/drivers/$ORIG_DRIVER_NAME/remove_id" ]; then
      run_as_root "echo $vendor $device > /sys/bus/pci/drivers/$ORIG_DRIVER_NAME/remove_id" || true
    fi
  fi
  exit $rc
}

# Ensure cleanup runs on normal exit and on signals
trap 'cleanup $?' EXIT
trap 'cleanup 130' INT TERM

# Do the hot-binding if requested (CONFIRM) or if IOMMU already OK
if [ "$CONFIRM" -eq 1 ] || [ "$IOMMU_OK" -eq 1 ]; then
  echo "[host] Attempting to bind $PCI_FULL to vfio-pci (this will unbind original driver)"

  if [ "$ALREADY_VFIO" -eq 1 ]; then
    echo "[host] Device $PCI_FULL already bound to vfio-pci; skipping bind steps"
    BOUND_BY_SCRIPT=0
  else
    if [ -L "/sys/bus/pci/devices/$PCI_FULL/driver" ]; then
      echo "[host] Unbinding $PCI_FULL from its current driver ($ORIG_DRIVER_NAME)"
      run_as_root "echo $PCI_FULL > /sys/bus/pci/devices/$PCI_FULL/driver/unbind 2>/dev/null || true"
    fi

    echo "[host] Loading vfio modules"
    run_as_root "modprobe vfio || true"
    run_as_root "modprobe vfio-pci || true"

    if [ -n "$vendor" ] && [ -n "$device" ]; then
      echo "[host] Registering device id $vendor $device with vfio-pci"
      run_as_root "echo $vendor $device > /sys/bus/pci/drivers/vfio-pci/new_id 2>/dev/null || true"
    fi

    echo "[host] Binding $PCI_FULL to vfio-pci"
    run_as_root "echo $PCI_FULL > /sys/bus/pci/drivers/vfio-pci/bind 2>/dev/null || true"

    # verify binding by resolving driver symlink target
    bound_driver="$(readlink -f "/sys/bus/pci/devices/$PCI_FULL/driver" 2>/dev/null || true)"
    if echo "$bound_driver" | grep -q "vfio-pci"; then
      echo "[host] Device $PCI_FULL bound to vfio-pci"
      BOUND_BY_SCRIPT=1
    else
      echo "WARNING: device not confirmed bound to vfio-pci; aborting run" >&2
      exit 1
    fi
  fi
fi

# Determine image name
IMAGE_NAME="${IMAGE_ARG:-${DOCKER_IMAGE:-}}"
if [ -z "$IMAGE_NAME" ]; then
  if [ -f docker/Dockerfile ]; then
    IMAGE_NAME="moneta-nvidia"
    echo "[host] Building Docker image ${IMAGE_NAME} (may take a while)"
    # Use repository root as build context so Dockerfile can COPY files from project root
    run_as_root "docker build -t ${IMAGE_NAME} -f $REPO_ROOT/docker/Dockerfile $REPO_ROOT"
  else
    echo "ERROR: no DOCKER_IMAGE provided and docker/Dockerfile not found" >&2
    exit 1
  fi
fi

echo "[host] Starting container with privileged access and device passthrough"
echo "  (container will mount this repo at /workspace)"

# Run container in foreground; when it exits cleanup trap will run
run_as_root "docker run --rm --privileged --name moneta-nvidia \
  --env-file $REPO_ROOT/.env -e PCI_FULL=${PCI_FULL} \
  ${IMAGE_NAME}"

