#!/bin/bash
#
# File: scripts/08_compile.sh
# Description: Compile firmware
#
# Copyright (c) 2019-2024
#
# This is free software, licensed under the MIT License.
# See /LICENSE for more information.
#

set -Eeuo pipefail

source "${SCRIPT_DIR}/lib/logger.sh"
source "${SCRIPT_DIR}/lib/functions.sh"

log_info "Step 08: Compile Firmware"

cd "${WORKSPACE}/${TARGET_MATRIX}" || exit 1

log_progress "Disk usage before compilation:"
df -hT || true

log_progress "Starting compilation with $NPROC threads..."
if make_compile "." 2>&1; then
  log_success "Compilation completed"
else
  log_error "Compilation failed"
  exit 1
fi

log_progress "Disk usage after compilation:"
df -hT || true

# Extract device name and date
if [ -f ./.config ]; then
  DEVICE_NAME=$(get_device_name "./.config" || echo "")
  if [ -n "$DEVICE_NAME" ]; then
    export DEVICE_NAME="_${DEVICE_NAME}"
    log_info "Device: ${DEVICE_NAME}"
  fi
fi

export FILE_DATE="_$(date +"%Y%m%d%H%M")"
log_info "Build timestamp: ${FILE_DATE}"

log_success "Compilation stage completed"
