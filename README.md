# Blue/Green Deployment with Auto-Failover and Slack Alerts

Stage 3 implementation: Blue/Green deployment with Nginx auto-failover, structured logging, and real-time Slack alerting.

## Features

- **Blue/Green Deployment**: Two identical app instances with automatic failover
- **Zero-Downtime Switching**: Nginx automatically fails over to backup pool
- **Structured Logging**: Detailed logs with pool, release, timing, and status information
- **Real-Time Monitoring**: Python log watcher tracks all requests
- **Slack Alerts**: Automatic notifications for failovers and high error rates
- **Alert Rate Limiting**: Prevents alert spam with configurable cooldowns
- **Maintenance Mode**: Suppress alerts during planned changes

## Architecture

```
┌─────────────┐
│   Users     │
└──────┬──────┘
       │ :8080
       ▼
┌─────────────┐       ┌──────────────┐
│    Nginx    │──────▶│ Shared Logs  │
│ (Load Bal.) │       │   Volume     │
└──┬──────┬───┘       └──────┬───────┘
   │      │                  │
   │      │                  │ Reads continuously
   │      │                  ▼
   │      │          ┌──────────────┐
   │      │          │ Log Watcher  │
   │      │          │  (Python)    │
   │      │          └──────┬───────┘
   │      │                 │
   │      │                 │ Sends alerts
   │      │                 ▼
   │      │          ┌──────────────┐
   │      │          │    Slack     │
   │      │          └──────────────┘
   │      │
   ▼      ▼
┌───┐  ┌───┐
│ B │  │ G │
│ l │  │ r │
│ u │  │ e │
│ e │  │ e │
│   │  │ n │
└───┘  └───┘
:8081  :8082
```

## Prerequisites

- Docker (20.10+)
- Docker Compose (2.0+)
- Slack workspace with webhook access

## Quick Start

### 1. Clone Repository

```bash
git clone https://github.com/your-username/blue-green-deployment.git
cd blue-green-deployment
```

### 2. Configure Slack Webhook

1. Go to https://api.slack.com/apps
2. Create new app → "From scratch"
3. Enable "Incoming Webhooks"
4. Add webhook to your workspace
5. Copy webhook URL

### 3. Configure Environment

```bash
# Copy example
cp .env.example .env

# Edit .env
nano .env
```

Required settings:
```bash
BLUE_IMAGE=your-registry/app:blue-tag
GREEN_IMAGE=your-registry/app:green-tag
ACTIVE_POOL=blue
RELEASE_ID_BLUE=blue-release-2025-01-28
RELEASE_ID_GREEN=green-release-2025-01-28
SLACK_WEBHOOK_URL=https://hooks.slack.com/services/YOUR/WEBHOOK/URL
```

### 4. Start Services

```bash
# Start all services
docker-compose up -d

# Check status
docker-compose ps

# View logs
docker-compose logs -f
```

Expected output:
```
NAME             STATUS           PORTS
app_blue         Up (healthy)     0.0.0.0:8081->3000/tcp
app_green        Up (healthy)     0.0.0.0:8082->3000/tcp
nginx_lb         Up               0.0.0.0:8080->80/tcp
alert_watcher    Up               N/A
```

### 5. Verify Setup

```bash
# Test main endpoint
curl -i http://localhost:8080/version

# Should show:
# HTTP/1.1 200 OK
# X-App-Pool: blue
# X-Release-Id: blue-release-2025-01-28
```

## Testing Failover and Alerts

### Test 1: Failover Alert

```bash
# 1. Verify Blue is active
curl http://localhost:8080/version
# X-App-Pool: blue

# 2. Trigger chaos on Blue
curl -X POST http://localhost:8081/chaos/start?mode=error

# 3. Wait 5-10 seconds
sleep 10

# 4. Verify failover to Green
curl http://localhost:8080/version
# X-App-Pool: green

# 5. Check Slack for "Failover Detected" alert

# 6. Stop chaos
curl -X POST http://localhost:8081/chaos/stop

# 7. Wait for recovery (optional)
# You should see "Recovery Detected" alert in Slack
```

### Test 2: High Error Rate Alert

```bash
# Generate errors to trigger error-rate alert
for i in {1..250}; do
  curl -s http://localhost:8080/version > /dev/null &
done

# Monitor watcher logs
docker-compose logs -f alert_watcher

# Check Slack for "High Error Rate" alert
```

### Test 3: View Structured Logs

```bash
# View Nginx logs with pool information
docker-compose exec nginx tail -20 /var/log/nginx/access.log

# Example log line:
# [28/Jan/2025:14:30:22 +0000] method=GET uri=/version status=200 
# pool=blue release=blue-release-2025-01-28 upstream_addr=172.18.0.2:3000 
# upstream_status=200 request_time=0.045 upstream_response_time=0.043
```

## Monitoring and Operations

### View Container Logs

```bash
# All logs
docker-compose logs -f

# Specific service
docker-compose logs -f alert_watcher
docker-compose logs -f nginx
docker-compose logs -f app_blue
docker-compose logs -f app_green
```

### Check Alert Watcher Status

```bash
# View watcher output
docker-compose logs alert_watcher

# Should show:
# 🔍 Blue/Green Log Watcher Started
# 📊 Configuration:
#    - Log File: /var/log/nginx/access.log
#    - Error Rate Threshold: 2.0%
#    - Window Size: 200 requests
#    - Slack Webhook: Configured ✅
```

### Manual Pool Switch

```bash
# Edit .env
ACTIVE_POOL=green

# Restart Nginx
docker-compose up -d nginx

# Verify
curl http://localhost:8080/version
```

### Enable Maintenance Mode

```bash
# Edit .env
MAINTENANCE_MODE=true

# Restart watcher
docker-compose restart alert_watcher

# Alerts are now suppressed
```

## Configuration

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `BLUE_IMAGE` | (required) | Docker image for Blue pool |
| `GREEN_IMAGE` | (required) | Docker image for Green pool |
| `ACTIVE_POOL` | blue | Primary pool (blue or green) |
| `RELEASE_ID_BLUE` | (required) | Version identifier for Blue |
| `RELEASE_ID_GREEN` | (required) | Version identifier for Green |
| `PORT` | 3000 | Application port |
| `SLACK_WEBHOOK_URL` | (required) | Slack incoming webhook URL |
| `ERROR_RATE_THRESHOLD` | 2.0 | Error percentage to trigger alert |
| `WINDOW_SIZE` | 200 | Request window for error rate calculation |
| `ALERT_COOLDOWN_SEC` | 300 | Seconds between duplicate alerts |
| `MAINTENANCE_MODE` | false | Suppress alerts when true |

### Adjusting Alert Sensitivity

**More sensitive (faster alerts)**:
```bash
ERROR_RATE_THRESHOLD=1.0
WINDOW_SIZE=100
```

**Less sensitive (fewer false positives)**:
```bash
ERROR_RATE_THRESHOLD=5.0
WINDOW_SIZE=500
```

## Runbook

For detailed operational procedures, see [runbook.md](runbook.md).

Key sections:
- Failover alert response
- High error rate alert response
- Recovery procedures
- Planned maintenance procedures
- Troubleshooting guide

## API Endpoints

### Application Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/version` | GET | Returns version with pool and release headers |
| `/healthz` | GET | Health check endpoint |
| `/chaos/start` | POST | Start chaos mode (query: `mode=error` or `mode=timeout`) |
| `/chaos/stop` | POST | Stop chaos mode |

### Direct Access

- **Blue**: `http://localhost:8081`
- **Green**: `http://localhost:8082`
- **Nginx (main)**: `http://localhost:8080`

## Troubleshooting

### Slack Alerts Not Working

```bash
# Test webhook manually
curl -X POST $SLACK_WEBHOOK_URL \
  -H 'Content-Type: application/json' \
  -d '{"text":"Test from Blue/Green monitoring"}'

# Check watcher logs
docker-compose logs alert_watcher | grep -i slack
```

### Logs Not Appearing

```bash
# Verify Nginx is writing logs
docker-compose exec nginx ls -l /var/log/nginx/

# Check volume
docker volume ls | grep nginx_logs

# Verify watcher can read logs
docker-compose exec alert_watcher ls -l /var/log/nginx/
```

### High CPU Usage

```bash
# Check container stats
docker stats

# Reduce log processing
# Edit .env:
WINDOW_SIZE=100  # Smaller window
```

## Project Structure

```
.
├── docker-compose.yml          # Service orchestration
├── nginx.conf.template         # Nginx configuration with logging
├── entrypoint.sh              # Nginx config generator
├── watcher.py                 # Log monitoring and alerting
├── requirements.txt           # Python dependencies
├── .env                       # Environment configuration (not in git)
├── .env.example               # Environment template
├── README.md                  # This file
├── runbook.md                 # Operations runbook
└── screenshots/               # Verification screenshots
    ├── failover-alert.png
    ├── error-rate-alert.png
    └── nginx-logs.png
```

## Screenshots

Required screenshots for submission:

1. **Failover Alert**: Slack message showing "Failover Detected" with pool transition
2. **High Error Rate Alert**: Slack message showing error rate above threshold
3. **Nginx Structured Logs**: Terminal showing log lines with pool, release, and timing data

See `screenshots/` directory for examples.

## Cleanup

```bash
# Stop all services
docker-compose down

# Remove volumes (including logs)
docker-compose down -v

# Remove everything
docker-compose down -v --remove-orphans
```

## Stage 2 Compatibility

All Stage 2 functionality is preserved:
- Blue/Green deployment works as before
- Automatic failover on health check failure
- Zero-downtime switching
- Chaos mode testing

Stage 3 adds observability on top without breaking existing behavior.

## Cost and Performance

- **CPU overhead**: ~5% (Python log watcher)
- **Memory overhead**: ~50MB (Python runtime)
- **Log storage**: ~1MB per 10,000 requests
- **Network**: Minimal (only Slack webhooks)

## License

This project is part of the DevOps Intern Stage 3 assessment.

## Support

For issues:
1. Check logs: `docker-compose logs`
2. Review runbook: `runbook.md`
3. Test webhook: `curl -X POST $SLACK_WEBHOOK_URL -d '{"text":"test"}'`
