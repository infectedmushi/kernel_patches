#!/usr/bin/env bash
# Enhanced Kernel Build Script (v5.1 - Fixed build prompt)
# - KernelSU (main) integration
# - SuSFS patches for android14-6.1
# - Git clean + Build clean prompts work correctly

set -euo pipefail

# ---------- Colors ----------
RED="\e[31m"; GREEN="\e[32m"; YELLOW="\e[33m"; BLUE="\e[34m"; ENDCOLOR="\e[0m"
bold=$(tput bold 2>/dev/null || true); normal=$(tput sgr0 2>/dev/null || true)

# ---------- Logging ----------
ts() { date +"%Y%m%d-%H%M"; }
ts_utc() { TZ=UTC date -u +"%Y%m%dT%H%MZ"; }
ts_date() { TZ=UTC date -u +"%Y%m%d"; }
log_info()    { echo -e "${GREEN}${bold}[INFO]${normal} $*${ENDCOLOR}"; }
log_warn()    { echo -e "${YELLOW}${bold}[WARN]${normal} $*${ENDCOLOR}"; }
log_error()   { echo -e "${RED}${bold}[ERROR]${normal} $*${ENDCOLOR}"; }
log_step()    { echo -e "${BLUE}${bold}==>${normal} $*${ENDCOLOR}"; }

START_EPOCH=$(date +%s)
trap 'rc=$?; end=$(date +%s); dur=$((end-START_EPOCH)); [[ $rc -eq 0 ]] || log_error "Exited with code $rc after ${dur}s"; exit $rc' EXIT

# ---------- Defaults (env-overridable) ----------
: "${PIXEL8A:=y}"
: "${LTO_TYPE:=thin}"
: "${ZIP_PREFIX:=AK3-A14-6.1.155-MKSU}"
: "${CLANG_PATH:=/mnt/Android/clang-22/bin}"
: "${ARM64_TOOLCHAIN:=/mnt/Hawai/toolchains/arm-gnu-toolchain-14.3.rel1-x86_64-aarch64-none-linux-gnu/bin/aarch64-none-linux-gnu-}"
: "${ARM32_TOOLCHAIN:=/mnt/Hawai/toolchains/arm-gnu-toolchain-14.3.rel1-x86_64-arm-none-eabi/bin/arm-none-eabi-}"
: "${KERNEL_DIR:=common}"
: "${CONFIG_FILE:=arch/arm64/configs/gki_defconfig}"
: "${OUT_DIR:=out}"
: "${RESET_COMMIT:=f090d4b08}"
: "${THREADS:=$(nproc)}"
: "${RETRY:=3}"
: "${REPO_DEPTH:=1}"
: "${KSUN_BRANCH:=main}"
: "${ANYKERNEL_DIR:=AnyKernel3-p8a}"
: "${ANYKERNEL_BRANCH:=KernelSU}"
: "${SUSFS_REPO:=https://gitlab.com/simonpunk/susfs4ksu.git}"
: "${SUSFS_BRANCH:=gki-android14-6.1-dev}"
: "${PATCHES_REPO:=https://github.com/infectedmushi/kernel_patches}"
: "${PATCHES_BRANCH:=main}"
: "${BUILDS_DIR:=builds/6.1.155}"
: "${LOCALVERSION:=-deepongi}"

export USE_CCACHE="${USE_CCACHE:-1}"
export CCACHE_DIR="${CCACHE_DIR:-/mnt/ccache/.ccache}"
export LLVM_CACHE_PATH="${LLVM_CACHE_PATH:-$HOME/.cache/llvm}"

# ---------- Helpers ----------
cmd_exists() { command -v "$1" &>/dev/null; }
retry() { local n=0; local max=$1; shift; until "$@"; do n=$((n+1)); (( n>=max )) && return 1; sleep $((n)); done; }

git_clone_or_update() {
  local url=$1 dir=$2 branch=$3 depth=$4
  if [[ -d "$dir/.git" ]]; then
    log_info "Updating $dir"
    (cd "$dir" && git fetch --all --prune && git checkout "$branch" && git reset --hard "origin/$branch") || return 1
  else
    local depth_args=()
    [[ "${depth}" != "0" ]] && depth_args=(--depth "$depth")
    retry "$RETRY" git clone "${depth_args[@]}" -b "$branch" "$url" "$dir" || return 1
  fi
}

append_unique_cfg() {
  local file=$1 line=$2
  grep -q -E "^${line//\//\\/}$" "$file" 2>/dev/null || printf "%s\n" "$line" >> "$file"
}

set_cfg_toggle() {
  local file=$1 key=$2 val=$3
  sed -i -E "/^#?\s*${key}=.*/d" "$file" 2>/dev/null || true
  case "$val" in
    y|n) printf "%s=%s\n" "$key" "$([ "$val" = y ] && echo y || echo n)" >> "$file" ;;
    \"*\"|\'*\') printf "%s=%s\n" "$key" "$val" >> "$file" ;;
    *) printf "%s=\"%s\"\n" "$key" "$val" >> "$file" ;;
  esac
}

apply_patch_forward() {
  local patch_file=$1
  if patch -p1 --dry-run --forward < "$patch_file" &>/dev/null; then
    patch -p1 -ui "$patch_file"
    log_info "Applied patch: $patch_file"
  else
    log_warn "Patch likely already applied or context mismatch: $patch_file"
  fi
}

get_kernelsu_version_from_build() {
  local out_dir="${1:-.}"
  local version=""
  
  if [[ -f "$out_dir/.build_log" ]]; then
    version=$(grep "-- KernelSU version:" "$out_dir/.build_log" 2>/dev/null | tail -1 | sed 's/.*-- KernelSU version: //g' | tr -d '[:space:]' | grep -oE '^[0-9]+$' || true)
    if [[ -n "$version" ]]; then
      printf "r%s" "$version"
      return 0
    fi
  fi
  
  return 1
}

get_kernelsu_version_from_git() {
  local ksu_dir="${1:-.}"
  local version=""
  
  if [[ -d "$ksu_dir/.git" ]]; then
    version=$(cd "$ksu_dir" 2>/dev/null && git rev-list --count HEAD 2>/dev/null || true)
    if [[ -n "$version" && "$version" =~ ^[0-9]+$ ]]; then
      printf "r%s" "$version"
      return 0
    fi
  fi
  
  return 1
}

prompt_release_number() {
  local release_num
  echo -e "${YELLOW}Enter release number (e.g., r22122, v1.0):${ENDCOLOR}" >&2
  read -r release_num
  
  if [[ -z "$release_num" ]]; then
    log_error "Release number cannot be empty"
    exit 1
  fi
  
  if ! [[ "$release_num" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    log_error "Invalid release number format. Use only alphanumeric characters, dashes, or underscores"
    exit 1
  fi
  
  printf "%s" "$release_num"
}

# ---------- Validate tools ----------
validate_requirements() {
  log_step "Validating requirements"
  local tools=(git make clang zip patch curl sed grep awk ccache)
  local missing=()
  for t in "${tools[@]}"; do cmd_exists "$t" || missing+=("$t"); done
  [[ ${#missing[@]} -eq 0 ]] || { log_error "Missing tools: ${missing[*]}"; exit 1; }
  [[ -d "$CLANG_PATH" ]] || { log_error "Clang path not found: $CLANG_PATH"; exit 1; }
  export PATH="$CLANG_PATH:$PATH"
  clang --version | head -n1 || { log_error "clang not runnable"; exit 1; }
  log_info "ccache: $(ccache -V | head -n1 || echo disabled)"
}

# ---------- Repos ----------
setup_repositories() {
  log_step "Setting up repositories"

  if [[ -d "susfs4ksu/.git" ]]; then
    log_info "Updating susfs4ksu"
    (cd susfs4ksu && git fetch --all --prune && git checkout "$SUSFS_BRANCH" && git reset --hard "origin/$SUSFS_BRANCH")
  else
    retry "$RETRY" git clone ${REPO_DEPTH:+--depth "$REPO_DEPTH"} -b "$SUSFS_BRANCH" "$SUSFS_REPO" susfs4ksu
  fi

  if [[ -d "$ANYKERNEL_DIR/.git" ]]; then
    log_info "Updating $ANYKERNEL_DIR"
    (cd "$ANYKERNEL_DIR" && git fetch --all --prune && git checkout "$ANYKERNEL_BRANCH" && git reset --hard "origin/$ANYKERNEL_BRANCH")
  else
    if [[ -d "$ANYKERNEL_DIR" ]]; then
      log_warn "$ANYKERNEL_DIR exists without .git; removing"
      rm -rf "$ANYKERNEL_DIR"
    fi
    retry "$RETRY" git clone ${REPO_DEPTH:+--depth "$REPO_DEPTH"} -b "$ANYKERNEL_BRANCH" "https://github.com/deepongi-labs/${ANYKERNEL_DIR}" "$ANYKERNEL_DIR"
  fi

  if [[ -d "kernel_patches/.git" ]]; then
    log_info "Updating kernel_patches"
    (cd kernel_patches && git fetch --all --prune && git checkout "$PATCHES_BRANCH" && git reset --hard "origin/$PATCHES_BRANCH")
  else
    retry "$RETRY" git clone ${REPO_DEPTH:+--depth "$REPO_DEPTH"} -b "$PATCHES_BRANCH" "$PATCHES_REPO" kernel_patches
  fi

  log_info "Repositories ready"
}

# ---------- Compiler ----------
setup_compiler() {
  log_step "Setting up compiler"
  export PATH="$CLANG_PATH:$PATH"
  cmd_exists clang || { log_error "clang not found in PATH"; exit 1; }
  log_info "Using $(clang --version | head -n1)"
}

# ---------- User prompts BEFORE kernel operations ----------
prompt_build_options() {
  log_step "Build options"
  
  # Git source preparation
  echo -e "${YELLOW}Git source preparation:${ENDCOLOR}" >&2
  echo "  1) Clean (git clean + git reset + remove KernelSU) - Fresh code" >&2
  echo "  2) Skip clean (keep modifications)" >&2
  echo -e "${YELLOW}Enter choice (1 or 2):${ENDCOLOR} " >&2
  read -r GIT_CLEAN
  
  if ! [[ "$GIT_CLEAN" =~ ^[12]$ ]]; then
    log_error "Invalid choice. Use 1 or 2"
    prompt_build_options
    return
  fi
  
  # Build directory cleanup
  if [[ -d "$KERNEL_DIR/$OUT_DIR" ]]; then
    echo ""
    log_step "Build directory cleanup"
    echo -e "${YELLOW}OUT_DIR exists: $KERNEL_DIR/$OUT_DIR${ENDCOLOR}" >&2
    echo "  1) Clean (rm -rf out) - Full rebuild" >&2
    echo "  2) Resume (keep out dir) - Continue from last build" >&2
    echo -e "${YELLOW}Enter choice (1 or 2):${ENDCOLOR} " >&2
    read -r BUILD_CLEAN
    
    if ! [[ "$BUILD_CLEAN" =~ ^[12]$ ]]; then
      log_error "Invalid choice. Use 1 or 2"
      prompt_build_options
      return
    fi
  else
    log_info "No existing build directory"
    BUILD_CLEAN="1"
  fi
}

# ---------- Kernel source ----------
prepare_kernel_source() {
  log_step "Preparing kernel source"
  [[ -d "$KERNEL_DIR" ]] || { log_error "Kernel directory not found: $KERNEL_DIR"; exit 1; }
  
  cd "$KERNEL_DIR"
  
  # Apply user's choice
  if [[ "$GIT_CLEAN" == "1" ]]; then
    log_info "Cleaning git source"
    git clean -fdx || log_warn "git clean failed"
    git reset --hard "$RESET_COMMIT" || { log_error "Failed reset to $RESET_COMMIT"; exit 1; }
    rm -rf KernelSU || true
    log_info "Source cleaned and reset to $RESET_COMMIT"
  else
    log_info "Skipping source clean (keeping modifications)"
    rm -rf KernelSU || true
    log_info "Removed KernelSU only"
  fi
  
  # Apply build directory cleanup
  if [[ "$BUILD_CLEAN" == "1" ]] && [[ -d "$OUT_DIR" ]]; then
    log_info "Cleaning build directory"
    rm -rf "$OUT_DIR"
  elif [[ "$BUILD_CLEAN" == "2" ]]; then
    log_info "Resuming from existing build directory"
  fi
  
  mkdir -p "$OUT_DIR"
}

# ---------- Device config ----------
configure_pixel8a() {
  if [[ "${PIXEL8A,,}" != "y" ]]; then
    log_info "Skipping Pixel 8a config"
    return
  fi
  log_step "Configuring Pixel 8a (Tensor G3)"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_ARM64_CORTEX_X3=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_ARM64_CORTEX_A715=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_ARM64_CORTEX_A510=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_ARM64_VA_BITS=48"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_ARM64_PA_BITS=48"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_ARM64_TAGGED_ADDR_ABI=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_ARM64_SVE=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_ARM64_BTI=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_ARM64_PTR_AUTH=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_SCHED_MC=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_SCHED_CORE=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_ENERGY_MODEL=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_UCLAMP_TASK=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_UCLAMP_TASK_GROUP=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_SCHEDUTIL=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_CPU_FREQ=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_CPUFREQ_DT=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_CPU_FREQ_GOV_SCHEDUTIL=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_CPU_FREQ_DEFAULT_GOV_SCHEDUTIL=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_OPP=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_CPU_IDLE=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_ARM_PSCI_CPUIDLE=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_THERMAL=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_CPU_THERMAL=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_DEVFREQ_THERMAL=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_THERMAL_GOV_POWER_ALLOCATOR=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_THERMAL_GOV_STEP_WISE=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_THERMAL_GOV_FAIR_SHARE=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_THERMAL_EMULATION=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_THERMAL_WRITABLE_TRIPS=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_POWER_CAP=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_PERF_EVENTS=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_ARM64_SME=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_NUMA_BALANCING=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_CMA=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_CMA_AREAS=7"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_TCP_CONG_ADVANCED=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_TCP_CONG_CUBIC=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_NET_SCH_FQ_CODEL=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_DEFAULT_FQ_CODEL=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_NET_SCH_CAKE=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_DEFAULT_CAKE=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_DEFAULT_TCP_CONG=\"bbr\""
  append_unique_cfg "$CONFIG_FILE" "CONFIG_F2FS_FS=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_F2FS_FS_XATTR=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_F2FS_FS_POSIX_ACL=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_F2FS_FS_SECURITY=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_F2FS_FS_COMPRESSION=y"
  log_info "Pixel 8a configuration done"
}

# ---------- LTO ----------
configure_lto() {
  log_step "Configuring LTO: $LTO_TYPE"
  sed -i -E '/^CONFIG_LTO_(CLANG_(FULL|THIN)|NONE)=/d' "$CONFIG_FILE" 2>/dev/null || true
  case "${LTO_TYPE}" in
    full) append_unique_cfg "$CONFIG_FILE" "CONFIG_LTO_CLANG_FULL=y" ;;
    thin) append_unique_cfg "$CONFIG_FILE" "CONFIG_LTO_CLANG_THIN=y" ;;
    none) append_unique_cfg "$CONFIG_FILE" "CONFIG_LTO_NONE=y" ;;
    *) log_error "Invalid LTO_TYPE: $LTO_TYPE"; exit 1 ;;
  esac
  log_info "LTO set"
}

# ---------- KernelSU ----------
install_kernelsu() {
  log_step "Installing KernelSU ($KSUN_BRANCH)"
  retry "$RETRY" bash -c \
    "curl -LSs https://raw.githubusercontent.com/5ec1cff/KernelSU/refs/heads/${KSUN_BRANCH}/kernel/setup.sh | bash -s ${KSUN_BRANCH}"
  log_info "KernelSU installed"
}

# ---------- Baseband-guard (BBG) ----------
add_bbg() {
  log_step "Adding BBG (Baseband-guard)"
  [[ -f "Makefile" && -d "security" ]] || { log_error "Not in kernel top-level; cannot add BBG"; exit 1; }
  if ! curl -LSs https://raw.githubusercontent.com/vc-teahouse/Baseband-guard/main/setup.sh | bash; then
    log_error "BBG setup failed"; exit 1
  fi
  if ! grep -q "^CONFIG_BBG=y$" "$CONFIG_FILE"; then
    echo "CONFIG_BBG=y" >> "$CONFIG_FILE"
    log_info "Enabled CONFIG_BBG in $CONFIG_FILE"
  else
    log_warn "CONFIG_BBG already enabled in $CONFIG_FILE"
  fi
  local kcfg="security/Kconfig"
  if [[ -f "$kcfg" ]]; then
    if ! awk '/^config LSM$/{f=1} f && /^help$/{f=0} f && /default/ && /baseband_guard/{found=1} END{exit !found}' "$kcfg"; then
      sed -i '/^config LSM$/,/^help$/{
        /^[[:space:]]*default/ {
          /baseband_guard/! s/\<landlock\>/landlock,baseband_guard/
        }
      }' "$kcfg"
      log_info "Added baseband_guard to LSM default in $kcfg"
    else
      log_warn "baseband_guard already present in LSM default"
    fi
  else
    log_warn "security/Kconfig not found; skipping LSM default update"
  fi
}

# ---------- SUSFS patches ----------
apply_susfs_patches() {
  log_step "Applying SUSFS patches"
  
  cp -fv ../susfs4ksu/kernel_patches/50_add_susfs_in_gki-android14-6.1.patch ./
  cp -fv ../fix-clidr-uninitialized.patch ./
  cp -fv ../fix_proc_base.patch ./
  mkdir -p fs include/linux
  cp -fv ../susfs4ksu/kernel_patches/fs/* ./fs/ || true
  cp -fv ../susfs4ksu/kernel_patches/include/linux/* ./include/linux/ || true
  
  log_info "Applying 50_add_susfs_in_gki-android14-6.1.patch"
  patch -p1 -f < 50_add_susfs_in_gki-android14-6.1.patch || log_warn "Patch 50 encountered issues, continuing"
  
  rm -f fs/proc/base.c.rej fs/proc/base.c.orig
  
  log_info "Applying targeted fix for fs/proc/base.c"
  apply_patch_forward fix_proc_base.patch || log_warn "fix_proc_base patch apply failed"
  
  log_info "Applying 10_enable_susfs_for_ksu.patch"
  cp -fv ../10_enable_susfs_for_ksu.patch ./
  (cd KernelSU && patch -p1 -f -ui ../10_enable_susfs_for_ksu.patch) || log_warn "KernelSU patch apply failed"
  

  apply_patch_forward fix-clidr-uninitialized.patch || true
  log_info "SUSFS patches synced"
}

# ---------- Kernel config ----------
configure_kernel() {
  log_step "Tuning kernel config"

  if compgen -G "android/abi_gki_protected_exports_*" > /dev/null; then
    rm -f android/abi_gki_protected_exports_*
  fi

  set_cfg_toggle "$CONFIG_FILE" "CONFIG_LOCALVERSION_AUTO" n
  set_cfg_toggle "$CONFIG_FILE" "CONFIG_LOCALVERSION" "\"$LOCALVERSION\""

  append_unique_cfg "$CONFIG_FILE" "CONFIG_KSU=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_KSU_KPROBES_HOOK=n"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_KSU_DEBUG=n"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_KSU_THRONE_TRACKER_ALWAYS_THREADED=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_KSU_ALLOWLIST_WORKAROUND=n"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_KSU_LSM_SECURITY_HOOKS=y"

  append_unique_cfg "$CONFIG_FILE" "CONFIG_KSU_SUSFS=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_KSU_SUSFS_SUS_PATH=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_KSU_SUSFS_SUS_MOUNT=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_KSU_SUSFS_AUTO_ADD_SUS_KSU_DEFAULT_MOUNT=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_KSU_SUSFS_AUTO_ADD_SUS_BIND_MOUNT=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_KSU_SUSFS_SUS_KSTAT=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_KSU_SUSFS_TRY_UMOUNT=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_KSU_SUSFS_AUTO_ADD_TRY_UMOUNT_FOR_BIND_MOUNT=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_KSU_SUSFS_SPOOF_UNAME=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_KSU_SUSFS_ENABLE_LOG=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_KSU_SUSFS_OPEN_REDIRECT=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_KSU_SUSFS_SUS_SU=n"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_KSU_SUSFS_SUS_MAP=y"

  append_unique_cfg "$CONFIG_FILE" "CONFIG_TMPFS_XATTR=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_TMPFS_POSIX_ACL=y"

  append_unique_cfg "$CONFIG_FILE" "CONFIG_IP_NF_TARGET_TTL=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_IP6_NF_TARGET_HL=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_IP6_NF_MATCH_HL=y"

  append_unique_cfg "$CONFIG_FILE" "CONFIG_TCP_CONG_ADVANCED=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_TCP_CONG_BBR=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_NET_SCH_FQ=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_TCP_CONG_BIC=n"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_TCP_CONG_WESTWOOD=n"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_TCP_CONG_HTCP=n"

  append_unique_cfg "$CONFIG_FILE" "CONFIG_IP_SET=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_IP_SET_MAX=256"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_IP_SET_BITMAP_IP=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_IP_SET_BITMAP_IPMAC=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_IP_SET_BITMAP_PORT=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_IP_SET_HASH_IP=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_IP_SET_HASH_IPPORT=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_IP_SET_HASH_IPPORTIP=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_IP_SET_HASH_IPPORTNET=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_IP_SET_HASH_NET=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_IP_SET_HASH_NETNET=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_IP_SET_HASH_NETPORT=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_IP_SET_HASH_NETIFACE=y"

  append_unique_cfg "$CONFIG_FILE" "CONFIG_CC_OPTIMIZE_FOR_PERFORMANCE=y"
  append_unique_cfg "$CONFIG_FILE" "CONFIG_CCACHE=y"

  log_info "Kernel config updated"
}

# ---------- Compile ----------
compile_kernel() {
  log_step "Compiling kernel"
  local start=$(date +%s)
  
  time make -j"$THREADS" \
    LLVM_IAS=1 \
    LLVM=1 \
    ARCH=arm64 \
    CLANG_TRIPLE=aarch64-linux-gnu- \
    CROSS_COMPILE_COMPAT="$ARM32_TOOLCHAIN" \
    CROSS_COMPILE="$ARM64_TOOLCHAIN" \
    CC="ccache clang" \
    LD=ld.lld \
    HOSTLD=ld.lld \
    O="$OUT_DIR" \
    gki_defconfig all 2>&1 | tee "$OUT_DIR/.build_log"

  local end=$(date +%s); log_info "Compiled in $((end-start))s"
  [[ -f "$OUT_DIR/arch/arm64/boot/Image" ]] || { log_error "Image missing"; exit 1; }
}

# ---------- Package ----------
package_kernel() {
  log_step "Packaging"
  cd ..
  local image="$KERNEL_DIR/$OUT_DIR/arch/arm64/boot/Image"
  [[ -f "$image" ]] || { log_error "Kernel image not found: $image"; exit 1; }

  cp -fv "$image" "$ANYKERNEL_DIR"/
  (cd "$ANYKERNEL_DIR"; rm -rf .git; )

  # Get version - NO logging during detection!
  local release_num=""
  if release_num=$(get_kernelsu_version_from_build "$KERNEL_DIR/$OUT_DIR" 2>/dev/null); then
    log_info "Extracted KernelSU version from build: $release_num"
  elif release_num=$(get_kernelsu_version_from_git "$(pwd)/KernelSU" 2>/dev/null); then
    log_info "Extracted KernelSU version from git: $release_num"
  else
    log_step "Could not auto-detect version"
    release_num="$(prompt_release_number)"
    log_info "Using release number: $release_num"
  fi
  
  # Build filename with clean version
  local date_str="$(ts_date)"
  local BUILD_LABEL="${date_str}-${release_num}"
  local zip_name="${ZIP_PREFIX}-${BUILD_LABEL}.zip"
  
  log_info "Creating zip: $zip_name"
  (cd "$ANYKERNEL_DIR" && zip -r "../$zip_name" ./*)

  mkdir -p "$BUILDS_DIR"
  mv -v "$zip_name" "$BUILDS_DIR"/
  rm -f "$ANYKERNEL_DIR/Image"
  log_info "Output: $BUILDS_DIR/$zip_name"
}

main() {
  log_step "Start"
  validate_requirements
  setup_repositories
  setup_compiler
  prompt_build_options
  prepare_kernel_source
  configure_pixel8a
  configure_lto
  install_kernelsu
  add_bbg
  apply_susfs_patches
  configure_kernel
  # Remove old prepare_build() call
  # prepare_build is now merged into prepare_kernel_source()
  compile_kernel
  package_kernel
  log_info "Build completed 🎉"
}

main "$@"
