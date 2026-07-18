#!/bin/bash
#
# File: scripts/02_clone.sh
# Description: Clone OpenWrt source code
#
# Copyright (c) 2019-2024
#
# This is free software, licensed under the MIT License.
# See /LICENSE for more information.
#

set -Eeuo pipefail

source "${SCRIPT_DIR}/lib/logger.sh"
source "${SCRIPT_DIR}/lib/functions.sh"

log_info "Step 02: Clone Source Code"

cd "${WORKSPACE}" || exit 1

# Check available space
log_progress "Checking disk space before clone..."
df -hT "." || true

# Clone or update source
if [ -d "${TARGET_MATRIX}/.git" ]; then
  log_progress "OpenWrt directory exists, updating..."
  cd "${TARGET_MATRIX}" || exit 1
  
  # Try to update
  if git fetch origin 2>&1; then
    git reset --hard origin/"${REPO_BRANCH}" 2>&1 || log_warn "Reset warning"
  else
    log_warn "Fetch failed, will proceed with existing code"
  fi
  
  cd "${WORKSPACE}" || exit 1
else
  log_progress "Cloning OpenWrt source..."
  git_clone_with_retry "${REPO_URL}" "${REPO_BRANCH}" "${TARGET_MATRIX}" || exit 1
fi

# Verify clone
if [ ! -d "${TARGET_MATRIX}" ] || [ ! -d "${TARGET_MATRIX}/.git" ]; then
  log_error "Failed to clone OpenWrt source"
  exit 1
fi

log_progress "Displaying disk usage after clone..."
df -hT "." || true

log_success "Source code cloned successfully"
