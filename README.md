# Blue/Green Deployment with Nginx Auto-Failover

This project implements a Blue/Green deployment strategy with automatic failover using Nginx as a reverse proxy and load balancer.

## Overview

The system deploys two identical Node.js service instances (Blue and Green) behind Nginx. Traffic is routed to the active pool (default: Blue), and automatically fails over to the backup pool (Green) when the active pool becomes unhealthy.

## Architecture

```
┌─────────┐
│ Client  │
└────┬────┘
     │ :8080
     ▼
┌─────────────┐
│   Nginx     │
│  (Port 80)  │
└──┬──────┬───┘
   │      │
   │      └─────────────┐
   │ Primary           │ Backup
   ▼                   ▼
┌──────────┐      ┌──────────┐
│   Blue   │      │  Green   │
│ :8081    │      │ :8082    │
│ (active) │      │ (backup) │
└──────────┘      └──────────┘
```

## Prerequisites

- Docker Engine (20.10+)
- Docker Compose (2.0+)
- Pre-built application images accessible from your registry

## Quick Start

### 1. Clone and Configure

```bash
# Edit .env with your image references
nano .env
```

### 2. Configure Environment Variables

Edit `.env` file:

```bash
# Required: Specify your Docker images
BLUE_IMAGE=your-registry/app:blue-tag
GREEN_IMAGE=your-registry/app:green-tag

# Set active pool (blue or green)
ACTIVE_POOL=blue

# Release identifiers for tracking
RELEASE_ID_BLUE=blue-release-v1.0.0
RELEASE_ID_GREEN=green-release-v1.0.0

# Optional: Application port (default: 3000)
PORT=3000
```

### 3. Start Services

```bash
# Start all services
docker-compose up -d

# Check status
docker-compose ps

# View logs
docker-compose logs -f
```

### 4. Verify Deployment

```bash
# Test the version endpoint
curl -i http://localhost:8080/version

# Expected response headers:
# X-App-Pool: blue
# X-Release-Id: blue-release-v1.0.0
```

## Testing Failover

### Automatic Failover Test

```bash
# 1. Verify Blue is active
curl http://localhost:8080/version
# Should show X-App-Pool: blue

# 2. Trigger chaos on Blue (induce errors)
curl -X POST http://localhost:8081/chaos/start?mode=error

# 3. Immediately test failover
curl http://localhost:8080/version
# Should now show X-App-Pool: green

# 4. Verify stability (run multiple requests)
for i in {1..20}; do
  curl -s http://localhost:8080/version | grep -E "X-App-Pool|X-Release-Id"
  sleep 0.5
done

# 5. Stop chaos
curl -X POST http://localhost:8081/chaos/stop
```

### Test Timeout Failover

```bash
# Trigger timeout mode
curl -X POST http://localhost:8081/chaos/start?mode=timeout

# Test requests continue to work via Green
curl http://localhost:8080/version
```

## API Endpoints

### Application Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/version` | GET | Returns version info with pool and release headers |
| `/healthz` | GET | Health check endpoint |
| `/chaos/start` | POST | Start chaos simulation (query param: `mode=error` or `mode=timeout`) |
| `/chaos/stop` | POST | Stop chaos simulation |

### Direct Access (for testing)

- Blue service: `http://localhost:8081`
- Green service: `http://localhost:8082`
- Nginx proxy: `http://localhost:8080`

## Switching Active Pool

To manually switch the active pool:

```bash
# Method 1: Edit .env and restart
nano .env  # Change ACTIVE_POOL=green
docker-compose up -d nginx  # Restart only nginx

# Method 2: Use environment override
ACTIVE_POOL=green docker-compose up -d nginx
```

## Nginx Configuration Details

### Failover Mechanism

The Nginx configuration implements automatic failover with:

- **Primary/Backup Pattern**: Active pool is primary, other is backup
- **Fast Failure Detection**: 
  - `max_fails=2`: Mark unhealthy after 2 failures
  - `fail_timeout=5s`: Quick recovery check interval
- **Aggressive Timeouts**:
  - Connection: 2s
  - Send: 3s
  - Read: 3s
- **Retry Policy**: Retries on error, timeout, and 5xx responses
- **Zero-Downtime**: Backup takes over within the same request

### Header Forwarding

All application headers are preserved and forwarded to clients:
- `X-App-Pool`: Identifies which pool served the request
- `X-Release-Id`: Tracks the release version

## Monitoring

### Check Service Health

```bash
# Check all containers
docker-compose ps

# Check specific service logs
docker-compose logs app_blue
docker-compose logs app_green
docker-compose logs nginx

# Check Nginx status
curl http://localhost:8080/nginx_status
```

### Verify Health Checks

```bash
# Direct health checks
curl http://localhost:8081/healthz  # Blue
curl http://localhost:8082/healthz  # Green
```

## Troubleshooting

### Issue: Services not starting

```bash
# Check container status
docker-compose ps

# View detailed logs
docker-compose logs --tail=50

# Restart services
docker-compose restart
```

### Issue: Failover not working

```bash
# Verify Nginx configuration
docker-compose exec nginx cat /etc/nginx/nginx.conf

# Test configuration
docker-compose exec nginx nginx -t

# Reload configuration
docker-compose exec nginx nginx -s reload
```

### Issue: Headers not showing

```bash
# Use verbose curl to see all headers
curl -v http://localhost:8080/version

# Check if services are setting headers correctly
curl -v http://localhost:8081/version  # Direct Blue
curl -v http://localhost:8082/version  # Direct Green
```

## Cleanup

```bash
# Stop and remove all containers
docker-compose down

# Remove containers and volumes
docker-compose down -v

# Remove containers, volumes, and networks
docker-compose down -v --remove-orphans
```

## Performance Characteristics

- **Failover Time**: < 5 seconds (typically 2-3s)
- **Zero Failed Requests**: Retry mechanism ensures client requests succeed
- **Request Timeout**: Maximum 8-10 seconds total (including retries)
- **Health Check Interval**: Every 5 seconds

## CI/CD Integration

The setup is designed for automated testing:

```bash
# CI can set environment variables
export BLUE_IMAGE=registry/app:commit-abc123
export GREEN_IMAGE=registry/app:commit-abc123
export ACTIVE_POOL=blue
export RELEASE_ID_BLUE=build-123
export RELEASE_ID_GREEN=build-123

# Run deployment
docker-compose up -d

# Wait for healthy state
sleep 15

# Run automated tests
./test-failover.sh
```

## Security Considerations

- Services are isolated in a Docker bridge network
- Only Nginx is exposed to the host
- Direct service ports (8081, 8082) should be firewalled in production
- Use HTTPS termination at Nginx for production deployments

## Project Structure

```
.
├── docker-compose.yml       # Service orchestration
├── nginx.conf.template      # Nginx configuration template
├── entrypoint.sh           # Dynamic config generation script
├── .env.example            # Environment variables template
├── README.md               # This file
└── DECISION.md             # Implementation decisions (optional)
```

## License

This project is part of the DevOps Intern Stage 2 assessment.

## Support

For issues or questions:
1. Check container logs: `docker-compose logs`
2. Verify configuration: `docker-compose config`
3. Test Nginx config: `docker-compose exec nginx nginx -t`
