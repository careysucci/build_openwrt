#!/bin/bash
#
# File: scripts/04_patch.sh
# Description: Apply patches and fixes
#
# Copyright (c) 2019-2024
#
# This is free software, licensed under the MIT License.
# See /LICENSE for more information.
#

set -Eeuo pipefail

source "${SCRIPT_DIR}/lib/logger.sh"
source "${SCRIPT_DIR}/lib/functions.sh"

log_info "Step 04: Apply Patches"

cd "${WORKSPACE}/${TARGET_MATRIX}" || exit 1

# Check and apply Linux 6.12+ firewall4 fix
log_progress "Checking for firewall4 (nftables) fix..."
if [ -f "${WORKSPACE}/fix-kmod-nf-ipt-linux612.sh" ]; then
  log_progress "Running firewall4 configuration fix..."
  chmod +x "${WORKSPACE}/fix-kmod-nf-ipt-linux612.sh"
  if "${WORKSPACE}/fix-kmod-nf-ipt-linux612.sh" 2>&1; then
    log_success "Firewall4 fix applied"
  else
    log_warn "Firewall4 fix script warning"
  fi
else
  log_info "Firewall4 fix script not found, skipping"
fi

log_success "Patches applied"
