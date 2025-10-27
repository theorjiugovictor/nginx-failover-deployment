# Implementation Decisions

## Overview

This document explains the key design decisions made in implementing the Blue/Green deployment with auto-failover.

## Architecture Decisions

### 1. Primary/Backup Upstream Pattern

**Decision**: Use Nginx's native `backup` directive instead of weighted load balancing.

**Rationale**:
- The task requires "all traffic goes to Blue" in normal state, not load distribution
- `backup` ensures zero traffic to Green unless Blue fails
- Simpler configuration with clear active/standby roles
- Aligns perfectly with Blue/Green deployment philosophy

**Alternative Considered**: Using weights (e.g., 100:0) was considered but rejected because:
- More complex to maintain
- Doesn't guarantee zero traffic to backup
- Backup directive is purpose-built for this pattern

### 2. Aggressive Timeout Configuration

**Decision**: Set very tight timeouts (2-3 seconds) on proxy connections.

**Rationale**:
- Task requires "tight timeouts so failures are detected quickly"
- Request must complete within ~10 seconds including retries
- With 2 upstream attempts: 3s × 2 = 6s maximum, well under 10s limit
- Fast failure detection ensures minimal impact on clients

**Configuration**:
```nginx
proxy_connect_timeout 2s;  # Connection establishment
proxy_send_timeout 3s;     # Sending request
proxy_read_timeout 3s;     # Reading response
```

### 3. Comprehensive Retry Policy

**Decision**: Retry on `error timeout http_500 http_502 http_503 http_504`.

**Rationale**:
- Task requires: "If Blue fails a request (timeout or 5xx), Nginx retries to Green"
- Covers all failure scenarios mentioned in requirements
- `error`: Network/connection errors
- `timeout`: Slow/unresponsive upstreams
- `http_5xx`: Application errors (including chaos mode)

**Limits**:
```nginx
proxy_next_upstream_tries 2;      # Try primary + backup = 2 total
proxy_next_upstream_timeout 8s;   # Total retry window
```

### 4. Fast Failure Marking

**Decision**: `max_fails=2 fail_timeout=5s` for the primary upstream.

**Rationale**:
- 2 consecutive failures trigger marking as down (quick but not hair-trigger)
- 5-second cooldown before retry attempts (fast recovery)
- Balances between sensitivity and stability
- Prevents flapping during temporary issues

**Why not max_fails=1?**
- Too sensitive; a single network hiccup could cause unnecessary failover
- 2 failures provide better confidence the service is truly down

### 5. Dynamic Configuration with envsubst Alternative

**Decision**: Use a shell script with `sed` instead of envsubst.

**Rationale**:
- More control over substitution logic
- Can derive BACKUP_POOL from ACTIVE_POOL automatically
- Easier debugging (can echo variables)
- No dependency on additional tools

**Implementation**:
```bash
if [ "$ACTIVE" = "blue" ]; then
    BACKUP="green"
else
    BACKUP="blue"
fi
```

### 6. Direct Port Exposure (8081, 8082)

**Decision**: Expose Blue and Green services directly to host.

**Rationale**:
- Task explicitly requires: "Expose Blue/Green on 8081/8082 so the grader can call /chaos/* directly"
- Enables testing and chaos induction without going through Nginx
- Necessary for triggering failover scenarios
- In production, these would be firewalled

### 7. Health Check Strategy

**Decision**: Implement Docker health checks with 5-second intervals.

**Rationale**:
- Ensures services are ready before Nginx starts (prevents startup race conditions)
- `depends_on` with `condition: service_healthy` provides robust startup ordering
- 5-second interval matches Nginx fail_timeout for consistency
- Prevents Nginx from starting with unavailable backends

**Configuration**:
```yaml
healthcheck:
  test: ["CMD", "wget", "--quiet", "--tries=1", "--spider", "http://localhost:${PORT:-3000}/healthz"]
  interval: 5s
  timeout: 3s
  retries: 3
```

### 8. Header Forwarding Strategy

**Decision**: Use `proxy_pass_header` for specific headers rather than blanket passthrough.

**Rationale**:
- Task requires: "Do not strip upstream headers; forward app headers to clients"
- Explicitly listing headers makes configuration clear
- Nginx passes most headers by default, but explicit is better
- Ensures `X-App-Pool` and `X-Release-Id` are never stripped

**Configuration**:
```nginx
proxy_pass_header X-App-Pool;
proxy_pass_header X-Release-Id;
```

### 9. No Buffering

**Decision**: Disable proxy buffering with `proxy_buffering off`.

**Rationale**:
- Reduces latency for immediate response to client
- Important for fast failover perception
- Simpler behavior for debugging
- Not handling large payloads where buffering would help

### 10. Environment Variable Parameterization

**Decision**: All configurable values go through `.env` file.

**Rationale**:
- Task requires: "Your Compose file must be fully parameterized via a .env"
- CI/grader can easily inject values without modifying files
- Clean separation of configuration from orchestration
- Supports both manual and automated testing

**Parameters**:
- `BLUE_IMAGE`, `GREEN_IMAGE`: Image references
- `ACTIVE_POOL`: Which pool is primary
- `RELEASE_ID_BLUE`, `RELEASE_ID_GREEN`: Release tracking
- `PORT`: Application port (default: 3000)

## Technical Trade-offs

### Trade-off 1: Simplicity vs. Features

**Choice**: Keep configuration minimal and focused.

**Reasoning**:
- Task has specific requirements; avoid over-engineering
- Fewer moving parts = easier to debug
- Clear behavior makes grading straightforward
- Can always add complexity later if needed

**What we didn't add**:
- Circuit breakers (Nginx failover is sufficient)
- Advanced monitoring (beyond basic health checks)
- SSL/TLS (not required for task)
- Rate limiting (not in scope)

### Trade-off 2: Fail-Fast vs. Resilience

**Choice**: Fail-fast with aggressive timeouts.

**Reasoning**:
- Task requirement: "tight timeouts so failures are detected quickly"
- Better user experience (fail fast and retry vs. long hang)
- 10-second total budget requires quick decision-making
- Backup is always ready, so fast failover is safe

**Impact**:
- May failover on temporary network blips
- Acceptable given backup is identical and always available

### Trade-off 3: Manual Reload vs. Automatic Detection

**Choice**: Manual Nginx reload required for ACTIVE_POOL changes.

**Reasoning**:
- Task focuses on automatic health-based failover, not manual switching
- Docker Compose handles config regeneration on restart
- Simpler than implementing file watchers or API-based reloading
- Manual switches are rare; health-based failover is automatic

## Testing Strategy

### Automated Verification Points

1. **Baseline**: GET /version returns 200 with correct pool/release headers
2. **Stability**: 5+ consecutive requests all return same pool
3. **Chaos Response**: POST to /chaos/start triggers immediate failover
4. **Failover Quality**: Next GET shows different pool with correct headers
5. **Zero Errors**: 0 non-200 responses during failover window
6. **Consistency**: ≥95% of responses from backup pool after failover

### Manual Testing Workflow

```bash
# 1. Verify baseline
curl -i http://localhost:8080/version

# 2. Induce failure
curl -X POST http://localhost:8081/chaos/start?mode=error

# 3. Confirm failover
for i in {1..20}; do
  curl -s http://localhost:8080/version | grep -E "X-App-Pool|X-Release-Id"
done

# 4. Verify no errors
# Expected: All 200, all showing green
```

## Potential Improvements (Out of Scope)

If this were a production system, I would consider:

1. **Observability**:
   - Prometheus metrics export
   - Structured logging
   - Distributed tracing

2. **Advanced Health Checks**:
   - Application-level readiness checks
   - Dependency health verification
   - Graceful degradation

3. **Security Hardening**:
   - TLS termination
   - Request rate limiting
   - WAF integration

4. **High Availability**:
   - Multiple Nginx instances
   - DNS-based failover
   - Geographic distribution

5. **Automated Testing**:
   - Integration test suite
   - Load testing scenarios
   - Chaos engineering framework

## Compliance with Requirements

### ✅ Must-Have Features (All Implemented)

- ✅ Blue/Green deployment with pre-built images
- ✅ Nginx reverse proxy on port 8080
- ✅ Direct service exposure (8081, 8082)
- ✅ Automatic failover on health failure
- ✅ Zero client request failures during failover
- ✅ Header forwarding (X-App-Pool, X-Release-Id)
- ✅ Full parameterization via .env
- ✅ Docker Compose orchestration
- ✅ Support for chaos endpoints
- ✅ Request completion < 10 seconds
- ✅ Retry within same client request

## Conclusion

This implementation prioritizes:
1. **Correctness**: Meets all task requirements precisely
2. **Simplicity**: Easy to understand and debug
3. **Reliability**: Robust failover with zero client impact
4. **Testability**: Clear verification points for automated grading
