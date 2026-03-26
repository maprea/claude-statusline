#!/usr/bin/env bash
#
# Claude Code Status Line - Installation Script
# ==============================================
# Installs the status line scripts and configures Claude Code.
#
# Usage:
#   ./setup.sh              # Full install
#   ./setup.sh --daemon     # Also set up background daemon
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
    
    if ! command -v python3 &>/dev/null; then
        missing+=("python3")
    fi
    
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
    
    # Copy all scripts
    cp "${SCRIPT_DIR}/claude_usage_calc.py" "$INSTALL_DIR/"
    cp "${SCRIPT_DIR}/statusline_display.sh" "$INSTALL_DIR/"
    cp "${SCRIPT_DIR}/statusline.sh" "$INSTALL_DIR/"
    cp "${SCRIPT_DIR}/calc_daemon.sh" "$INSTALL_DIR/"
    
    # Make executable
    chmod +x "${INSTALL_DIR}"/*.sh
    chmod +x "${INSTALL_DIR}"/*.py
    
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

setup_daemon() {
    info "Setting up background daemon..."
    
    local daemon_script="${INSTALL_DIR}/calc_daemon.sh"
    
    if [[ "$OSTYPE" == "darwin"* ]]; then
        setup_launchd
    else
        setup_systemd
    fi
}

setup_launchd() {
    local plist_file="${HOME}/Library/LaunchAgents/com.claude.usage-calc.plist"
    local daemon_script="${INSTALL_DIR}/calc_daemon.sh"
    
    info "Creating launchd service..."
    
    mkdir -p "${HOME}/Library/LaunchAgents"
    
    cat > "$plist_file" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.claude.usage-calc</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${daemon_script}</string>
        <string>run</string>
    </array>
    <key>StartInterval</key>
    <integer>15</integer>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${CLAUDE_DIR}/calc_daemon.log</string>
    <key>StandardErrorPath</key>
    <string>${CLAUDE_DIR}/calc_daemon.log</string>
</dict>
</plist>
EOF
    
    # Load the service
    launchctl unload "$plist_file" 2>/dev/null || true
    launchctl load "$plist_file"
    
    success "launchd service installed and started"
    info "To check status: launchctl list | grep claude"
    info "To stop: launchctl unload $plist_file"
}

setup_systemd() {
    local service_file="${HOME}/.config/systemd/user/claude-usage-calc.service"
    local timer_file="${HOME}/.config/systemd/user/claude-usage-calc.timer"
    local calc_script="${INSTALL_DIR}/claude_usage_calc.py"
    
    info "Creating systemd user service..."
    
    mkdir -p "${HOME}/.config/systemd/user"
    
    # Create service unit
    cat > "$service_file" << EOF
[Unit]
Description=Claude Code Usage Calculator
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/bin/python3 ${calc_script}
StandardOutput=append:${CLAUDE_DIR}/calc_daemon.log
StandardError=append:${CLAUDE_DIR}/calc_daemon.log

[Install]
WantedBy=default.target
EOF
    
    # Create timer unit (runs every 15 seconds)
    cat > "$timer_file" << EOF
[Unit]
Description=Claude Code Usage Calculator Timer
Requires=claude-usage-calc.service

[Timer]
OnBootSec=5
OnUnitActiveSec=15
AccuracySec=1

[Install]
WantedBy=timers.target
EOF
    
    # Reload and enable
    systemctl --user daemon-reload
    systemctl --user enable claude-usage-calc.timer
    systemctl --user start claude-usage-calc.timer
    
    success "systemd timer installed and started"
    info "To check status: systemctl --user status claude-usage-calc.timer"
    info "To stop: systemctl --user stop claude-usage-calc.timer"
}

# ============================================================================
# Uninstallation
# ============================================================================

uninstall() {
    warn "Uninstalling Claude Code Status Line..."
    
    # Stop daemon
    if [[ -f "${INSTALL_DIR}/calc_daemon.sh" ]]; then
        "${INSTALL_DIR}/calc_daemon.sh" stop 2>/dev/null || true
    fi
    
    # Remove launchd service (macOS)
    local plist_file="${HOME}/Library/LaunchAgents/com.claude.usage-calc.plist"
    if [[ -f "$plist_file" ]]; then
        launchctl unload "$plist_file" 2>/dev/null || true
        rm -f "$plist_file"
        info "Removed launchd service"
    fi
    
    # Remove systemd service (Linux)
    if systemctl --user is-active claude-usage-calc.timer &>/dev/null; then
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
    
    # Remove cache files
    rm -f "${CLAUDE_DIR}/usage_cache.json"
    rm -f "${CLAUDE_DIR}/.usage_calc.lock"
    rm -f "${CLAUDE_DIR}/.calc_daemon.pid"
    rm -f "${CLAUDE_DIR}/calc_daemon.log"
    info "Removed cache files"
    
    # Note about settings.json
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
  --daemon        Also set up background daemon (launchd/systemd)
  --uninstall     Remove all installed files and services

Installation steps:
  1. Check dependencies (python3, jq, bc)
  2. Copy scripts to ~/.claude/statusline/
  3. Configure Claude Code settings.json
  4. (Optional) Set up background daemon

After installation:
  - Restart Claude Code to see the status line
  - Run '~/.claude/statusline/calc_daemon.sh status' to check daemon
  - Edit ~/.claude/settings.json to customize

EOF
}

main() {
    local setup_daemon=false
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help|-h)
                show_help
                exit 0
                ;;
            --daemon)
                setup_daemon=true
                shift
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
    
    # Set up daemon if requested
    if $setup_daemon; then
        setup_daemon
    else
        info "Skipping daemon setup (use --daemon to enable)"
        info "The status line will still work, updating on-demand"
    fi
    
    echo ""
    echo "╔══════════════════════════════════════════════════════════════════╗"
    echo "║                     Installation Complete!                       ║"
    echo "╚══════════════════════════════════════════════════════════════════╝"
    echo ""
    success "Status line installed successfully!"
    echo ""
    info "Next steps:"
    echo "  1. Restart Claude Code (close and reopen terminal)"
    echo "  2. Accept the workspace trust dialog when prompted"
    echo ""
    info "To run calculator manually:"
    echo "  ${INSTALL_DIR}/calc_daemon.sh run"
    echo ""
    info "To start background daemon:"
    echo "  ${INSTALL_DIR}/calc_daemon.sh start"
    echo ""
}

main "$@"
