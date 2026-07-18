#!/bin/bash
#
# File: scripts/10_clean.sh
# Description: Cleanup temporary files
#
# Copyright (c) 2019-2024
#
# This is free software, licensed under the MIT License.
# See /LICENSE for more information.
#

set -Eeuo pipefail

source "${SCRIPT_DIR}/lib/logger.sh"
source "${SCRIPT_DIR}/lib/functions.sh"

log_info "Step 10: Cleanup"

cd "${WORKSPACE}" || exit 1

# Clean temporary directory
if [ -d "${BUILD_TEMP_DIR}" ]; then
  log_progress "Cleaning temporary directory..."
  rm_safe "${BUILD_TEMP_DIR}"
fi

# Display final disk usage
log_progress "Final disk usage:"
df -hT "." || true

# List output files
if [ -d "${FIRMWARE_DIR}" ] && [ "$(ls -A ${FIRMWARE_DIR})" ]; then
  log_progress "Firmware files:"
  ls -lh "${FIRMWARE_DIR}"/
fi

log_success "Cleanup completed"
