#!/bin/bash
#
# File: scripts/00_prepare.sh
# Description: Environment preparation and dependency installation
#
# Copyright (c) 2019-2024
#
# This is free software, licensed under the MIT License.
# See /LICENSE for more information.
#

set -Eeuo pipefail

source "${SCRIPT_DIR}/lib/logger.sh"
source "${SCRIPT_DIR}/lib/functions.sh"

log_info "Step 00: Environment Preparation"

# Detect OS
detect_os || log_warn "OS detection warning"

# Check system resources
check_disk_space
check_memory

# Check for required commands
if ! check_dependencies 2>/dev/null; then
  log_info "Installing missing dependencies..."
  install_dependencies
fi

# Create necessary directories
mkdir_safe "${OUTPUT_DIR}"
mkdir_safe "${LOGS_DIR}"
mkdir_safe "${FIRMWARE_DIR}"
mkdir_safe "${PACKAGES_DIR}"
mkdir_safe "${BUILD_TEMP_DIR}"
mkdir_safe "${CACHE_DIR}"

# Setup ccache
setup_ccache "${CCACHE_DIR}"

# Set timezone
sudo timedatectl set-timezone "${TZ}" 2>/dev/null || true

log_success "Environment preparation completed"
