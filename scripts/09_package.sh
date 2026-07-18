#!/bin/bash
#
# File: scripts/09_package.sh
# Description: Package and organize artifacts
#
# Copyright (c) 2019-2024
#
# This is free software, licensed under the MIT License.
# See /LICENSE for more information.
#

set -Eeuo pipefail

source "${SCRIPT_DIR}/lib/logger.sh"
source "${SCRIPT_DIR}/lib/functions.sh"

log_info "Step 09: Package and Organize"

cd "${WORKSPACE}" || exit 1

# Organize firmware files
log_progress "Organizing firmware files..."
if [ "${UPLOAD_FIRMWARE}" = "true" ]; then
  if [ -d "${TARGET_MATRIX}/bin/targets" ]; then
    organize_artifacts "${TARGET_MATRIX}" "${FIRMWARE_DIR}" || log_warn "Organization warning"
  else
    log_warn "No firmware artifacts found"
  fi
fi

# Generate checksums
if [ -d "${FIRMWARE_DIR}" ] && [ "$(ls -A ${FIRMWARE_DIR})" ]; then
  log_progress "Generating SHA256 checksums..."
  generate_sha256 "${FIRMWARE_DIR}" "${WORKSPACE}/output/sha256sum.txt"
fi

# Generate manifest
log_progress "Generating build manifest..."
generate_manifest "${FIRMWARE_DIR}" "${WORKSPACE}/output/manifest.txt"

# Save build information
log_progress "Saving build information..."
{
  echo "Build Date: $(date)"
  echo "Build User: ${BUILD_USER}"
  echo "Build Target: ${TARGET_MATRIX}"
  echo "Source Branch: ${REPO_BRANCH}"
  echo "Golang Version: ${GOLANG_VERSON}"
  echo "System: $(uname -a)"
  echo "CPU Cores: ${NPROC}"
  echo "Total Memory: ${TOTAL_MEM}MB"
  echo "Available Disk: ${AVAILABLE_DISK}GB"
} > "${WORKSPACE}/output/build.info"

log_success "Packaging completed"
