#!/usr/bin/env bash
#
# Claude Code Status Line - Installation Script
# ==============================================
# Installs the status line scripts and configures Claude Code.
#
# Usage:
#   ./setup.sh              # Full install
#   ./setup.sh --uninstall  # Remove everything

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${HOME}/.claude/statusline"
CLAUDE_DIR="${HOME}/.claude"
SETTINGS_FILE="${CLAUDE_DIR}/settings.json"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ============================================================================
# Helper Functions
# ============================================================================

info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

success() {
    echo -e "${GREEN}[OK]${NC} $*"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

error() {
    echo -e "${RED}[ERROR]${NC} $*"
}

check_dependencies() {
    local missing=()

    if ! command -v jq &>/dev/null; then
        missing+=("jq")
    fi

    if ! command -v bc &>/dev/null; then
        missing+=("bc")
    fi

    if (( ${#missing[@]} > 0 )); then
        error "Missing dependencies: ${missing[*]}"
        echo ""
        echo "Please install them:"
        if [[ "$OSTYPE" == "darwin"* ]]; then
            echo "  brew install ${missing[*]}"
        else
            echo "  sudo apt-get install ${missing[*]}"
            echo "  # or"
            echo "  sudo yum install ${missing[*]}"
        fi
        return 1
    fi

    success "All dependencies found"
    return 0
}

# ============================================================================
# Installation
# ============================================================================

install_files() {
    info "Creating installation directory: $INSTALL_DIR"
    mkdir -p "$INSTALL_DIR"

    info "Copying scripts..."

    cp "${SCRIPT_DIR}/statusline_display.sh" "$INSTALL_DIR/"
    cp "${SCRIPT_DIR}/statusline.sh" "$INSTALL_DIR/"

    chmod +x "${INSTALL_DIR}"/*.sh

    # Clean up legacy files from previous versions
    rm -f "${INSTALL_DIR}/calc_daemon.sh"
    rm -f "${INSTALL_DIR}/claude_usage_calc.py"
    rm -f "${CLAUDE_DIR}/usage_cache.json"
    rm -f "${CLAUDE_DIR}/.usage_calc.lock"
    rm -f "${CLAUDE_DIR}/.calc_daemon.pid"
    rm -f "${CLAUDE_DIR}/calc_daemon.log"

    success "Scripts installed to $INSTALL_DIR"
}

configure_claude() {
    info "Configuring Claude Code settings..."

    # Create settings directory if it doesn't exist
    mkdir -p "$CLAUDE_DIR"

    # Create or update settings.json
    if [[ -f "$SETTINGS_FILE" ]]; then
        # Backup existing settings
        cp "$SETTINGS_FILE" "${SETTINGS_FILE}.backup"
        info "Backed up existing settings to ${SETTINGS_FILE}.backup"

        # Check if statusLine is already configured
        if jq -e '.statusLine' "$SETTINGS_FILE" &>/dev/null; then
            warn "statusLine is already configured in settings.json"
            echo ""
            echo "Current configuration:"
            jq '.statusLine' "$SETTINGS_FILE"
            echo ""
            read -p "Do you want to replace it? [y/N] " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                info "Keeping existing statusLine configuration"
                return 0
            fi
        fi

        # Update settings with statusLine
        local temp_file
        temp_file=$(mktemp)
        jq --arg cmd "${INSTALL_DIR}/statusline.sh" \
           '.statusLine = {"type": "command", "command": $cmd}' \
           "$SETTINGS_FILE" > "$temp_file"
        mv "$temp_file" "$SETTINGS_FILE"
    else
        # Create new settings file
        cat > "$SETTINGS_FILE" << EOF
{
  "statusLine": {
    "type": "command",
    "command": "${INSTALL_DIR}/statusline.sh"
  }
}
EOF
    fi

    success "Claude Code settings updated"
}

# ============================================================================
# Uninstallation
# ============================================================================

uninstall() {
    warn "Uninstalling Claude Code Status Line..."

    # Remove legacy daemon services if they exist
    local plist_file="${HOME}/Library/LaunchAgents/com.claude.usage-calc.plist"
    if [[ -f "$plist_file" ]]; then
        launchctl unload "$plist_file" 2>/dev/null || true
        rm -f "$plist_file"
        info "Removed launchd service"
    fi

    if systemctl --user is-active claude-usage-calc.timer &>/dev/null 2>&1; then
        systemctl --user stop claude-usage-calc.timer
        systemctl --user disable claude-usage-calc.timer
        rm -f "${HOME}/.config/systemd/user/claude-usage-calc.service"
        rm -f "${HOME}/.config/systemd/user/claude-usage-calc.timer"
        systemctl --user daemon-reload
        info "Removed systemd service"
    fi

    # Remove installation directory
    if [[ -d "$INSTALL_DIR" ]]; then
        rm -rf "$INSTALL_DIR"
        info "Removed $INSTALL_DIR"
    fi

    # Remove legacy cache files
    rm -f "${CLAUDE_DIR}/usage_cache.json"
    rm -f "${CLAUDE_DIR}/.usage_calc.lock"
    rm -f "${CLAUDE_DIR}/.calc_daemon.pid"
    rm -f "${CLAUDE_DIR}/calc_daemon.log"

    warn "Note: statusLine configuration in ${SETTINGS_FILE} was not removed"
    warn "Edit the file manually to remove the statusLine section if desired"

    success "Uninstallation complete"
}

# ============================================================================
# Main
# ============================================================================

show_help() {
    cat << EOF
Claude Code Status Line - Setup Script

Usage: $0 [OPTIONS]

Options:
  --help, -h      Show this help message
  --uninstall     Remove all installed files and services

Installation steps:
  1. Check dependencies (jq, bc)
  2. Copy scripts to ~/.claude/statusline/
  3. Configure Claude Code settings.json

After installation:
  - Restart Claude Code to see the status line

EOF
}

main() {
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help|-h)
                show_help
                exit 0
                ;;
            --uninstall)
                uninstall
                exit 0
                ;;
            *)
                error "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done

    echo ""
    echo "╔══════════════════════════════════════════════════════════════════╗"
    echo "║         Claude Code Status Line - Installation                   ║"
    echo "╚══════════════════════════════════════════════════════════════════╝"
    echo ""

    # Check dependencies
    if ! check_dependencies; then
        exit 1
    fi

    # Install files
    install_files

    # Configure Claude Code
    configure_claude

    echo ""
    echo "╔══════════════════════════════════════════════════════════════════╗"
    echo "║                     Installation Complete!                       ║"
    echo "╚══════════════════════════════════════════════════════════════════╝"
    echo ""
    success "Status line installed successfully!"
    echo ""
    info "Restart Claude Code to see the status line"
    echo ""
}

main "$@"
