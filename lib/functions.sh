#!/bin/bash
#
# File: lib/functions.sh
# Description: Utility functions for build process
#
# Copyright (c) 2019-2024
#
# This is free software, licensed under the MIT License.
# See /LICENSE for more information.
#

set -Eeuo pipefail

source "${SCRIPT_DIR}/lib/logger.sh"

# ===== System check functions =====

check_disk_space() {
  local min_required=30
  if [ "$AVAILABLE_DISK" -lt "$min_required" ]; then
    log_error "Insufficient disk space!"
    log_error "Required: ${min_required}GB, Available: ${AVAILABLE_DISK}GB"
    exit 1
  fi
  log_success "Disk space check passed (${AVAILABLE_DISK}GB available)"
}

check_memory() {
  if [ "$TOTAL_MEM" -lt 2048 ]; then
    log_error "Insufficient memory!"
    log_error "Required: 2GB minimum, Available: ${TOTAL_MEM}MB"
    exit 1
  fi
  if [ "$TOTAL_MEM" -lt 4096 ]; then
    log_warn "Memory below recommended threshold (${TOTAL_MEM}MB, 4GB recommended)"
  fi
  log_success "Memory check passed (${TOTAL_MEM}MB available)"
}

check_dependencies() {
  local deps=(git wget curl make gcc g++ python3 python3-pip cmake ninja-build pkg-config)
  local missing=()
  
  for dep in "${deps[@]}"; do
    if ! command -v "$dep" &> /dev/null; then
      missing+=("$dep")
    fi
  done
  
  if [ ${#missing[@]} -gt 0 ]; then
    log_warn "Missing dependencies: ${missing[*]}"
    return 1
  fi
  log_success "All required dependencies installed"
  return 0
}

detect_os() {
  case "${OS_ID}" in
    ubuntu|debian)
      log_info "Detected: ${OS_ID} ${OS_VERSION_ID}"
      return 0
      ;;
    linuxmint)
      log_info "Detected: Linux Mint ${OS_VERSION_ID}"
      return 0
      ;;
    pop)
      log_info "Detected: Pop!_OS ${OS_VERSION_ID}"
      return 0
      ;;
    *)
      log_warn "Unsupported OS: ${OS_ID}"
      return 1
      ;;
  esac
}

install_dependencies() {
  log_info "Installing build dependencies..."
  
  if ! command -v apt-get &> /dev/null; then
    log_error "apt-get not found. Only Debian/Ubuntu based systems are supported."
    exit 1
  fi
  
  sudo -E apt-get -qq update || true
  sudo -E apt-get -qq install -y \
    build-essential clang flex bison gawk gcc g++ gettext git \
    libncurses5-dev libssl-dev libfuse-dev pkg-config \
    python3 python3-pip python3-setuptools python3-pyelftools \
    rsync unzip wget curl cmake ninja-build ccache \
    jq qemu-utils aria2 rename file \
    llvm libelf-dev device-tree-compiler libgmp3-dev libmpc-dev dwarves \
    swig zlib1g-dev libffi-dev || true
  
  sudo -E apt-get -qq autoremove --purge || true
  sudo -E apt-get -qq clean || true
  
  log_success "Build dependencies installed"
}

# ===== Git functions =====

git_clone_with_retry() {
  local url="$1"
  local branch="$2"
  local target="$3"
  local max_retries=3
  local retry=0
  
  while [ $retry -lt $max_retries ]; do
    log_progress "Cloning $url (branch: $branch) [attempt $((retry+1))/$max_retries]"
    if git clone --depth 1 "$url" -b "$branch" "$target" 2>&1; then
      log_success "Successfully cloned $url"
      return 0
    fi
    retry=$((retry + 1))
    if [ $retry -lt $max_retries ]; then
      sleep $((retry * 5))
    fi
  done
  
  log_error "Failed to clone $url after $max_retries attempts"
  return 1
}

git_update_or_clone() {
  local url="$1"
  local branch="$2"
  local target="$3"
  
  if [ -d "$target/.git" ]; then
    log_progress "Updating $target"
    cd "$target" || return 1
    git fetch origin || return 1
    git checkout "$branch" || return 1
    git pull origin "$branch" 2>&1 || log_warn "Git pull warning"
    cd - || return 1
    log_success "Updated $target"
  else
    log_progress "Cloning $url to $target"
    git_clone_with_retry "$url" "$branch" "$target" || return 1
  fi
  return 0
}

# ===== File functions =====

mkdir_safe() {
  mkdir -p "$@" 2>/dev/null || true
}

rm_safe() {
  rm -rf "$@" 2>/dev/null || true
}

cp_safe() {
  cp -f "$@" 2>/dev/null || true
}

# ===== Build functions =====

make_download() {
  local workdir="$1"
  local max_retries=3
  local retry=0
  
  [ ! -d "$workdir" ] && return 1
  
  cd "$workdir" || return 1
  
  while [ $retry -lt $max_retries ]; do
    log_progress "Running make download [attempt $((retry+1))/$max_retries]"
    if make download -j$((NPROC+1)) 2>&1; then
      # Remove incomplete files
      find dl -size -1024c -exec rm -f {} \; 2>/dev/null || true
      cd - || return 1
      log_success "Package download completed"
      return 0
    fi
    retry=$((retry + 1))
    if [ $retry -lt $max_retries ]; then
      sleep $((retry * 10))
    fi
  done
  
  cd - || return 1
  log_error "Failed to download packages after $max_retries attempts"
  return 1
}

make_compile() {
  local workdir="$1"
  
  [ ! -d "$workdir" ] && return 1
  
  cd "$workdir" || return 1
  
  log_progress "Compiling with $NPROC threads"
  if make -j"$NPROC" V=s 2>&1; then
    cd - || return 1
    log_success "Compilation completed successfully"
    return 0
  else
    log_warn "Parallel compilation failed, retrying with single thread"
    if make -j1 V=s 2>&1; then
      cd - || return 1
      log_success "Single-threaded compilation completed"
      return 0
    fi
  fi
  
  cd - || return 1
  log_error "Compilation failed"
  return 1
}

get_device_name() {
  local config_file="$1"
  
  if [ ! -f "$config_file" ]; then
    return 1
  fi
  
  grep '^CONFIG_TARGET.*DEVICE.*=y' "$config_file" 2>/dev/null | \
    sed -r 's/.*DEVICE_(.*)=y/\1/' || echo ""
}

# ===== Artifact functions =====

organize_artifacts() {
  local target_dir="$1"
  local output_dir="$2"
  
  [ ! -d "$target_dir" ] && return 1
  [ ! -d "$output_dir" ] && mkdir -p "$output_dir"
  
  if [ -d "$target_dir/bin/targets" ]; then
    cd "$target_dir/bin/targets" || return 1
    for dir in */*/; do
      if [ -d "$dir" ]; then
        log_progress "Processing firmware from $dir"
        cd "$dir" || continue
        
        # Remove packages directory
        rm_safe packages
        
        # Remove build metadata
        rm_safe config.buildinfo feeds.buildinfo profiles.json version.buildinfo
        
        # Copy firmware files
        cp_safe * "$output_dir/" 2>/dev/null || true
        
        cd - || continue
      fi
    done
    cd - || return 1
  fi
  
  log_success "Artifacts organized to $output_dir"
  return 0
}

generate_sha256() {
  local firmware_dir="$1"
  local output_file="$2"
  
  [ ! -d "$firmware_dir" ] && return 1
  
  if command -v sha256sum &> /dev/null; then
    cd "$firmware_dir" || return 1
    sha256sum * > "$output_file" 2>/dev/null || true
    cd - || return 1
    log_success "SHA256 checksums generated"
  fi
}

generate_manifest() {
  local firmware_dir="$1"
  local output_file="$2"
  
  [ ! -d "$firmware_dir" ] && return 1
  
  {
    echo "Build Date: $(date)"
    echo "Build User: ${BUILD_USER}"
    echo "Build Target: ${TARGET_MATRIX}"
    echo "Golang Version: ${GOLANG_VERSON}"
    echo ""
    echo "Files:"
    ls -lh "$firmware_dir"/
  } > "$output_file"
  
  log_success "Manifest generated"
}

# ===== Cache functions =====

setup_ccache() {
  local ccache_dir="$1"
  mkdir_safe "$ccache_dir"
  
  export CCACHE_DIR="$ccache_dir"
  export USE_CCACHE=1
  
  if command -v ccache &> /dev/null; then
    ccache --max-size=5G 2>/dev/null || true
    log_success "ccache configured"
  fi
}

# ===== Symbolic links =====

setup_mount_links() {
  local target="$1"
  
  # Create directories
  mkdir_safe "${target}/dl"
  mkdir_safe "${target}/bin"
  mkdir_safe "${target}/staging_dir"
  
  log_info "Mount links setup for $target"
}
