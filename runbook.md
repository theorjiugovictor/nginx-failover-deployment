# Blue/Green Deployment Operations Runbook

## Alert Types and Response Procedures

### 1. Failover Detected Alert

**Alert Example**:
```
🚨 Failover Detected
Traffic has switched from blue to green

Previous Pool: blue
Current Pool: green
Release: green-release-2025-01-28
Upstream: 172.18.0.3:3000
Timestamp: 28/Jan/2025:14:30:22 +0000
```

**What It Means**:
- The system automatically switched from the primary pool (Blue) to the backup pool (Green)
- This happens when the primary pool fails health checks or returns errors
- Traffic is now being served by the backup pool

**Operator Actions**:

1. **Investigate Primary Pool Health** (Immediate - 2 minutes)
   ```bash
   # Check Blue container logs
   docker-compose logs --tail=100 app_blue
   
   # Check Blue container status
   docker-compose ps app_blue
   
   # Test Blue directly
   curl -i http://localhost:8081/healthz
   curl -i http://localhost:8081/version
   ```

2. **Verify Backup Pool is Serving Traffic** (Immediate - 1 minute)
   ```bash
   # Test through Nginx
   curl -i http://localhost:8080/version
   # Should show: X-App-Pool: green
   
   # Run multiple requests to confirm stability
   for i in {1..10}; do curl -s http://localhost:8080/version | grep pool; done
   ```

3. **Determine Root Cause** (5-10 minutes)
   - Check application logs for errors
   - Check resource utilization: `docker stats app_blue`
   - Review recent deployments or changes
   - Check external dependencies (database, API calls)

4. **Decide on Action**:
   - **If transient issue**: Wait for automatic recovery (5-10 minutes)
   - **If persistent issue**: Investigate and fix before switching back
   - **If critical bug**: Keep traffic on Green, fix Blue offline

**Recovery Verification**:
```bash
# After fixing Blue, verify it's healthy
curl http://localhost:8081/healthz

# You should see a "Recovery Detected" alert in Slack when traffic returns to Blue
```

---

### 2. High Error Rate Alert

**Alert Example**:
```
🚨 High Error Rate
Error rate has exceeded threshold: 5.50%

Error Rate: 5.50%
Threshold: 2.0%
Errors: 11
Window Size: 200
Action: Check upstream container logs
```

**What It Means**:
- More than 2% of requests (default threshold) are returning 5xx errors
- This could indicate:
  - Application bugs
  - Resource exhaustion (CPU, memory)
  - External dependency failures
  - Database connection issues

**Operator Actions**:

1. **Check Current Error Rate** (Immediate - 1 minute)
   ```bash
   # View recent Nginx logs
   docker-compose logs --tail=50 nginx
   
   # Check which pool is serving errors
   docker-compose logs --tail=100 alert_watcher | grep "Error:"
   ```

2. **Identify Failing Pool** (Immediate - 2 minutes)
   ```bash
   # Check Blue logs
   docker-compose logs --tail=100 app_blue | grep -i error
   
   # Check Green logs
   docker-compose logs --tail=100 app_green | grep -i error
   ```

3. **Check Resource Usage** (2 minutes)
   ```bash
   # Monitor container resources
   docker stats --no-stream
   
   # Check if containers are restarting
   docker-compose ps
   ```

4. **Investigate Application Issues** (5-15 minutes)
   - Review application error logs
   - Check database connectivity
   - Verify external API availability
   - Look for recent code changes that might have introduced bugs

5. **Immediate Mitigation Options**:

   **Option A: Manual Failover (if one pool is healthy)**
   ```bash
   # If Blue is causing errors, switch to Green
   # Edit .env and change:
   ACTIVE_POOL=green
   
   # Restart Nginx only
   docker-compose up -d nginx
   ```

   **Option B: Rollback (if recent deployment)**
   ```bash
   # Revert to previous working image
   # Edit .env with previous image tags
   docker-compose pull
   docker-compose up -d app_blue app_green
   ```

   **Option C: Scale Down (if resource issue)**
   ```bash
   # Restart affected container
   docker-compose restart app_blue
   ```

**Post-Incident Actions**:
- Document root cause
- Create incident report
- Implement fixes to prevent recurrence
- Consider adjusting ERROR_RATE_THRESHOLD if too sensitive

---

### 3. Recovery Detected Alert

**Alert Example**:
```
🚨 Recovery Detected
Primary pool blue has recovered and is serving traffic

Recovered Pool: blue
Status: Healthy
Action: No action required
```

**What It Means**:
- The primary pool has recovered from its failure
- Traffic has automatically switched back to the primary pool
- System is back to normal operation

**Operator Actions**:

1. **Verify System Stability** (2-3 minutes)
   ```bash
   # Check all containers are healthy
   docker-compose ps
   
   # Run stability test
   for i in {1..20}; do 
     curl -s http://localhost:8080/version | grep pool
     sleep 1
   done
   ```

2. **Monitor for Recurrence** (10-15 minutes)
   - Watch Slack for any new alerts
   - Monitor logs: `docker-compose logs -f`
   - Keep eye on error rates

3. **Document Incident** (15-30 minutes)
   - Record what failed
   - Document how long failover lasted
   - Note any manual interventions
   - Update runbook if needed

**No immediate action required**, but maintain vigilance.

---

## Planned Maintenance Procedures

### Suppressing Alerts During Maintenance

When performing planned maintenance or pool switches, enable maintenance mode to prevent alert spam:

```bash
# Enable maintenance mode
# Edit .env:
MAINTENANCE_MODE=true

# Restart alert watcher
docker-compose restart alert_watcher

# Perform your maintenance...

# Disable maintenance mode when done
# Edit .env:
MAINTENANCE_MODE=false

# Restart alert watcher
docker-compose restart alert_watcher
```

### Manual Pool Switch (Planned)

```bash
# 1. Enable maintenance mode
echo "MAINTENANCE_MODE=true" >> .env
docker-compose restart alert_watcher

# 2. Switch active pool
# Edit .env:
ACTIVE_POOL=green

# 3. Restart Nginx
docker-compose up -d nginx

# 4. Verify switch
curl -i http://localhost:8080/version
# Should show X-App-Pool: green

# 5. Disable maintenance mode
sed -i 's/MAINTENANCE_MODE=true/MAINTENANCE_MODE=false/' .env
docker-compose restart alert_watcher
```

---

## Testing and Validation

### Testing Failover Alert

```bash
# 1. Verify baseline
curl http://localhost:8080/version
# Should show Blue

# 2. Trigger chaos on Blue
curl -X POST http://localhost:8081/chaos/start?mode=error

# 3. Wait 5 seconds
sleep 5

# 4. Check Slack for failover alert

# 5. Verify Green is serving
curl http://localhost:8080/version
# Should show Green

# 6. Stop chaos
curl -X POST http://localhost:8081/chaos/stop
```

### Testing Error Rate Alert

```bash
# Generate high error rate
for i in {1..50}; do
  curl http://localhost:8080/version &
done

# Wait for error rate alert in Slack
```

### Viewing Structured Logs

```bash
# View recent Nginx logs with pool info
docker-compose exec nginx tail -20 /var/log/nginx/access.log

# View watcher output
docker-compose logs -f alert_watcher

# View specific pool logs
docker-compose logs -f app_blue
docker-compose logs -f app_green
```

---

## Configuration Reference

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `SLACK_WEBHOOK_URL` | (required) | Slack incoming webhook URL |
| `ERROR_RATE_THRESHOLD` | 2.0 | Error rate percentage to trigger alert |
| `WINDOW_SIZE` | 200 | Number of requests in sliding window |
| `ALERT_COOLDOWN_SEC` | 300 | Seconds between same alert types |
| `MAINTENANCE_MODE` | false | Suppress alerts when true |
| `ACTIVE_POOL` | blue | Which pool is primary |

### Adjusting Alert Sensitivity

**If getting too many false positives**:
```bash
# Increase error rate threshold
ERROR_RATE_THRESHOLD=5.0

# Increase window size (more data before alerting)
WINDOW_SIZE=500

# Increase cooldown period
ALERT_COOLDOWN_SEC=600
```

**If alerts are too slow**:
```bash
# Decrease error rate threshold
ERROR_RATE_THRESHOLD=1.0

# Decrease window size (alert faster)
WINDOW_SIZE=100
```

---

## Troubleshooting

### Alert Not Appearing in Slack

**Check 1: Webhook URL**
```bash
# Test webhook directly
curl -X POST ${SLACK_WEBHOOK_URL} \
  -H 'Content-Type: application/json' \
  -d '{"text":"Test alert from Blue/Green monitoring"}'
```

**Check 2: Watcher is Running**
```bash
docker-compose ps alert_watcher
# Should show "Up"

docker-compose logs alert_watcher
# Should show "Log watcher started"
```

**Check 3: Cooldown Period**
```bash
# Check if in cooldown
docker-compose logs alert_watcher | grep "cooldown"
```

### Logs Not Being Generated

**Check 1: Nginx is Writing Logs**
```bash
docker-compose exec nginx ls -l /var/log/nginx/
# Should show access.log with recent timestamp

docker-compose exec nginx tail /var/log/nginx/access.log
```

**Check 2: Volume Mount**
```bash
# Verify shared volume
docker volume ls | grep nginx_logs

# Check watcher can read logs
docker-compose exec alert_watcher ls -l /var/log/nginx/
```

### Failover Not Detected

**Check 1: Pool Information in Logs**
```bash
# Verify logs contain pool info
docker-compose exec nginx tail -5 /var/log/nginx/access.log
# Should see "pool=blue" or "pool=green"
```

**Check 2: Watcher Parsing**
```bash
# Check watcher logs for parse errors
docker-compose logs alert_watcher | grep -i error
```

---

## Emergency Contacts

- **DevOps Team**: #devops-alerts Slack channel
- **On-Call Engineer**: Check PagerDuty
- **Escalation**: Check team runbook for escalation path

---

## Revision History

| Date | Version | Changes |
|------|---------|---------|
| 2025-01-28 | 1.0 | Initial runbook creation |
