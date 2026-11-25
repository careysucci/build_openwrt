#!/bin/bash
#
# File: scripts/06_config.sh
# Description: Configure build
#
# Copyright (c) 2019-2024
#
# This is free software, licensed under the MIT License.
# See /LICENSE for more information.
#

set -Eeuo pipefail

source "${SCRIPT_DIR}/lib/logger.sh"
source "${SCRIPT_DIR}/lib/functions.sh"

log_info "Step 06: Make Config"

cd "${WORKSPACE}/${TARGET_MATRIX}" || exit 1

# Copy config file
if [ -f "${WORKSPACE}/${CONFIG_FILE}" ]; then
  log_progress "Copying config file..."
  cp -f "${WORKSPACE}/${CONFIG_FILE}" ./.config
  log_success "Config file copied"
else
  log_warn "Config file not found: ${CONFIG_FILE}"
  log_progress "Creating default config..."
  make menuconfig || log_warn "Menuconfig warning"
fi

# Make defconfig
log_progress "Running make defconfig..."
if make defconfig 2>&1; then
  log_success "Configuration completed"
else
  log_error "Configuration failed"
  exit 1
fi

if [ "$TARGET_MATRIX" = "official" ]; then
  log_progress "Verifying final BPF toolchain configuration..."
  for symbol in CONFIG_DEVEL=y CONFIG_BPF_TOOLCHAIN_HOST=y CONFIG_USE_LLVM_HOST=y; do
    if ! grep -Fxq "$symbol" ./.config; then
      log_error "Missing $symbol after make defconfig"
      exit 1
    fi
  done
  log_success "Host LLVM configuration verified"
fi

# Backup config
cp_safe ./.config "${WORKSPACE}/output/.config.backup"

log_success "Build configuration completed"
