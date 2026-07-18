#!/bin/bash
#
# File: scripts/07_download.sh
# Description: Download packages
#
# Copyright (c) 2019-2024
#
# This is free software, licensed under the MIT License.
# See /LICENSE for more information.
#

set -Eeuo pipefail

source "${SCRIPT_DIR}/lib/logger.sh"
source "${SCRIPT_DIR}/lib/functions.sh"

log_info "Step 07: Download Packages"

cd "${WORKSPACE}/${TARGET_MATRIX}" || exit 1

# Backup config before download
log_progress "Backing up configuration..."
if [ -f ./.config ]; then
  cp_safe ./.config "${WORKSPACE}/diy/common/.config"
fi

# Download packages
log_progress "Downloading packages (first pass)..."
if ! make_download "." 2>&1; then
  log_error "Download failed"
  exit 1
fi

# Remove incomplete downloads and retry
log_progress "Cleaning incomplete downloads..."
find dl -size -1024c -exec rm -f {} \; 2>/dev/null || true

log_progress "Downloading packages (second pass)..."
if make_download "." 2>&1; then
  log_success "Package download completed"
else
  log_warn "Second download pass had issues, continuing..."
fi

log_success "Download stage completed"
