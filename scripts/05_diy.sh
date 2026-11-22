#!/bin/bash
#
# File: scripts/05_diy.sh
# Description: DIY customizations
#
# Copyright (c) 2019-2024
#
# This is free software, licensed under the MIT License.
# See /LICENSE for more information.
#

set -Eeuo pipefail

source "${SCRIPT_DIR}/lib/logger.sh"
source "${SCRIPT_DIR}/lib/functions.sh"

log_info "Step 05: DIY Configuration"

cd "${WORKSPACE}/${TARGET_MATRIX}" || exit 1

log_progress "Running DIY Part 2 (after feeds)..."
if [ -f "${WORKSPACE}/${DIY_P2_SH}" ]; then
  chmod +x "${WORKSPACE}/${DIY_P2_SH}"
  export GITHUB_WORKSPACE="${WORKSPACE}"
  export GITHUB_TOKEN="${GITHUB_TOKEN:-}"
  cd "${WORKSPACE}" || exit 1
  source "${WORKSPACE}/${DIY_P2_SH}" || log_warn "DIY P2 warning"
  cd "${WORKSPACE}/${TARGET_MATRIX}" || exit 1
else
  log_warn "DIY Part 2 script not found"
fi

log_progress "Final feeds update after DIY..."
if ./scripts/feeds update -a 2>&1; then
  ./scripts/feeds install -a 2>&1 || log_warn "Feed install warning"
  log_progress "Restoring matched dae backend and LuCI packages..."
  ./scripts/feeds install -f -p packages dae 2>&1
  ./scripts/feeds install -f -p luci luci-app-dae 2>&1
fi

log_success "DIY customizations completed"
