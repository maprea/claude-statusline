#!/usr/bin/env bash
#
# Claude Code Usage Calculator Daemon
# ====================================
# Runs the usage calculator every 15 seconds in the background.
#
# Usage:
#   ./calc_daemon.sh start   - Start the daemon
#   ./calc_daemon.sh stop    - Stop the daemon
#   ./calc_daemon.sh status  - Check daemon status
#   ./calc_daemon.sh restart - Restart the daemon
#   ./calc_daemon.sh run     - Run once (for testing)
#
# The daemon writes its PID to ~/.claude/.calc_daemon.pid

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="${HOME}/.claude"
PID_FILE="${CLAUDE_DIR}/.calc_daemon.pid"
LOG_FILE="${CLAUDE_DIR}/calc_daemon.log"
CALC_SCRIPT="${SCRIPT_DIR}/claude_usage_calc.py"
REFRESH_INTERVAL=15  # seconds

# Ensure claude directory exists
mkdir -p "$CLAUDE_DIR"

# ============================================================================
# Helper Functions
# ============================================================================

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
}

is_running() {
    if [[ -f "$PID_FILE" ]]; then
        local pid
        pid=$(cat "$PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            return 0
        fi
    fi
    return 1
}

get_pid() {
    if [[ -f "$PID_FILE" ]]; then
        cat "$PID_FILE"
    else
        echo ""
    fi
}

# ============================================================================
# Daemon Functions
# ============================================================================

daemon_loop() {
    log "Daemon starting with PID $$"
    echo $$ > "$PID_FILE"
    
    trap 'log "Daemon received SIGTERM"; rm -f "$PID_FILE"; exit 0' SIGTERM
    trap 'log "Daemon received SIGINT"; rm -f "$PID_FILE"; exit 0' SIGINT
    
    while true; do
        # Run calculator
        if [[ -f "$CALC_SCRIPT" ]]; then
            python3 "$CALC_SCRIPT" 2>> "$LOG_FILE" || true
        else
            log "Calculator script not found: $CALC_SCRIPT"
        fi
        
        sleep "$REFRESH_INTERVAL"
    done
}

start_daemon() {
    if is_running; then
        echo "Daemon is already running (PID: $(get_pid))"
        return 0
    fi
    
    echo "Starting Claude usage calculator daemon..."
    
    # Run daemon in background
    nohup bash -c "$(declare -f log daemon_loop); SCRIPT_DIR='$SCRIPT_DIR' CLAUDE_DIR='$CLAUDE_DIR' PID_FILE='$PID_FILE' LOG_FILE='$LOG_FILE' CALC_SCRIPT='$CALC_SCRIPT' REFRESH_INTERVAL='$REFRESH_INTERVAL' daemon_loop" >> "$LOG_FILE" 2>&1 &
    
    sleep 1
    
    if is_running; then
        echo "Daemon started successfully (PID: $(get_pid))"
        log "Daemon started by user"
    else
        echo "Failed to start daemon. Check $LOG_FILE for details."
        return 1
    fi
}

stop_daemon() {
    if ! is_running; then
        echo "Daemon is not running"
        rm -f "$PID_FILE"
        return 0
    fi
    
    local pid
    pid=$(get_pid)
    echo "Stopping daemon (PID: $pid)..."
    
    kill "$pid" 2>/dev/null || true
    
    # Wait for graceful shutdown
    local count=0
    while is_running && (( count < 10 )); do
        sleep 0.5
        ((count++))
    done
    
    # Force kill if still running
    if is_running; then
        kill -9 "$pid" 2>/dev/null || true
    fi
    
    rm -f "$PID_FILE"
    echo "Daemon stopped"
    log "Daemon stopped by user"
}

daemon_status() {
    if is_running; then
        local pid
        pid=$(get_pid)
        echo "Daemon is running (PID: $pid)"
        
        # Show recent log entries
        if [[ -f "$LOG_FILE" ]]; then
            echo ""
            echo "Recent log entries:"
            tail -5 "$LOG_FILE" 2>/dev/null || true
        fi
        
        # Show cache status
        local cache_file="${CLAUDE_DIR}/usage_cache.json"
        if [[ -f "$cache_file" ]]; then
            local cache_age
            cache_age=$(( $(date +%s) - $(stat -c %Y "$cache_file" 2>/dev/null || stat -f %m "$cache_file" 2>/dev/null || echo 0) ))
            echo ""
            echo "Cache file age: ${cache_age}s"
        fi
        
        return 0
    else
        echo "Daemon is not running"
        return 1
    fi
}

run_once() {
    echo "Running calculator once..."
    if [[ -f "$CALC_SCRIPT" ]]; then
        python3 "$CALC_SCRIPT" "$@"
    else
        echo "Calculator script not found: $CALC_SCRIPT"
        return 1
    fi
}

# ============================================================================
# Main
# ============================================================================

case "${1:-status}" in
    start)
        start_daemon
        ;;
    stop)
        stop_daemon
        ;;
    restart)
        stop_daemon
        sleep 1
        start_daemon
        ;;
    status)
        daemon_status
        ;;
    run)
        shift || true
        run_once "$@"
        ;;
    *)
        echo "Usage: $0 {start|stop|restart|status|run}"
        echo ""
        echo "Commands:"
        echo "  start   - Start the background daemon"
        echo "  stop    - Stop the background daemon"
        echo "  restart - Restart the daemon"
        echo "  status  - Show daemon status"
        echo "  run     - Run calculator once (for testing)"
        exit 1
        ;;
esac
