#!/usr/bin/env python3
"""
Claude Code Usage Calculator
============================
Parses local session JSONL files to calculate:
- Per-session token usage (input, output, total)
- 5-hour window cumulative usage with auto-detected boundaries
- Weekly cumulative usage with auto-detected boundaries
- Window/weekly reset times

Output: JSON cache file for the statusline script to read.
Run via cron or background loop every 15 seconds.

Architecture:
  ~/.claude/projects/<project-path>/<session-uuid>.jsonl
  → parsed messages with usage data
  → aggregated metrics written to ~/.claude/usage_cache.json
"""

import json
import os
import sys
import glob
import hashlib
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Dict, List, Optional, Tuple, Any
from collections import defaultdict
import fcntl

# Constants
CLAUDE_DIR = Path.home() / ".claude"
PROJECTS_DIR = CLAUDE_DIR / "projects"
CACHE_FILE = CLAUDE_DIR / "usage_cache.json"
LOCK_FILE = CLAUDE_DIR / ".usage_calc.lock"
WINDOW_DURATION_HOURS = 5
WEEK_DURATION_HOURS = 24 * 7


def get_file_lock(lock_path: Path) -> Optional[int]:
    """Acquire exclusive file lock to prevent concurrent runs."""
    lock_fd = os.open(str(lock_path), os.O_CREAT | os.O_RDWR)
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return lock_fd
    except (IOError, OSError):
        os.close(lock_fd)
        return None


def release_file_lock(lock_fd: int, lock_path: Path):
    """Release file lock."""
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_UN)
        os.close(lock_fd)
    except Exception:
        pass


def parse_timestamp(ts_str: str) -> Optional[datetime]:
    """Parse ISO timestamp string to datetime with UTC timezone."""
    if not ts_str:
        return None
    try:
        # Handle various formats
        ts_str = ts_str.replace("Z", "+00:00")
        if "." in ts_str:
            # Truncate microseconds if too long
            parts = ts_str.split(".")
            frac_and_tz = parts[1]
            # Find timezone part
            for i, c in enumerate(frac_and_tz):
                if c in "+-":
                    frac = frac_and_tz[:i][:6]  # Max 6 decimal places
                    tz = frac_and_tz[i:]
                    ts_str = f"{parts[0]}.{frac}{tz}"
                    break
            else:
                # No timezone in fraction part
                ts_str = f"{parts[0]}.{frac_and_tz[:6]}"
        dt = datetime.fromisoformat(ts_str)
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        return dt
    except Exception:
        return None


def extract_usage_from_message(msg: Dict) -> Dict[str, int]:
    """Extract token usage from a message entry."""
    usage = {
        "input_tokens": 0,
        "output_tokens": 0,
        "cache_creation_tokens": 0,
        "cache_read_tokens": 0,
    }
    
    # Try different paths where usage might be stored
    usage_data = None
    
    # Path 1: message.usage
    if "message" in msg and isinstance(msg["message"], dict):
        usage_data = msg["message"].get("usage")
    
    # Path 2: direct usage field
    if not usage_data and "usage" in msg:
        usage_data = msg.get("usage")
    
    # Path 3: nested in response
    if not usage_data and "response" in msg:
        resp = msg["response"]
        if isinstance(resp, dict):
            usage_data = resp.get("usage")
    
    if usage_data and isinstance(usage_data, dict):
        usage["input_tokens"] = usage_data.get("input_tokens", 0) or 0
        usage["output_tokens"] = usage_data.get("output_tokens", 0) or 0
        usage["cache_creation_tokens"] = usage_data.get("cache_creation_input_tokens", 0) or 0
        usage["cache_read_tokens"] = usage_data.get("cache_read_input_tokens", 0) or 0
    
    return usage


def parse_jsonl_file(filepath: Path) -> List[Dict]:
    """Parse a JSONL file and return list of message entries with usage and timestamps."""
    entries = []
    
    try:
        with open(filepath, "r", encoding="utf-8", errors="replace") as f:
            for line_num, line in enumerate(f, 1):
                line = line.strip()
                if not line:
                    continue
                try:
                    data = json.loads(line)
                    
                    # Skip summary/metadata entries
                    if data.get("type") == "summary":
                        continue
                    
                    # Extract timestamp
                    ts = None
                    for ts_field in ["timestamp", "createdAt", "created_at"]:
                        if ts_field in data:
                            ts = parse_timestamp(data[ts_field])
                            if ts:
                                break
                    
                    # Also check nested message timestamp
                    if not ts and "message" in data and isinstance(data["message"], dict):
                        msg_ts = data["message"].get("timestamp") or data["message"].get("createdAt")
                        if msg_ts:
                            ts = parse_timestamp(msg_ts)
                    
                    # Extract usage
                    usage = extract_usage_from_message(data)
                    
                    # Only include if we have usage data
                    if any(v > 0 for v in usage.values()):
                        entries.append({
                            "timestamp": ts,
                            "usage": usage,
                            "file": str(filepath),
                            "line": line_num,
                        })
                
                except json.JSONDecodeError:
                    continue
    
    except Exception as e:
        print(f"Error reading {filepath}: {e}", file=sys.stderr)
    
    return entries


def get_session_id_from_path(filepath: Path) -> str:
    """Extract session ID from JSONL file path."""
    return filepath.stem  # UUID without extension


def get_project_from_path(filepath: Path) -> str:
    """Extract project name from file path."""
    return filepath.parent.name


def find_all_sessions() -> Dict[str, List[Path]]:
    """Find all session JSONL files grouped by session ID."""
    sessions = defaultdict(list)
    
    if not PROJECTS_DIR.exists():
        return sessions
    
    # Find all JSONL files
    for jsonl_path in PROJECTS_DIR.glob("**/*.jsonl"):
        if jsonl_path.name.startswith("."):
            continue
        session_id = get_session_id_from_path(jsonl_path)
        sessions[session_id].append(jsonl_path)
    
    return sessions


def aggregate_session_usage(entries: List[Dict]) -> Dict[str, Any]:
    """Aggregate usage data for a single session."""
    total = {
        "input_tokens": 0,
        "output_tokens": 0,
        "cache_creation_tokens": 0,
        "cache_read_tokens": 0,
        "total_tokens": 0,
        "message_count": len(entries),
        "first_activity": None,
        "last_activity": None,
    }
    
    timestamps = []
    
    for entry in entries:
        usage = entry["usage"]
        total["input_tokens"] += usage["input_tokens"]
        total["output_tokens"] += usage["output_tokens"]
        total["cache_creation_tokens"] += usage["cache_creation_tokens"]
        total["cache_read_tokens"] += usage["cache_read_tokens"]
        
        if entry["timestamp"]:
            timestamps.append(entry["timestamp"])
    
    total["total_tokens"] = (
        total["input_tokens"] + 
        total["output_tokens"] + 
        total["cache_creation_tokens"] + 
        total["cache_read_tokens"]
    )
    
    if timestamps:
        timestamps.sort()
        total["first_activity"] = timestamps[0].isoformat()
        total["last_activity"] = timestamps[-1].isoformat()
    
    return total


def detect_window_boundaries(all_entries: List[Dict]) -> List[Dict]:
    """
    Auto-detect 5-hour window boundaries from activity patterns.
    A new window starts when there's a gap of >= 5 hours since last activity,
    or at the first activity of a new continuous period.
    
    Returns list of windows with start/end times and usage.
    """
    if not all_entries:
        return []
    
    # Sort entries by timestamp (filter out None timestamps)
    timed_entries = [e for e in all_entries if e["timestamp"]]
    if not timed_entries:
        return []
    
    timed_entries.sort(key=lambda x: x["timestamp"])
    
    windows = []
    window_start = None
    window_entries = []
    
    for entry in timed_entries:
        ts = entry["timestamp"]
        
        if window_start is None:
            # First entry starts a new window
            window_start = ts
            window_entries = [entry]
        else:
            # Check if this entry is within 5 hours of window start
            window_end_time = window_start + timedelta(hours=WINDOW_DURATION_HOURS)
            
            if ts <= window_end_time:
                # Within current window
                window_entries.append(entry)
            else:
                # New window needed - save current window
                if window_entries:
                    windows.append({
                        "start": window_start,
                        "end": window_start + timedelta(hours=WINDOW_DURATION_HOURS),
                        "entries": window_entries,
                    })
                # Start new window
                window_start = ts
                window_entries = [entry]
    
    # Don't forget the last window
    if window_entries and window_start:
        windows.append({
            "start": window_start,
            "end": window_start + timedelta(hours=WINDOW_DURATION_HOURS),
            "entries": window_entries,
        })
    
    return windows


def find_current_window(windows: List[Dict], now: datetime) -> Optional[Dict]:
    """Find the window that contains the current time, or the most recent active one."""
    for window in reversed(windows):
        if window["start"] <= now <= window["end"]:
            return window
    
    # If no active window, check if we're within 5 hours of the last activity
    if windows:
        last_window = windows[-1]
        last_entry_time = max(e["timestamp"] for e in last_window["entries"])
        potential_end = last_entry_time + timedelta(hours=WINDOW_DURATION_HOURS)
        if now <= potential_end:
            # Adjust window to be based on last activity
            return {
                "start": last_entry_time,
                "end": potential_end,
                "entries": last_window["entries"],  # Reuse entries for now
            }
    
    return None


def detect_weekly_boundary(all_entries: List[Dict], now: datetime) -> Tuple[datetime, datetime]:
    """
    Detect weekly quota boundaries.
    The week resets based on the first activity pattern (typically Monday or Thursday).
    
    For simplicity, we'll use a rolling 7-day window starting from the earliest
    activity within the past 7 days.
    """
    week_ago = now - timedelta(days=7)
    
    # Filter entries from the past 7 days
    recent_entries = [
        e for e in all_entries 
        if e["timestamp"] and e["timestamp"] >= week_ago
    ]
    
    if not recent_entries:
        # No recent activity, return current week boundaries
        # Start from Monday of current week
        days_since_monday = now.weekday()
        week_start = now.replace(hour=0, minute=0, second=0, microsecond=0) - timedelta(days=days_since_monday)
        return week_start, week_start + timedelta(days=7)
    
    recent_entries.sort(key=lambda x: x["timestamp"])
    
    # The week started at the first activity
    first_activity = recent_entries[0]["timestamp"]
    
    # Find the "week reset" by looking for gaps > 24 hours that might indicate weekly reset
    # Or just use simple 7-day rolling window from first activity this period
    
    # For quota purposes, we'll use rolling 7-day window
    week_start = max(week_ago, first_activity)
    week_end = week_start + timedelta(days=7)
    
    return week_start, week_end


def calculate_all_metrics() -> Dict[str, Any]:
    """
    Main calculation function.
    Returns comprehensive metrics for all sessions and cumulative usage.
    """
    now = datetime.now(timezone.utc)
    
    result = {
        "calculated_at": now.isoformat(),
        "sessions": {},
        "current_window": None,
        "weekly": None,
    }
    
    # Find all sessions
    sessions = find_all_sessions()
    all_entries = []
    
    # Process each session
    for session_id, paths in sessions.items():
        session_entries = []
        for path in paths:
            session_entries.extend(parse_jsonl_file(path))
        
        if session_entries:
            result["sessions"][session_id] = aggregate_session_usage(session_entries)
            result["sessions"][session_id]["project"] = get_project_from_path(paths[0])
            all_entries.extend(session_entries)
    
    # Detect and analyze windows
    windows = detect_window_boundaries(all_entries)
    current_window = find_current_window(windows, now)
    
    if current_window:
        window_usage = aggregate_session_usage(current_window["entries"])
        time_remaining = current_window["end"] - now
        seconds_remaining = max(0, time_remaining.total_seconds())
        
        result["current_window"] = {
            "start": current_window["start"].isoformat(),
            "end": current_window["end"].isoformat(),
            "reset_timestamp": int(current_window["end"].timestamp()),
            "seconds_remaining": int(seconds_remaining),
            "time_remaining_human": format_duration(seconds_remaining),
            "usage": window_usage,
            "is_active": now <= current_window["end"],
        }
    else:
        # No active window
        result["current_window"] = {
            "start": None,
            "end": None,
            "reset_timestamp": None,
            "seconds_remaining": 0,
            "time_remaining_human": "No active window",
            "usage": {
                "input_tokens": 0,
                "output_tokens": 0,
                "cache_creation_tokens": 0,
                "cache_read_tokens": 0,
                "total_tokens": 0,
                "message_count": 0,
            },
            "is_active": False,
        }
    
    # Weekly analysis
    week_start, week_end = detect_weekly_boundary(all_entries, now)
    weekly_entries = [
        e for e in all_entries
        if e["timestamp"] and week_start <= e["timestamp"] <= week_end
    ]
    
    weekly_usage = aggregate_session_usage(weekly_entries)
    weekly_time_remaining = week_end - now
    weekly_seconds_remaining = max(0, weekly_time_remaining.total_seconds())
    
    result["weekly"] = {
        "start": week_start.isoformat(),
        "end": week_end.isoformat(),
        "reset_timestamp": int(week_end.timestamp()),
        "seconds_remaining": int(weekly_seconds_remaining),
        "time_remaining_human": format_duration(weekly_seconds_remaining),
        "reset_day": week_end.strftime("%A"),
        "reset_time": week_end.strftime("%H:%M"),
        "usage": weekly_usage,
    }
    
    return result


def format_duration(seconds: float) -> str:
    """Format seconds into human-readable duration."""
    if seconds <= 0:
        return "0m"
    
    hours = int(seconds // 3600)
    minutes = int((seconds % 3600) // 60)
    
    if hours > 24:
        days = hours // 24
        hours = hours % 24
        return f"{days}d {hours}h"
    elif hours > 0:
        return f"{hours}h {minutes}m"
    else:
        return f"{minutes}m"


def write_cache(data: Dict):
    """Write metrics to cache file atomically."""
    cache_tmp = CACHE_FILE.with_suffix(".tmp")
    
    try:
        with open(cache_tmp, "w") as f:
            json.dump(data, f, indent=2)
        cache_tmp.rename(CACHE_FILE)
    except Exception as e:
        print(f"Error writing cache: {e}", file=sys.stderr)
        if cache_tmp.exists():
            cache_tmp.unlink()


def main():
    """Main entry point."""
    # Ensure claude directory exists
    CLAUDE_DIR.mkdir(exist_ok=True)
    
    # Try to acquire lock
    lock_fd = get_file_lock(LOCK_FILE)
    if lock_fd is None:
        print("Another instance is running, skipping...", file=sys.stderr)
        sys.exit(0)
    
    try:
        metrics = calculate_all_metrics()
        write_cache(metrics)
        
        # Output summary to stdout only in verbose mode
        if "--verbose" in sys.argv or "-v" in sys.argv:
            print(json.dumps(metrics, indent=2))
    
    finally:
        release_file_lock(lock_fd, LOCK_FILE)


if __name__ == "__main__":
    main()
