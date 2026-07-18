#!/bin/bash
#
# File: lib/logger.sh
# Description: Logging functions with colored output
#
# Copyright (c) 2019-2024
#
# This is free software, licensed under the MIT License.
# See /LICENSE for more information.
#

set -Eeuo pipefail

source "${SCRIPT_DIR}/lib/common.sh"

# ===== Logging functions =====

log_info() {
  echo -e "${BLUE}[INFO]${NC} $*" >&2
}

log_success() {
  echo -e "${GREEN}[✓]${NC} $*" >&2
}

log_warn() {
  echo -e "${YELLOW}[WARN]${NC} $*" >&2
}

log_error() {
  echo -e "${RED}[✗]${NC} $*" >&2
}

log_section() {
  echo ""
  echo -e "${BLUE}========================================${NC}"
  echo -e "${BLUE}$*${NC}"
  echo -e "${BLUE}========================================${NC}"
  echo ""
}

log_debug() {
  if [ "${DEBUG:-0}" = "1" ]; then
    echo -e "${BLUE}[DEBUG]${NC} $*" >&2
  fi
}

log_progress() {
  echo -e "${BLUE}>>>${NC} $*" >&2
}
