#!/bin/bash
#
# File: lib/common.sh
# Description: Common variables and constants
#
# Copyright (c) 2019-2024
#
# This is free software, licensed under the MIT License.
# See /LICENSE for more information.
#

set -Eeuo pipefail

# ===== Color codes =====
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ===== Common paths =====
OUTPUT_DIR="${WORKSPACE}/output"
LOGS_DIR="${WORKSPACE}/output/logs"
FIRMWARE_DIR="${WORKSPACE}/output/firmware"
PACKAGES_DIR="${WORKSPACE}/output/packages"
CACHE_DIR="${WORKSPACE}/.cache"
DL_DIR="${WORKSPACE}/${TARGET_MATRIX}/dl"
BUILD_DIR="${WORKSPACE}/${TARGET_MATRIX}/build_dir"
CCACHE_DIR="${WORKSPACE}/.ccache"

# ===== System detection =====
if [ -f /etc/os-release ]; then
  . /etc/os-release
  OS_ID="${ID:-}"
  OS_VERSION_ID="${VERSION_ID:-}"
else
  OS_ID="unknown"
  OS_VERSION_ID="unknown"
fi

# ===== CPU configuration =====
export NPROC=$(nproc 2>/dev/null || echo 1)
export MAKE_J=$((NPROC - 1))
[ "$MAKE_J" -lt 1 ] && MAKE_J=1

# ===== Memory configuration (in MB) =====
if [ -f /proc/meminfo ]; then
  TOTAL_MEM=$(grep MemTotal /proc/meminfo | awk '{print $2 / 1024}' | cut -d. -f1)
else
  TOTAL_MEM=4096
fi

# ===== Disk space (in GB) =====
if command -v df &> /dev/null; then
  AVAILABLE_DISK=$(df "${WORKSPACE}" 2>/dev/null | tail -1 | awk '{print $4 / 1024 / 1024}' | cut -d. -f1 || echo 0)
else
  AVAILABLE_DISK=0
fi

export NPROC MAKE_J TOTAL_MEM AVAILABLE_DISK
