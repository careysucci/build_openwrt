#!/bin/bash
#
# File: scripts/setup.sh
# Description: Initial setup and verification script
#
# Usage: bash scripts/setup.sh
#
# Copyright (c) 2019-2024
#
# This is free software, licensed under the MIT License.
# See /LICENSE for more information.
#

set -Eeuo pipefail

echo ""
echo "========================================"
echo "OpenWrt Local Build System Setup"
echo "========================================"
echo ""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo "[INFO] Project directory: ${PROJECT_DIR}"
echo "[INFO] Script directory: ${SCRIPT_DIR}"
echo ""

# Check for required directories
echo "[INFO] Checking directory structure..."
required_dirs=("lib" "scripts" "diy" ".github/workflows")
for dir in "${required_dirs[@]}"; do
  if [ -d "${PROJECT_DIR}/${dir}" ]; then
    echo "[✓] Directory exists: ${dir}/"
  else
    echo "[✗] Directory missing: ${dir}/"
  fi
done

echo ""

# Check for required files
echo "[INFO] Checking required files..."
required_files=(
  "build.sh"
  "diy-part1.sh"
  "diy-part2.sh"
  "lib/common.sh"
  "lib/logger.sh"
  "lib/functions.sh"
  "scripts/00_prepare.sh"
  "scripts/01_env.sh"
  "scripts/02_clone.sh"
  "scripts/03_feeds.sh"
  "scripts/04_patch.sh"
  "scripts/05_diy.sh"
  "scripts/06_config.sh"
  "scripts/07_download.sh"
  "scripts/08_compile.sh"
  "scripts/09_package.sh"
  "scripts/10_clean.sh"
  ".github/workflows/openwrt-lean.yml"
  ".github/workflows/openwrt-official.yml"
)

for file in "${required_files[@]}"; do
  if [ -f "${PROJECT_DIR}/${file}" ]; then
    echo "[✓] File exists: ${file}"
  else
    echo "[✗] File missing: ${file}"
  fi
done

echo ""

# Check script permissions
echo "[INFO] Fixing script permissions..."
chmod +x "${PROJECT_DIR}/build.sh" || true
chmod +x "${PROJECT_DIR}/diy-part1.sh" || true
chmod +x "${PROJECT_DIR}/diy-part2.sh" || true
chmod +x "${PROJECT_DIR}/scripts"/*.sh 2>/dev/null || true
chmod +x "${PROJECT_DIR}/lib"/*.sh 2>/dev/null || true
echo "[✓] Script permissions updated"

echo ""

# Check for ShellCheck
echo "[INFO] Checking for ShellCheck..."
if command -v shellcheck &> /dev/null; then
  echo "[✓] ShellCheck is installed ($(shellcheck --version | head -1))"
  echo "[INFO] Running ShellCheck on build.sh..."
  if shellcheck -x "${PROJECT_DIR}/build.sh" 2>&1 | grep -v "SC1090\|SC1091"; then
    echo "[✓] ShellCheck passed"
  else
    echo "[INFO] ShellCheck found some issues (may be informational)"
  fi
else
  echo "[!] ShellCheck not installed (optional)"
  echo "    Install with: sudo apt-get install shellcheck"
fi

echo ""

# System information
echo "[INFO] System Information:"
echo "  OS: $(lsb_release -ds 2>/dev/null || echo 'Unknown')"
echo "  Kernel: $(uname -r)"
echo "  CPU Cores: $(nproc)"
if [ -f /proc/meminfo ]; then
  MEM_GB=$(grep MemTotal /proc/meminfo | awk '{print $2 / 1024 / 1024}' | cut -d. -f1)
  echo "  Memory: ${MEM_GB}GB"
fi
if command -v df &> /dev/null; then
  DISK_GB=$(df "${PROJECT_DIR}" | tail -1 | awk '{print $4 / 1024 / 1024}' | cut -d. -f1)
  echo "  Available Disk: ${DISK_GB}GB"
fi

echo ""

# Check for required commands
echo "[INFO] Checking for required commands..."
required_commands=(git wget curl make gcc python3)
missing_commands=()

for cmd in "${required_commands[@]}"; do
  if command -v "$cmd" &> /dev/null; then
    echo "[✓] Found: $cmd"
  else
    echo "[✗] Missing: $cmd"
    missing_commands+=("$cmd")
  fi
done

echo ""

if [ ${#missing_commands[@]} -gt 0 ]; then
  echo "[WARN] Missing commands: ${missing_commands[*]}"
  echo "[INFO] Run: bash build.sh to install dependencies automatically"
else
  echo "[✓] All required commands found"
fi

echo ""
echo "[✓] Setup verification completed!"
echo ""
echo "Next steps:"
echo "1. Review configuration files in diy/ directory"
echo "2. Run: bash build.sh lede 1.26"
echo "   or: bash build.sh official 1.26"
echo ""
echo "For more information, see README_LOCAL_BUILD.md"
echo ""
