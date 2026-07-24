#!/bin/bash
#
# File: scripts/01_env.sh
# Description: Environment variables setup
#
# Copyright (c) 2019-2024
#
# This is free software, licensed under the MIT License.
# See /LICENSE for more information.
#

set -Eeuo pipefail

source "${SCRIPT_DIR}/lib/logger.sh"

log_info "Step 01: Environment Variables Setup"

# Display build configuration
log_info "Build Configuration:"
log_info "  Repository: $REPO_URL"
log_info "  Branch: $REPO_BRANCH"
log_info "  Target: $TARGET_MATRIX"
log_info "  Config: $CONFIG_FILE"
log_info "  Golang: $GOLANG_VERSON"
log_info "  Timezone: $TZ"
log_info "  Threads: $NPROC"
log_info "  Make -j: $MAKE_J"

# Export all variables
export REPO_URL REPO_BRANCH FEEDS_CONF CONFIG_FILE DIY_P1_SH DIY_P2_SH
export CONFIG_FIREWALL_FILE UPLOAD_BIN_DIR UPLOAD_FIRMWARE UPLOAD_RELEASE
export AUTHORED_BY IMG_PREFIX TARGET_MATRIX RELEASE_NAME TZ
export GOLANG_VERSON BUILD_DATE BUILD_USER HOSTNAME WORKSPACE
export NPROC MAKE_J TOTAL_MEM AVAILABLE_DISK

log_success "Environment variables configured"
