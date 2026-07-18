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
  source "${WORKSPACE}/${DIY_P2_SH}" || log_warn "DIY P2 warning"
else
  log_warn "DIY Part 2 script not found"
fi

log_progress "Final feeds update after DIY..."
if ./scripts/feeds update -a 2>&1; then
  ./scripts/feeds install -a 2>&1 || log_warn "Feed install warning"
fi

log_success "DIY customizations completed"
