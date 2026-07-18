#!/bin/bash
#
# File: build.sh
# Description: OpenWrt local build orchestrator
# Supports both LEDE and Official OpenWrt builds
#
# Usage: bash build.sh [lede|official] [1.26|1.25|1.24]
#
# Copyright (c) 2019-2024
#
# This is free software, licensed under the MIT License.
# See /LICENSE for more information.
#

set -Eeuo pipefail

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export SCRIPT_DIR

# Load libraries
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/logger.sh"
source "${SCRIPT_DIR}/lib/functions.sh"

# Default values
BUILD_TARGET="${1:-lede}"
GOLANG_VERSION="${2:-1.26}"
BUILD_DATE=$(date +"%Y.%m.%d-%H%M")
BUILD_USER="${USER:-builder}"
HOSTNAME="${HOSTNAME:-localhost}"
WORKSPACE="$(pwd)"
BUILD_TEMP_DIR="${WORKSPACE}/.tmp"
export WORKSPACE BUILD_DATE BUILD_USER HOSTNAME BUILD_TEMP_DIR

# Environment setup
export DEBIAN_FRONTEND=noninteractive
export TZ=Asia/Shanghai

# Validate build target
case "${BUILD_TARGET}" in
  lede|official)
    log_info "Build target: ${BUILD_TARGET}"
    ;;
  *)
    log_error "Invalid build target: ${BUILD_TARGET}"
    log_error "Supported targets: lede, official"
    exit 1
    ;;
esac

# Set environment based on target
case "${BUILD_TARGET}" in
  lede)
    export REPO_URL="https://github.com/coolsnowwolf/lede.git"
    export REPO_BRANCH="master"
    export CONFIG_FILE="diy/x86/lean_auto.config"
    export TARGET_MATRIX="lede"
    export RELEASE_NAME="WyWrt"
    ;;
  official)
    export REPO_URL="https://github.com/openwrt/openwrt.git"
    export REPO_BRANCH="openwrt-25.12"
    export CONFIG_FILE="diy/x86/official_auto.config"
    export TARGET_MATRIX="official"
    export RELEASE_NAME="WyWrt"
    ;;
esac

# Common environment variables
export FEEDS_CONF="feeds.conf.default"
export DIY_P1_SH="diy-part1.sh"
export DIY_P2_SH="diy-part2.sh"
export CONFIG_FIREWALL_FILE="diy/config/99-custom-firewall"
export UPLOAD_BIN_DIR="false"
export UPLOAD_FIRMWARE="true"
export UPLOAD_RELEASE="false"
export AUTHORED_BY="Wy.House"
export IMG_PREFIX="WyHouse"
export GOLANG_VERSON="${GOLANG_VERSION}"

# Trap for cleanup on error
trap 'on_error' ERR
trap 'log_info "Build interrupted"; exit 130' INT

on_error() {
  local line_no=$1
  log_error "Build failed at line ${line_no}"
  exit 1
}

# Main execution
main() {
  log_section "OpenWrt Local Build System"
  log_info "Target: ${BUILD_TARGET}"
  log_info "Golang: ${GOLANG_VERSION}"
  log_info "Date: ${BUILD_DATE}"
  log_info "User: ${BUILD_USER}"
  log_info "Workspace: ${WORKSPACE}"
  
  # Create output directory structure
  mkdir -p "${WORKSPACE}/output/firmware"
  mkdir -p "${WORKSPACE}/output/packages"
  mkdir -p "${WORKSPACE}/output/logs"
  mkdir -p "${BUILD_TEMP_DIR}"
  
  # Run build steps
  log_section "Step 00: Environment Preparation"
  source "${SCRIPT_DIR}/scripts/00_prepare.sh" 2>&1 | tee "${WORKSPACE}/output/logs/00_prepare.log"
  
  log_section "Step 01: Environment Variables"
  source "${SCRIPT_DIR}/scripts/01_env.sh" 2>&1 | tee "${WORKSPACE}/output/logs/01_env.log"
  
  log_section "Step 02: Clone Source Code"
  source "${SCRIPT_DIR}/scripts/02_clone.sh" 2>&1 | tee "${WORKSPACE}/output/logs/02_clone.log"
  
  log_section "Step 03: Load Feeds"
  source "${SCRIPT_DIR}/scripts/03_feeds.sh" 2>&1 | tee "${WORKSPACE}/output/logs/03_feeds.log"
  
  log_section "Step 04: Apply Patches"
  source "${SCRIPT_DIR}/scripts/04_patch.sh" 2>&1 | tee "${WORKSPACE}/output/logs/04_patch.log"
  
  log_section "Step 05: DIY Configuration"
  source "${SCRIPT_DIR}/scripts/05_diy.sh" 2>&1 | tee "${WORKSPACE}/output/logs/05_diy.log"
  
  log_section "Step 06: Make Config"
  source "${SCRIPT_DIR}/scripts/06_config.sh" 2>&1 | tee "${WORKSPACE}/output/logs/06_config.log"
  
  log_section "Step 07: Download Packages"
  source "${SCRIPT_DIR}/scripts/07_download.sh" 2>&1 | tee "${WORKSPACE}/output/logs/07_download.log"
  
  log_section "Step 08: Compile Firmware"
  source "${SCRIPT_DIR}/scripts/08_compile.sh" 2>&1 | tee "${WORKSPACE}/output/logs/08_compile.log"
  
  log_section "Step 09: Package and Organize"
  source "${SCRIPT_DIR}/scripts/09_package.sh" 2>&1 | tee "${WORKSPACE}/output/logs/09_package.log"
  
  log_section "Step 10: Cleanup"
  source "${SCRIPT_DIR}/scripts/10_clean.sh" 2>&1 | tee "${WORKSPACE}/output/logs/10_clean.log"
  
  log_success "Build completed successfully!"
  log_info "Output directory: ${WORKSPACE}/output"
  
  # Summary
  log_section "Build Summary"
  if [ -d "${WORKSPACE}/output/firmware" ] && [ "$(ls -A ${WORKSPACE}/output/firmware)" ]; then
    log_success "Firmware files:"
    ls -lh "${WORKSPACE}/output/firmware/"
  fi
}

main "$@"
