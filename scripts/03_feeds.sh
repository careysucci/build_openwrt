#!/bin/bash
#
# File: scripts/03_feeds.sh
# Description: Update and install feeds
#
# Copyright (c) 2019-2024
#
# This is free software, licensed under the MIT License.
# See /LICENSE for more information.
#

set -Eeuo pipefail

source "${SCRIPT_DIR}/lib/logger.sh"
source "${SCRIPT_DIR}/lib/functions.sh"

log_info "Step 03: Load Feeds"

cd "${WORKSPACE}/${TARGET_MATRIX}" || exit 1

log_progress "Running DIY Part 1 (before feeds)..."
if [ -f "${WORKSPACE}/${DIY_P1_SH}" ]; then
  chmod +x "${WORKSPACE}/${DIY_P1_SH}"
  source "${WORKSPACE}/${DIY_P1_SH}" || log_warn "DIY P1 warning"
else
  log_warn "DIY Part 1 script not found"
fi

log_progress "Updating feeds..."
if ./scripts/feeds update -a 2>&1; then
  log_progress "Installing feeds..."
  ./scripts/feeds install -a 2>&1 || log_warn "Feed install warning"
else
  log_error "Failed to update feeds"
  exit 1
fi

log_progress "Updating golang packages..."
rm_safe feeds/packages/lang/golang

if [ "${TARGET_MATRIX}" = "lede" ]; then
  # LEDE can accept version from inputs or use latest
  if [ -n "${GOLANG_VERSON}" ]; then
    log_progress "Cloning golang branch: ${GOLANG_VERSON}"
    git clone --depth 1 -b "${GOLANG_VERSON}" https://github.com/kenzok8/golang feeds/packages/lang/golang 2>&1 || \
      git clone --depth 1 https://github.com/kenzok8/golang feeds/packages/lang/golang 2>&1 || log_warn "Golang clone warning"
  else
    git clone --depth 1 https://github.com/kenzok8/golang feeds/packages/lang/golang 2>&1 || log_warn "Golang clone warning"
  fi
else
  # Official OpenWrt must use specified version
  if [ -n "${GOLANG_VERSON}" ]; then
    log_progress "Cloning golang branch: ${GOLANG_VERSON}"
    git clone --depth 1 -b "${GOLANG_VERSON}" https://github.com/kenzok8/golang feeds/packages/lang/golang 2>&1 || exit 1
  else
    log_error "Golang version required for official OpenWrt"
    exit 1
  fi
fi

log_progress "Cleaning conflicting packages..."
rm_safe feeds/packages/utils/v2dat
rm_safe feeds/packages/net/alist
rm_safe feeds/packages/net/adguardhome
rm_safe feeds/packages/net/brook
rm_safe feeds/packages/net/gost
rm_safe feeds/packages/net/mosdns
rm_safe feeds/packages/net/redsocks*
rm_safe feeds/packages/net/smartdns
rm_safe feeds/packages/net/trojan*
rm_safe feeds/packages/net/v2ray*
rm_safe feeds/packages/net/xray*

log_success "Feeds loaded successfully"
