#!/usr/bin/env bash


clear
echo ""
echo "   ______           _            ______            "
echo "   | ___ \         | |           | ___ \           "
echo "   | |_/ / ___  ___| | _____ _ __| |_/ / _____  __ "
echo "   | ___ \/ _ \/ __| |/ / _ \ '__| ___ \/ _ \ \/ / "
echo "   | |_/ /  __/ (__|   <  __/ |  | |_/ / (_) >  <  "
echo "   \____/ \___|\___|_|\_\___|_|  \____/ \___/_/\_\ "
echo ""
echo "  Dolphin Emulator — macOS toolchain setup in a virtual environment"
echo "  This script installs everything needed to build Dolphin on macOS"
echo "  WITHOUT admin/sudo at any point."
echo ""




# ============================================================
#  setup-dolphin-toolchain.sh
#  Installs everything needed to build Dolphin on macOS
#  WITHOUT admin/sudo at any point.
#
#  What it does:
#    1. Finds a usable clang (bypasses the Xcode license shim)
#       OR downloads a standalone LLVM as a fallback
#    2. Installs Miniforge (user-space conda) for cmake, git,s
#       ninja, and pkg-config
#    3. Writes ~/dolphin-toolchain/activate.sh — source this
#       before every build session
#
#  Usage:
#    chmod +x setup-dolphin-toolchain.sh
#    ./setup-dolphin-toolchain.sh
# ============================================================
set -euo pipefail

# ── Directories ──────────────────────────────────────────────
TOOLCHAIN_DIR="${HOME}/dolphin-toolchain"
MINIFORGE_DIR="${TOOLCHAIN_DIR}/miniforge3"
LLVM_DIR="${TOOLCHAIN_DIR}/llvm"
ARCH=$(uname -m)   # arm64 or x86_64

# ── Colours / helpers ────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; RESET='\033[0m'

info()  { printf "${BLUE}[INFO]${RESET}  %s\n" "$*"; }
ok()    { printf "${GREEN}[OK]${RESET}    %s\n" "$*"; }
warn()  { printf "${YELLOW}[WARN]${RESET}  %s\n" "$*"; }
die()   { printf "${RED}[ERR]${RESET}   %s\n" "$*" >&2; exit 1; }
banner(){ printf "\n${BOLD}──── %s ────${RESET}\n" "$*"; }

mkdir -p "${TOOLCHAIN_DIR}"

# ════════════════════════════════════════════════════════════
# STEP 1 — Find a usable C/C++ compiler
# The Xcode license error is injected by the /usr/bin/clang
# SHIM (via xcrun).  The real CLT binary sits directly in
# /Library/Developer/CommandLineTools/usr/bin/ and does NOT
# check the license.  We try that first.
# ════════════════════════════════════════════════════════════
banner "Step 1: Locate C/C++ compiler"

CLT_CLANG="/Library/Developer/CommandLineTools/usr/bin/clang"
XCODE_CLANG="/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang"

CLANG_BIN=""      # will hold the *directory* containing clang/clang++
SDK_FLAG=""       # will hold -isysroot ... if needed

try_clang() {
    local candidate="$1"
    if [ -x "${candidate}" ] && "${candidate}" --version &>/dev/null; then
        CLANG_BIN="$(dirname "${candidate}")"
        ok "Usable clang found: ${candidate}"
        return 0
    fi
    return 1
}

try_clang "${CLT_CLANG}" \
|| try_clang "${XCODE_CLANG}" \
|| {
    # ── Fallback: download standalone LLVM ───────────────────
    warn "No direct CLT clang found. Downloading standalone LLVM (~300 MB)."

    if [ ! -d "${LLVM_DIR}/bin" ]; then
        info "Querying GitHub for the latest LLVM release..."
        RELEASE_JSON=$(curl -fsSL "https://api.github.com/repos/llvm/llvm-project/releases/latest") \
            || die "Could not reach GitHub API. Check your internet connection."

        # Pick the right asset for this architecture
        if [ "${ARCH}" = "arm64" ]; then
            PATTERN="arm64-apple-darwin"
        else
            PATTERN="x86_64-apple-darwin"
        fi

        LLVM_URL=$(
            printf '%s' "${RELEASE_JSON}" \
            | grep '"browser_download_url"' \
            | grep "clang+llvm" \
            | grep "${PATTERN}" \
            | grep '\.tar\.xz"' \
            | head -1 \
            | grep -o 'https://[^"]*'
        )

        [ -n "${LLVM_URL}" ] || die \
            "Could not parse LLVM download URL for ${ARCH}.\n" \
            "Visit https://github.com/llvm/llvm-project/releases and download manually."

        LLVM_TARBALL="${TOOLCHAIN_DIR}/llvm.tar.xz"
        info "Downloading: ${LLVM_URL}"
        curl -L --progress-bar "${LLVM_URL}" -o "${LLVM_TARBALL}"

        info "Extracting LLVM (this may take a minute)..."
        mkdir -p "${LLVM_DIR}"
        tar -xf "${LLVM_TARBALL}" --strip-components=1 -C "${LLVM_DIR}"
        rm -f "${LLVM_TARBALL}"
        ok "LLVM installed to ${LLVM_DIR}"
    else
        ok "LLVM already present at ${LLVM_DIR}"
    fi

    CLANG_BIN="${LLVM_DIR}/bin"

    # Standalone LLVM needs the macOS SDK for system headers.
    # The CLT SDK is present on disk even when the license isn't accepted.
    SDK_PATH=""
    # Try the generic symlink first, then find the newest versioned SDK
    for candidate in \
        "/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk" \
        "$(find /Library/Developer/CommandLineTools/SDKs -maxdepth 1 \
              -name 'MacOSX*.sdk' 2>/dev/null | sort -V | tail -1)"; do
        if [ -d "${candidate}" ]; then
            SDK_PATH="${candidate}"
            break
        fi
    done

    if [ -n "${SDK_PATH}" ]; then
        SDK_FLAG="-isysroot ${SDK_PATH}"
        ok "macOS SDK: ${SDK_PATH}"
    else
        warn "macOS SDK not found. Build may fail on system headers."
        warn "Try: xcode-select --install  (installs CLT without needing admin on most Macs)"
    fi
}

# ════════════════════════════════════════════════════════════
# STEP 2 — Install Miniforge (user-space conda) for cmake,
#           git, ninja, pkg-config
# ════════════════════════════════════════════════════════════
banner "Step 2: Install Miniforge (user-space package manager)"

if [ ! -d "${MINIFORGE_DIR}" ]; then
    if [ "${ARCH}" = "arm64" ]; then
        MF_URL="https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-MacOSX-arm64.sh"
    else
        MF_URL="https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-MacOSX-x86_64.sh"
    fi

    info "Downloading Miniforge installer..."
    curl -L --progress-bar "${MF_URL}" -o "${TOOLCHAIN_DIR}/miniforge_installer.sh"
    chmod +x "${TOOLCHAIN_DIR}/miniforge_installer.sh"

    info "Installing Miniforge to ${MINIFORGE_DIR} (no sudo)..."
    # -b = batch/silent, -p = prefix (install location)
    bash "${TOOLCHAIN_DIR}/miniforge_installer.sh" -b -p "${MINIFORGE_DIR}"
    rm -f "${TOOLCHAIN_DIR}/miniforge_installer.sh"
    ok "Miniforge installed."
else
    ok "Miniforge already present at ${MINIFORGE_DIR}"
fi

# Activate conda for the rest of this script
# shellcheck source=/dev/null
source "${MINIFORGE_DIR}/etc/profile.d/conda.sh"
conda activate base

# ════════════════════════════════════════════════════════════
# STEP 3 — Install build tools via conda
# ════════════════════════════════════════════════════════════
banner "Step 3: Install cmake, git, ninja, pkg-config"

info "This may take a few minutes on the first run..."
conda install -y -c conda-forge \
    git \
    cmake \
    ninja \
    pkg-config
ok "Build tools installed."

# ════════════════════════════════════════════════════════════
# STEP 4 — Write activate.sh (source before every build)
# ════════════════════════════════════════════════════════════
banner "Step 4: Writing activate.sh"

ENV_SCRIPT="${TOOLCHAIN_DIR}/activate.sh"

# Use a heredoc with a quoted delimiter so variables in the
# script body are written literally (not expanded now).
cat > "${ENV_SCRIPT}" << 'ACTIVATE_EOF'
#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────
#  Dolphin toolchain — environment activation
#  Source this BEFORE running cmake / ninja:
#    source ~/dolphin-toolchain/activate.sh
# ──────────────────────────────────────────────────────────
ACTIVATE_EOF

# Now append the parts that DO need the variables expanded
cat >> "${ENV_SCRIPT}" << ACTIVATE_EOF
source "${MINIFORGE_DIR}/etc/profile.d/conda.sh"
conda activate base

export PATH="${CLANG_BIN}:${MINIFORGE_DIR}/bin:\${PATH}"
export CC="${CLANG_BIN}/clang"
export CXX="${CLANG_BIN}/clang++"
ACTIVATE_EOF

# Append SDK flag only if we set one
if [ -n "${SDK_FLAG}" ]; then
cat >> "${ENV_SCRIPT}" << ACTIVATE_EOF

# Point standalone LLVM at the macOS SDK
export CFLAGS="${SDK_FLAG} \${CFLAGS:-}"
export CXXFLAGS="${SDK_FLAG} \${CXXFLAGS:-}"
ACTIVATE_EOF
fi

# Append the status printout (literal, so quoted delimiter again)
cat >> "${ENV_SCRIPT}" << 'ACTIVATE_EOF'

echo "✓ Dolphin toolchain active"
echo "  clang  : $(${CC} --version | head -1)"
echo "  cmake  : $(cmake --version | head -1)"
echo "  git    : $(git --version)"
echo "  ninja  : $(ninja --version)"
ACTIVATE_EOF

chmod +x "${ENV_SCRIPT}"
ok "Written: ${ENV_SCRIPT}"

# ════════════════════════════════════════════════════════════
# DONE — Print next steps
# ════════════════════════════════════════════════════════════
printf "\n${BOLD}${GREEN}"
printf "╔══════════════════════════════════════════════════════════╗\n"
printf "║              Toolchain setup complete! 🎉                ║\n"
printf "╚══════════════════════════════════════════════════════════╝\n"
printf "${RESET}\n"
printf "Next steps:\n\n"
printf "  ${BOLD}1. Activate the toolchain (do this in every new shell):${RESET}\n"
printf "     source ~/dolphin-toolchain/activate.sh\n\n"
printf "  ${BOLD}2. Clone Dolphin (submodules are required):${RESET}\n"
printf "     git clone --recurse-submodules https://github.com/dolphin-emu/dolphin.git\n\n"
printf "  ${BOLD}3. Build:${RESET}\n"
printf "     cd dolphin && mkdir build && cd build\n"
printf "     cmake -G Ninja -DCMAKE_C_COMPILER=\"\$CC\" -DCMAKE_CXX_COMPILER=\"\$CXX\" ..\n"
printf "     ninja\n\n"
printf "  The finished app will be at: dolphin/build/Binaries/Dolphin.app\n\n"

banner "Step 5: Activating toolchain"
source "${ENV_SCRIPT}"

CONDA="$HOME/dolphin-toolchain/miniforge3/bin/conda"
SOURCE_DIR="$HOME/becker-dolphin-source"
BUILD_DIR="$SOURCE_DIR/build"





banner "Step 6: Downloading source code"

if [ -d "$SOURCE_DIR" ]; then
    warn "Source directory already exists at ${SOURCE_DIR}"
    warn "If you want a fresh clone, delete that directory and re-run this script."
else
    git clone --recurse-submodules https://github.com/21beckem/becker-dolphin-source.git \
        "$SOURCE_DIR" || die "Failed to clone Dolphin source. Check your internet connection."
    ok "Dolphin source code cloned to ${SOURCE_DIR}"
fi








banner "Step 6: Building Dolphin"

set -e


echo "==> Installing dependencies..."
"$CONDA" install -c conda-forge git cmake ninja pkg-config qt6-main -y

echo "==> Initializing submodules..."
cd "$SOURCE_DIR"
"$HOME/dolphin-toolchain/miniforge3/bin/git" submodule update --init --recursive

echo "==> Creating build directory..."
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

echo "==> Running CMake..."
cmake -G Ninja \
  -DCMAKE_C_COMPILER="/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang" \
  -DCMAKE_CXX_COMPILER="/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang++" \
  -DCMAKE_OSX_SYSROOT="/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk" \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="14.0" \
  -DGIT_EXECUTABLE="$HOME/dolphin-toolchain/miniforge3/bin/git" \
  -DCMAKE_PREFIX_PATH="$HOME/dolphin-toolchain/miniforge3" \
  -DENABLE_VULKAN=OFF \
  ..

echo "==> CMake config done! Run: ninja -C $BUILD_DIR"

banner "Step 7: Making Dolphin"
ninja -C "$BUILD_DIR"

echo ""
echo ""
ok "   Build complete! The app is at: $BUILD_DIR/Binaries/Dolphin.app"
echo ""