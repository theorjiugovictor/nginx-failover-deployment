#!/usr/bin/env python3
"""
Blue/Green Deployment Log Watcher and Alert System
Monitors Nginx logs for failover events and error rates, sends alerts to Slack
"""

import os
import io
import re
import time
import json
import requests
from datetime import datetime
from collections import deque
from typing import Optional, Dict

# Configuration from environment variables
SLACK_WEBHOOK_URL = os.getenv('SLACK_WEBHOOK_URL', '')
ERROR_RATE_THRESHOLD = float(os.getenv('ERROR_RATE_THRESHOLD', '2.0'))  # percentage
WINDOW_SIZE = int(os.getenv('WINDOW_SIZE', '200'))  # number of requests
ALERT_COOLDOWN_SEC = int(os.getenv('ALERT_COOLDOWN_SEC', '300'))  # seconds
LOG_FILE = os.getenv('NGINX_LOG_FILE', '/var/log/nginx/access.log')
MAINTENANCE_MODE = os.getenv('MAINTENANCE_MODE', 'false').lower() == 'true'

# State tracking
last_seen_pool: Optional[str] = None
request_window = deque(maxlen=WINDOW_SIZE)
last_alert_times: Dict[str, float] = {}


def parse_log_line(line: str) -> Optional[Dict[str, str]]:
    """
    Parse Nginx log line in custom format
    Example: [28/Jan/2025:10:30:45 +0000] method=GET uri=/version status=200 pool=blue ...
    """
    pattern = r'\[([^\]]+)\] (?:method=(\S+) )?(?:uri=(\S+) )?(?:status=(\d+) )?(?:pool=(\S+) )?(?:release=(\S+) )?(?:upstream_addr=(\S+) )?(?:upstream_status=(\S+) )?(?:request_time=(\S+) )?(?:upstream_response_time=(\S+) )?(?:client=(\S+))?'
    
    match = re.search(pattern, line)
    if not match:
        return None
    
    return {
        'timestamp': match.group(1),
        'method': match.group(2) or '-',
        'uri': match.group(3) or '-',
        'status': match.group(4) or '-',
        'pool': match.group(5) or '-',
        'release': match.group(6) or '-',
        'upstream_addr': match.group(7) or '-',
        'upstream_status': match.group(8) or '-',
        'request_time': match.group(9) or '0',
        'upstream_response_time': match.group(10) or '0',
        'client': match.group(11) or '-'
    }


def send_slack_alert(alert_type: str, message: str, details: Dict[str, str]) -> bool:
    """Send alert to Slack with rate limiting"""
    if not SLACK_WEBHOOK_URL:
        print(f"⚠️  No Slack webhook configured. Alert: {alert_type}")
        return False
    
    if MAINTENANCE_MODE:
        print(f"🔧 Maintenance mode enabled. Suppressing alert: {alert_type}")
        return False
    
    # Check cooldown
    now = time.time()
    if alert_type in last_alert_times:
        time_since_last = now - last_alert_times[alert_type]
        if time_since_last < ALERT_COOLDOWN_SEC:
            print(f"⏱️  Alert cooldown active for {alert_type}. Skipping. ({int(ALERT_COOLDOWN_SEC - time_since_last)}s remaining)")
            return False
    
    # Build Slack message
    color = "#ff0000" if "error" in alert_type.lower() else "#ffa500"
    
    slack_payload = {
        "attachments": [{
            "color": color,
            "title": f"🚨 {alert_type}",
            "text": message,
            "fields": [
                {"title": key, "value": value, "short": True}
                for key, value in details.items()
            ],
            "footer": "Blue/Green Monitoring",
            "ts": int(now)
        }]
    }
    
    try:
        response = requests.post(
            SLACK_WEBHOOK_URL,
            json=slack_payload,
            headers={'Content-Type': 'application/json'},
            timeout=10
        )
        
        if response.status_code == 200:
            print(f"✅ Slack alert sent: {alert_type}")
            last_alert_times[alert_type] = now
            return True
        else:
            print(f"❌ Slack alert failed: {response.status_code} - {response.text}")
            return False
            
    except Exception as e:
        print(f"❌ Error sending Slack alert: {e}")
        return False


def check_failover(current_pool: str, log_entry: Dict[str, str]) -> None:
    """Detect and alert on pool failover events"""
    global last_seen_pool
    
    if last_seen_pool is None:
        last_seen_pool = current_pool
        print(f"📍 Initial pool detected: {current_pool}")
        return
    
    if current_pool != last_seen_pool and current_pool != '-':
        print(f"🔄 FAILOVER DETECTED: {last_seen_pool} → {current_pool}")
        
        send_slack_alert(
            alert_type="Failover Detected",
            message=f"Traffic has switched from *{last_seen_pool}* to *{current_pool}*",
            details={
                "Previous Pool": last_seen_pool,
                "Current Pool": current_pool,
                "Release": log_entry.get('release', 'unknown'),
                "Upstream": log_entry.get('upstream_addr', 'unknown'),
                "Timestamp": log_entry.get('timestamp', 'unknown')
            }
        )
        
        last_seen_pool = current_pool


def check_error_rate() -> None:
    """Calculate error rate over sliding window and alert if threshold exceeded"""
    if len(request_window) < WINDOW_SIZE:
        return  # Not enough data yet
    
    error_count = sum(1 for status in request_window if status >= 500)
    error_rate = (error_count / len(request_window)) * 100
    
    if error_rate > ERROR_RATE_THRESHOLD:
        print(f"⚠️  HIGH ERROR RATE: {error_rate:.2f}% ({error_count}/{len(request_window)} requests)")
        
        send_slack_alert(
            alert_type="High Error Rate",
            message=f"Error rate has exceeded threshold: *{error_rate:.2f}%*",
            details={
                "Error Rate": f"{error_rate:.2f}%",
                "Threshold": f"{ERROR_RATE_THRESHOLD}%",
                "Errors": str(error_count),
                "Window Size": str(WINDOW_SIZE),
                "Action": "Check upstream container logs"
            }
        )


def check_recovery(current_pool: str, initial_pool: str) -> None:
    """Detect when primary pool has recovered and is serving traffic again"""
    global last_seen_pool
    
    # If we're back to the initial pool after a failover
    if current_pool == initial_pool and last_seen_pool != initial_pool:
        print(f"✅ RECOVERY DETECTED: Back to {initial_pool}")
        
        send_slack_alert(
            alert_type="Recovery Detected",
            message=f"Primary pool *{initial_pool}* has recovered and is serving traffic",
            details={
                "Recovered Pool": initial_pool,
                "Status": "Healthy",
                "Action": "No action required"
            }
        )


def tail_file(file_path: str):
    """Tail a file like 'tail -f'"""
    print(f"📖 Starting to tail log file: {file_path}")
    
    # Wait for file to exist
    while not os.path.exists(file_path):
        print(f"⏳ Waiting for log file to be created: {file_path}")
        time.sleep(2)
    
    with open(file_path, 'r') as file:
        # Try to go to end of file for normal regular files. Some mounts
        # (named pipes or non-seekable streams) will raise UnsupportedOperation
        # — handle that gracefully by falling back to streaming reads.
        try:
            file.seek(0, 2)
        except (io.UnsupportedOperation, OSError):
            print("⚠️  Log stream is not seekable; reading sequentially from current position")

        while True:
            line = file.readline()
            if not line:
                time.sleep(0.1)  # Wait for new content
                continue

            yield line.strip()


def main():
    """Main monitoring loop"""
    print("=" * 60)
    print("🔍 Blue/Green Log Watcher Started")
    print("=" * 60)
    print(f"📊 Configuration:")
    print(f"   - Log File: {LOG_FILE}")
    print(f"   - Error Rate Threshold: {ERROR_RATE_THRESHOLD}%")
    print(f"   - Window Size: {WINDOW_SIZE} requests")
    print(f"   - Alert Cooldown: {ALERT_COOLDOWN_SEC} seconds")
    print(f"   - Slack Webhook: {'Configured ✅' if SLACK_WEBHOOK_URL else 'NOT configured ❌'}")
    print(f"   - Maintenance Mode: {'ON 🔧' if MAINTENANCE_MODE else 'OFF'}")
    print("=" * 60)
    print()
    
    initial_pool = os.getenv('ACTIVE_POOL', 'blue')
    print(f"📍 Expected initial pool: {initial_pool}")
    print()
    
    try:
        for line in tail_file(LOG_FILE):
            log_entry = parse_log_line(line)
            
            if not log_entry:
                continue
            
            # Extract key fields
            current_pool = log_entry.get('pool', '-')
            status_code = int(log_entry.get('status', '0'))
            upstream_status = log_entry.get('upstream_status', '-')
            
            # Skip if no pool info
            if current_pool == '-':
                continue
            
            # Track status codes in sliding window
            request_window.append(status_code)
            
            # Check for failover
            check_failover(current_pool, log_entry)
            
            # Check for high error rate
            check_error_rate()
            
            # Check for recovery
            check_recovery(current_pool, initial_pool)
            
            # Log to console (optional, can be verbose)
            if status_code >= 500:
                print(f"❌ Error: {status_code} | Pool: {current_pool} | URI: {log_entry.get('uri', '-')}")
            
    except KeyboardInterrupt:
        print("\n👋 Log watcher stopped by user")
    except Exception as e:
        print(f"💥 Fatal error: {e}")
        raise


if __name__ == '__main__':
    main()
