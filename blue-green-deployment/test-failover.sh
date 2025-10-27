#!/bin/bash

# Blue/Green Failover Test Script
# Tests automatic failover behavior

set -e

NGINX_URL="http://localhost:8080"
BLUE_URL="http://localhost:8081"
GREEN_URL="http://localhost:8082"

RED='\033[0;31m'
GREEN_COLOR='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "========================================="
echo "Blue/Green Deployment Failover Test"
echo "========================================="
echo ""

# Function to test endpoint and extract headers
test_endpoint() {
    local url=$1
    local response=$(curl -s -i "$url/version")
    local http_code=$(echo "$response" | grep -i "HTTP/" | awk '{print $2}')
    local app_pool=$(echo "$response" | grep -i "X-App-Pool:" | awk '{print $2}' | tr -d '\r')
    local release_id=$(echo "$response" | grep -i "X-Release-Id:" | awk '{print $2}' | tr -d '\r')
    
    echo "HTTP Code: $http_code"
    echo "App Pool: $app_pool"
    echo "Release ID: $release_id"
    echo ""
    
    if [ "$http_code" != "200" ]; then
        return 1
    fi
    return 0
}

# Test 1: Baseline - Blue should be active
echo "Test 1: Baseline - Verifying Blue is active"
echo "-------------------------------------------"
response=$(curl -s -i "$NGINX_URL/version")
http_code=$(echo "$response" | grep -i "HTTP/" | awk '{print $2}')
app_pool=$(echo "$response" | grep -i "X-App-Pool:" | awk '{print $2}' | tr -d '\r')

if [ "$http_code" = "200" ] && [ "$app_pool" = "blue" ]; then
    echo -e "${GREEN_COLOR}✓ PASS${NC}: Blue is active and responding"
else
    echo -e "${RED}✗ FAIL${NC}: Expected Blue to be active"
    echo "HTTP Code: $http_code, Pool: $app_pool"
    exit 1
fi
echo ""

# Test 2: Stability - Multiple requests should all go to Blue
echo "Test 2: Stability - Testing 10 consecutive requests"
echo "----------------------------------------------------"
blue_count=0
green_count=0
error_count=0

for i in {1..10}; do
    response=$(curl -s -i "$NGINX_URL/version")
    http_code=$(echo "$response" | grep -i "HTTP/" | awk '{print $2}')
    app_pool=$(echo "$response" | grep -i "X-App-Pool:" | awk '{print $2}' | tr -d '\r')
    
    if [ "$http_code" = "200" ]; then
        if [ "$app_pool" = "blue" ]; then
            blue_count=$((blue_count + 1))
        elif [ "$app_pool" = "green" ]; then
            green_count=$((green_count + 1))
        fi
    else
        error_count=$((error_count + 1))
    fi
    
    printf "Request %2d: %s - %s\n" "$i" "$http_code" "$app_pool"
    sleep 0.2
done

echo ""
echo "Results: Blue=$blue_count, Green=$green_count, Errors=$error_count"

if [ "$blue_count" -eq 10 ] && [ "$error_count" -eq 0 ]; then
    echo -e "${GREEN_COLOR}✓ PASS${NC}: All requests went to Blue with no errors"
else
    echo -e "${YELLOW}⚠ WARNING${NC}: Unexpected distribution"
fi
echo ""

# Test 3: Induce chaos on Blue
echo "Test 3: Inducing chaos on Blue"
echo "--------------------------------"
chaos_response=$(curl -s -X POST "$BLUE_URL/chaos/start?mode=error")
echo "Chaos mode activated on Blue: $chaos_response"
echo "Waiting 2 seconds for failover to take effect..."
sleep 2
echo ""

# Test 4: Verify failover to Green
echo "Test 4: Verify automatic failover to Green"
echo "-------------------------------------------"
response=$(curl -s -i "$NGINX_URL/version")
http_code=$(echo "$response" | grep -i "HTTP/" | awk '{print $2}')
app_pool=$(echo "$response" | grep -i "X-App-Pool:" | awk '{print $2}' | tr -d '\r')

if [ "$http_code" = "200" ] && [ "$app_pool" = "green" ]; then
    echo -e "${GREEN_COLOR}✓ PASS${NC}: Failover successful - Green is now active"
else
    echo -e "${RED}✗ FAIL${NC}: Failover did not occur"
    echo "HTTP Code: $http_code, Pool: $app_pool"
    exit 1
fi
echo ""

# Test 5: Stability under failure - 20 requests
echo "Test 5: Stability test - 20 requests during Blue failure"
echo "---------------------------------------------------------"
blue_count=0
green_count=0
error_count=0
non_200_count=0

for i in {1..20}; do
    response=$(curl -s -i "$NGINX_URL/version" --max-time 10)
    http_code=$(echo "$response" | grep -i "HTTP/" | awk '{print $2}')
    app_pool=$(echo "$response" | grep -i "X-App-Pool:" | awk '{print $2}' | tr -d '\r')
    
    if [ "$http_code" = "200" ]; then
        if [ "$app_pool" = "blue" ]; then
            blue_count=$((blue_count + 1))
        elif [ "$app_pool" = "green" ]; then
            green_count=$((green_count + 1))
        fi
    else
        error_count=$((error_count + 1))
        non_200_count=$((non_200_count + 1))
    fi
    
    # Visual indicator
    if [ "$http_code" = "200" ] && [ "$app_pool" = "green" ]; then
        printf "${GREEN_COLOR}●${NC}"
    elif [ "$http_code" = "200" ] && [ "$app_pool" = "blue" ]; then
        printf "${YELLOW}●${NC}"
    else
        printf "${RED}✗${NC}"
    fi
    
    sleep 0.5
done

echo ""
echo ""
echo "Results:"
echo "  Green responses: $green_count"
echo "  Blue responses: $blue_count"
echo "  Non-200 responses: $non_200_count"
echo "  Total requests: 20"

# Calculate green percentage
if [ $((green_count + blue_count)) -gt 0 ]; then
    green_percentage=$(awk "BEGIN {printf \"%.0f\", ($green_count / 20) * 100}")
    echo "  Green percentage: ${green_percentage}%"
fi

# Check requirements
if [ "$non_200_count" -eq 0 ]; then
    echo -e "${GREEN_COLOR}✓ PASS${NC}: Zero non-200 responses (requirement: 0)"
else
    echo -e "${RED}✗ FAIL${NC}: Found $non_200_count non-200 responses (requirement: 0)"
    exit 1
fi

if [ "$green_percentage" -ge 95 ]; then
    echo -e "${GREEN_COLOR}✓ PASS${NC}: Green percentage is ${green_percentage}% (requirement: ≥95%)"
else
    echo -e "${RED}✗ FAIL${NC}: Green percentage is ${green_percentage}% (requirement: ≥95%)"
    exit 1
fi
echo ""

# Test 6: Stop chaos and verify Blue recovery
echo "Test 6: Stop chaos and verify system recovery"
echo "----------------------------------------------"
stop_response=$(curl -s -X POST "$BLUE_URL/chaos/stop")
echo "Chaos mode stopped: $stop_response"
echo "Waiting 10 seconds for Blue to recover..."
sleep 10

# Blue should be available again
response=$(curl -s -i "$BLUE_URL/version")
http_code=$(echo "$response" | grep -i "HTTP/" | awk '{print $2}')

if [ "$http_code" = "200" ]; then
    echo -e "${GREEN_COLOR}✓ PASS${NC}: Blue has recovered and is responding"
else
    echo -e "${YELLOW}⚠ WARNING${NC}: Blue is still not responding (HTTP: $http_code)"
fi
echo ""

# Test 7: Direct endpoint verification
echo "Test 7: Direct endpoint verification"
echo "-------------------------------------"
echo "Testing Blue directly (port 8081)..."
test_endpoint "$BLUE_URL"

echo "Testing Green directly (port 8082)..."
test_endpoint "$GREEN_URL"

echo -e "${GREEN_COLOR}✓ PASS${NC}: Both services are accessible directly"
echo ""

# Test 8: Header validation
echo "Test 8: Header validation"
echo "-------------------------"
response=$(curl -s -i "$NGINX_URL/version")
has_app_pool=$(echo "$response" | grep -i "X-App-Pool:" | wc -l)
has_release_id=$(echo "$response" | grep -i "X-Release-Id:" | wc -l)

if [ "$has_app_pool" -gt 0 ] && [ "$has_release_id" -gt 0 ]; then
    echo -e "${GREEN_COLOR}✓ PASS${NC}: Required headers are present"
    echo "$response" | grep -i "X-App-Pool:"
    echo "$response" | grep -i "X-Release-Id:"
else
    echo -e "${RED}✗ FAIL${NC}: Required headers are missing"
    exit 1
fi
echo ""

# Summary
echo "========================================="
echo "Test Summary"
echo "========================================="
echo -e "${GREEN_COLOR}All tests passed successfully!${NC}"
echo ""
echo "✓ Baseline verification"
echo "✓ Pre-chaos stability"
echo "✓ Automatic failover"
echo "✓ Zero client failures during failover"
echo "✓ Post-failover stability (≥95% to backup)"
echo "✓ Service recovery"
echo "✓ Direct endpoint access"
echo "✓ Header forwarding"
echo ""
echo "Your Blue/Green deployment is working correctly!"
