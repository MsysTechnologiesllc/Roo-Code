#!/bin/sh
# Roo Code CLI Installer
# Usage: curl -fsSL https://raw.githubusercontent.com/RooCodeInc/Roo-Code/main/apps/cli/install.sh | sh
#
# Environment variables:
#   ROO_INSTALL_DIR   - Installation directory (default: ~/.roo/cli)
#   ROO_BIN_DIR       - Binary symlink directory (default: ~/.local/bin)
#   ROO_VERSION       - Specific version to install (default: latest)
#   ROO_LOCAL_TARBALL - Path to local tarball to install (skips download)
#   ROO_INSTALL_ATLAS - Install/configure Atlas MCP by default (1=true, 0=false)
#   ROO_ATLAS_VERSION - Atlas version to install (default: latest release)
#   ROO_ATLAS_REPO    - Atlas GitHub repo (default: dominic097/atlas)

set -e

# Configuration
INSTALL_DIR="${ROO_INSTALL_DIR:-$HOME/.roo/cli}"
BIN_DIR="${ROO_BIN_DIR:-$HOME/.local/bin}"
REPO="RooCodeInc/Roo-Code"
ATLAS_REPO="${ROO_ATLAS_REPO:-dominic097/atlas}"
ATLAS_SERVER_NAME="${ROO_ATLAS_MCP_SERVER_NAME:-pulse-atlas}"
MIN_NODE_VERSION=20

# Color output (only if terminal supports it)
if [ -t 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    BOLD='\033[1m'
    NC='\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    BOLD=''
    NC=''
fi

info() { printf "${GREEN}==>${NC} %s\n" "$1"; }
warn() { printf "${YELLOW}Warning:${NC} %s\n" "$1"; }
error() { printf "${RED}Error:${NC} %s\n" "$1" >&2; exit 1; }

# Check Node.js version
check_node() {
    if ! command -v node >/dev/null 2>&1; then
        error "Node.js is not installed. Please install Node.js $MIN_NODE_VERSION or higher.

Install Node.js:
  - macOS: brew install node
  - Linux: https://nodejs.org/en/download/package-manager
  - Or use a version manager like fnm, nvm, or mise"
    fi
    
    NODE_VERSION=$(node -v | sed 's/v//' | cut -d. -f1)
    if [ "$NODE_VERSION" -lt "$MIN_NODE_VERSION" ]; then
        error "Node.js $MIN_NODE_VERSION+ required. Found: $(node -v)

Please upgrade Node.js to version $MIN_NODE_VERSION or higher."
    fi
    
    info "Found Node.js $(node -v)"
}

# Detect OS and architecture
detect_platform() {
    OS=$(uname -s | tr '[:upper:]' '[:lower:]')
    ARCH=$(uname -m)
    
    case "$OS" in
        darwin) OS="darwin" ;;
        linux) OS="linux" ;;
        mingw*|msys*|cygwin*) 
            error "Windows is not supported by this installer. Please use WSL or install manually."
            ;;
        *) error "Unsupported OS: $OS" ;;
    esac
    
    case "$ARCH" in
        x86_64|amd64) ARCH="x64" ;;
        arm64|aarch64) ARCH="arm64" ;;
        *) error "Unsupported architecture: $ARCH" ;;
    esac
    
    PLATFORM="${OS}-${ARCH}"
    info "Detected platform: $PLATFORM"
}

# Get latest release version or use specified version
get_version() {
    # Skip version fetch if using local tarball
    if [ -n "$ROO_LOCAL_TARBALL" ]; then
        VERSION="${ROO_VERSION:-local}"
        info "Using local tarball (version: $VERSION)"
        return
    fi
    
    if [ -n "$ROO_VERSION" ]; then
        VERSION="$ROO_VERSION"
        info "Using specified version: $VERSION"
        return
    fi
    
    info "Fetching latest version..."
    
    # Try to get the latest cli release
    RELEASES_JSON=$(curl -fsSL "https://api.github.com/repos/$REPO/releases" 2>/dev/null) || {
        error "Failed to fetch releases from GitHub. Check your internet connection."
    }
    
    # Extract highest cli-v* tag by semantic version (do not rely on API ordering)
    VERSION=$(printf "%s" "$RELEASES_JSON" | node -e '
const fs = require("fs")
const input = fs.readFileSync(0, "utf8")
let releases
try {
  releases = JSON.parse(input)
} catch {
  process.exit(1)
}

function parseVersion(version) {
  const core = String(version).trim().split("+", 1)[0].split("-", 1)[0]
  if (!core) return null
  const parts = core.split(".")
  if (parts.length === 0 || parts.some((part) => !/^\d+$/.test(part))) {
    return null
  }
  return parts.map((part) => Number.parseInt(part, 10))
}

function compareVersions(a, b) {
  const maxLength = Math.max(a.length, b.length)
  for (let i = 0; i < maxLength; i++) {
    const aPart = a[i] ?? 0
    const bPart = b[i] ?? 0
    if (aPart > bPart) return 1
    if (aPart < bPart) return -1
  }
  return 0
}

let latestVersion = ""
let latestParts = null

if (Array.isArray(releases)) {
  for (const release of releases) {
    if (!release || typeof release.tag_name !== "string" || !release.tag_name.startsWith("cli-v")) {
      continue
    }
    const candidate = release.tag_name.slice("cli-v".length)
    const candidateParts = parseVersion(candidate)
    if (!candidateParts) continue
    if (!latestParts || compareVersions(candidateParts, latestParts) > 0) {
      latestVersion = candidate
      latestParts = candidateParts
    }
  }
}

if (latestVersion) {
  process.stdout.write(latestVersion)
}
')
    
    if [ -z "$VERSION" ]; then
        error "Could not find any CLI releases. The CLI may not have been released yet."
    fi
    
    info "Latest version: $VERSION"
}

# Download and extract
download_and_install() {
    TARBALL="roo-cli-${PLATFORM}.tar.gz"
    
    # Create temp directory
    TMP_DIR=$(mktemp -d)
    trap "rm -rf $TMP_DIR" EXIT
    
    # Use local tarball if provided, otherwise download
    if [ -n "$ROO_LOCAL_TARBALL" ]; then
        if [ ! -f "$ROO_LOCAL_TARBALL" ]; then
            error "Local tarball not found: $ROO_LOCAL_TARBALL"
        fi
        info "Using local tarball: $ROO_LOCAL_TARBALL"
        cp "$ROO_LOCAL_TARBALL" "$TMP_DIR/$TARBALL"
    else
        URL="https://github.com/$REPO/releases/download/cli-v${VERSION}/${TARBALL}"
        
        info "Downloading from $URL..."
        
        # Download with progress indicator
        HTTP_CODE=$(curl -fsSL -w "%{http_code}" "$URL" -o "$TMP_DIR/$TARBALL" 2>/dev/null) || {
            if [ "$HTTP_CODE" = "404" ]; then
                error "Release not found for platform $PLATFORM version $VERSION.

Available at: https://github.com/$REPO/releases"
            fi
            error "Download failed. HTTP code: $HTTP_CODE"
        }

        # Verify we got something
        if [ ! -s "$TMP_DIR/$TARBALL" ]; then
            error "Downloaded file is empty. Please try again."
        fi
    fi

    # Remove old installation if exists
    if [ -d "$INSTALL_DIR" ]; then
        info "Removing previous installation..."
        rm -rf "$INSTALL_DIR"
    fi
    
    mkdir -p "$INSTALL_DIR"
    
    # Extract
    info "Extracting to $INSTALL_DIR..."
    tar -xzf "$TMP_DIR/$TARBALL" -C "$INSTALL_DIR" --strip-components=1 || {
        error "Failed to extract tarball. The download may be corrupted."
    }
    
    # Save ripgrep binary before npm install (npm install will overwrite node_modules)
    RIPGREP_BIN=""
    if [ -f "$INSTALL_DIR/node_modules/@vscode/ripgrep/bin/rg" ]; then
        RIPGREP_BIN="$TMP_DIR/rg"
        cp "$INSTALL_DIR/node_modules/@vscode/ripgrep/bin/rg" "$RIPGREP_BIN"
    fi
    
    # Install npm dependencies
    info "Installing dependencies..."
    cd "$INSTALL_DIR"
    npm install --production --silent 2>/dev/null || {
        warn "npm install failed, trying with --legacy-peer-deps..."
        npm install --production --legacy-peer-deps --silent 2>/dev/null || {
            error "Failed to install dependencies. Make sure npm is available."
        }
    }
    cd - > /dev/null
    
    # Restore ripgrep binary after npm install
    if [ -n "$RIPGREP_BIN" ] && [ -f "$RIPGREP_BIN" ]; then
        mkdir -p "$INSTALL_DIR/node_modules/@vscode/ripgrep/bin"
        cp "$RIPGREP_BIN" "$INSTALL_DIR/node_modules/@vscode/ripgrep/bin/rg"
        chmod +x "$INSTALL_DIR/node_modules/@vscode/ripgrep/bin/rg"
    fi
    
    # Make executable
    chmod +x "$INSTALL_DIR/bin/roo"
    
    # Also make ripgrep executable if it exists
    if [ -f "$INSTALL_DIR/bin/rg" ]; then
        chmod +x "$INSTALL_DIR/bin/rg"
    fi
}

# Create symlink in bin directory
setup_bin() {
    mkdir -p "$BIN_DIR"
    
    # Remove old symlink if exists
    if [ -L "$BIN_DIR/roo" ] || [ -f "$BIN_DIR/roo" ]; then
        rm -f "$BIN_DIR/roo"
    fi
    
    ln -sf "$INSTALL_DIR/bin/roo" "$BIN_DIR/roo"
    info "Created symlink: $BIN_DIR/roo"
}

atlas_enabled() {
    case "${ROO_INSTALL_ATLAS:-1}" in
        0|false|FALSE|no|NO) return 1 ;;
        *) return 0 ;;
    esac
}

atlas_release_arch() {
    case "$ARCH" in
        x64) printf "amd64" ;;
        arm64) printf "arm64" ;;
        *) printf "%s" "$ARCH" ;;
    esac
}

latest_atlas_version() {
    curl -fsSL "https://api.github.com/repos/$ATLAS_REPO/releases/latest" 2>/dev/null | node -e '
const fs = require("fs")
let release
try {
  release = JSON.parse(fs.readFileSync(0, "utf8"))
} catch {
  process.exit(1)
}
const tag = String(release.tag_name || "").trim()
if (!tag) process.exit(1)
process.stdout.write(tag.replace(/^v/, ""))
'
}

install_atlas() {
    if ! atlas_enabled; then
        warn "Skipping Atlas install/configuration because ROO_INSTALL_ATLAS=0"
        return
    fi

    if command -v atlas >/dev/null 2>&1; then
        ATLAS_COMMAND="$(command -v atlas)"
        info "Found Atlas at $ATLAS_COMMAND"
        return
    fi

    ATLAS_VERSION="${ROO_ATLAS_VERSION:-}"
    if [ -z "$ATLAS_VERSION" ] || [ "$ATLAS_VERSION" = "latest" ]; then
        info "Fetching latest Atlas version..."
        ATLAS_VERSION="$(latest_atlas_version)" || {
            error "Failed to resolve latest Atlas release from $ATLAS_REPO. Set ROO_INSTALL_ATLAS=0 to skip."
        }
    fi
    ATLAS_VERSION="${ATLAS_VERSION#v}"
    ATLAS_ARCH="$(atlas_release_arch)"
    ATLAS_TARBALL="atlas_${ATLAS_VERSION}_${OS}_${ATLAS_ARCH}.tar.gz"
    ATLAS_URL="https://github.com/$ATLAS_REPO/releases/download/v${ATLAS_VERSION}/${ATLAS_TARBALL}"

    info "Installing Atlas $ATLAS_VERSION from $ATLAS_URL..."
    ATLAS_TMP_DIR="$(mktemp -d)"
    curl -fsSL "$ATLAS_URL" -o "$ATLAS_TMP_DIR/$ATLAS_TARBALL" || {
        rm -rf "$ATLAS_TMP_DIR"
        error "Failed to download Atlas for $OS/$ATLAS_ARCH. Set ROO_INSTALL_ATLAS=0 to skip."
    }
    tar -xzf "$ATLAS_TMP_DIR/$ATLAS_TARBALL" -C "$ATLAS_TMP_DIR" || {
        rm -rf "$ATLAS_TMP_DIR"
        error "Failed to extract Atlas archive."
    }
    if [ ! -f "$ATLAS_TMP_DIR/atlas" ]; then
        rm -rf "$ATLAS_TMP_DIR"
        error "Atlas archive did not contain an atlas binary."
    fi
    mkdir -p "$BIN_DIR"
    cp "$ATLAS_TMP_DIR/atlas" "$BIN_DIR/atlas"
    chmod +x "$BIN_DIR/atlas"
    rm -rf "$ATLAS_TMP_DIR"
    ATLAS_COMMAND="$BIN_DIR/atlas"
    info "Installed Atlas: $ATLAS_COMMAND"
}

configure_atlas_mcp() {
    if ! atlas_enabled; then
        return
    fi

    if [ -z "$ATLAS_COMMAND" ]; then
        ATLAS_COMMAND="$(command -v atlas 2>/dev/null || true)"
    fi
    if [ -z "$ATLAS_COMMAND" ]; then
        error "Atlas command is unavailable after install."
    fi

    info "Configuring $ATLAS_SERVER_NAME MCP defaults for FusionX/Roo..."
    ATLAS_COMMAND="$ATLAS_COMMAND" ATLAS_SERVER_NAME="$ATLAS_SERVER_NAME" node <<'NODE'
const fs = require("fs")
const os = require("os")
const path = require("path")

const command = process.env.ATLAS_COMMAND
const serverName = process.env.ATLAS_SERVER_NAME || "pulse-atlas"
const tools = [
  "context",
  "search",
  "semantic_search",
  "symbol",
  "callers",
  "neighbors",
  "path",
  "refs",
  "explain",
  "impact",
  "cross_repo_impact",
  "status",
]

function defaultStorageDirs() {
  const explicit = String(process.env.ROO_ATLAS_MCP_STORAGE_DIRS || "").trim()
  if (explicit) return explicit.split(path.delimiter).filter(Boolean)

  const home = os.homedir()
  if (process.platform === "darwin") {
    const base = path.join(home, "Library", "Application Support", "Code", "User", "globalStorage")
    return [path.join(base, "aziro.fusionx"), path.join(base, "aziro.fusionx-cline")]
  }
  return [
    path.join(home, ".config", "Code", "User", "globalStorage", "aziro.fusionx"),
    path.join(home, ".local", "share", "code-server", "User", "globalStorage", "aziro.fusionx"),
  ]
}

const server = {
  type: "stdio",
  command,
  args: ["mcp", "--transport", "stdio", "--db", "sqlite://${workspaceFolder}/.atlas/atlas.db"],
  cwd: "${workspaceFolder}",
  alwaysAllow: tools,
  timeout: 120,
}

for (const dir of defaultStorageDirs()) {
  const settingsDir = path.join(dir, "settings")
  fs.mkdirSync(settingsDir, { recursive: true })
  const file = path.join(settingsDir, "mcp_settings.json")
  let root = {}
  if (fs.existsSync(file)) {
    try {
      root = JSON.parse(fs.readFileSync(file, "utf8"))
    } catch {
      root = {}
    }
  }
  if (!root || typeof root !== "object" || Array.isArray(root)) root = {}
  if (!root.mcpServers || typeof root.mcpServers !== "object" || Array.isArray(root.mcpServers)) {
    root.mcpServers = {}
  }
  root.mcpServers[serverName] = server
  fs.writeFileSync(file, `${JSON.stringify(root, null, 2)}\n`)
  console.log(`registered ${serverName} in ${file}`)
}
NODE
}

# Check if bin dir is in PATH and provide instructions
check_path() {
    case ":$PATH:" in
        *":$BIN_DIR:"*) 
            # Already in PATH
            return 0
            ;;
    esac
    
    warn "$BIN_DIR is not in your PATH"
    echo ""
    echo "Add this line to your shell profile:"
    echo ""
    
    # Detect shell and provide specific instructions
    SHELL_NAME=$(basename "$SHELL")
    case "$SHELL_NAME" in
        zsh)
            echo "  echo 'export PATH=\"$BIN_DIR:\$PATH\"' >> ~/.zshrc"
            echo "  source ~/.zshrc"
            ;;
        bash)
            if [ -f "$HOME/.bashrc" ]; then
                echo "  echo 'export PATH=\"$BIN_DIR:\$PATH\"' >> ~/.bashrc"
                echo "  source ~/.bashrc"
            else
                echo "  echo 'export PATH=\"$BIN_DIR:\$PATH\"' >> ~/.bash_profile"
                echo "  source ~/.bash_profile"
            fi
            ;;
        fish)
            echo "  set -Ux fish_user_paths $BIN_DIR \$fish_user_paths"
            ;;
        *)
            echo "  export PATH=\"$BIN_DIR:\$PATH\""
            ;;
    esac
    echo ""
}

# Verify installation
verify_install() {
    if [ -x "$BIN_DIR/roo" ]; then
        info "Verifying installation..."
        # Just check if it runs without error
        "$BIN_DIR/roo" --version >/dev/null 2>&1 || true
    fi
    if atlas_enabled && [ -n "$ATLAS_COMMAND" ]; then
        "$ATLAS_COMMAND" version >/dev/null 2>&1 || warn "Atlas was installed but did not report a version"
    fi
}

# Print success message
print_success() {
    echo ""
    printf "${GREEN}${BOLD}✓ Roo Code CLI installed successfully!${NC}\n"
    echo ""
    echo "  Installation: $INSTALL_DIR"
    echo "  Binary: $BIN_DIR/roo"
    echo "  Version: $VERSION"
    if atlas_enabled; then
        echo "  Atlas MCP: $ATLAS_SERVER_NAME -> ${ATLAS_COMMAND:-atlas}"
    fi
    echo ""
    echo "  ${BOLD}Get started:${NC}"
    echo "    roo --help"
    echo ""
    echo "  ${BOLD}Example:${NC}"
    echo "    export OPENROUTER_API_KEY=sk-or-v1-..."
    echo "    cd ~/my-project && roo \"What is this project?\""
    echo ""
}

# Main
main() {
    echo ""
    printf "${BLUE}${BOLD}"
    echo "  ╭─────────────────────────────────╮"
    echo "  │     Roo Code CLI Installer      │"
    echo "  ╰─────────────────────────────────╯"
    printf "${NC}"
    echo ""
    
    check_node
    detect_platform
    get_version
    download_and_install
    setup_bin
    install_atlas
    configure_atlas_mcp
    check_path
    verify_install
    print_success
}

main "$@"
