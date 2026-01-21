#!/bin/bash

# Cilium Network Policy Validation Script
# This script validates that CiliumNetworkPolicy and host firewall are properly configured

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

PASSED=0
FAILED=0
WARNINGS=0

echo "================================================"
echo "Cilium Network Policy Validation"
echo "================================================"
echo ""

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
    echo -e "${RED}✗ kubectl not found${NC}"
    exit 1
fi

# Check if cilium CLI is available
if ! command -v cilium &> /dev/null; then
    echo -e "${RED}✗ cilium CLI not found${NC}"
    exit 1
fi

# Function to check resource existence
check_resource() {
    local resource=$1
    local name=$2
    local namespace=${3:-"--all-namespaces"}

    if kubectl get $resource $name $namespace &> /dev/null; then
        echo -e "${GREEN}✓${NC} $resource '$name' exists"
        ((PASSED++))
        return 0
    else
        echo -e "${RED}✗${NC} $resource '$name' not found"
        ((FAILED++))
        return 1
    fi
}

# 1. Validate Cilium is running
echo "1. Checking Cilium Installation"
echo "--------------------------------"
if kubectl get deployment -n kube-system cilium &> /dev/null; then
    echo -e "${GREEN}✓${NC} Cilium deployment found"
    ((PASSED++))
else
    echo -e "${RED}✗${NC} Cilium deployment not found"
    ((FAILED++))
fi

if kubectl get daemonset -n kube-system cilium &> /dev/null; then
    echo -e "${GREEN}✓${NC} Cilium daemonset found"
    ((PASSED++))
else
    echo -e "${RED}✗${NC} Cilium daemonset not found"
    ((FAILED++))
fi

echo ""

# 2. Check ClusterWide Policies
echo "2. Validating CiliumClusterwideNetworkPolicy"
echo "---------------------------------------------"

CCNP_COUNT=$(kubectl get ccnp --no-headers 2>/dev/null | wc -l)
if [ $CCNP_COUNT -gt 0 ]; then
    echo -e "${GREEN}✓${NC} Found $CCNP_COUNT CiliumClusterwideNetworkPolicy resources"
    ((PASSED++))
    kubectl get ccnp --no-headers | while read name _; do
        echo "  - $name"
    done
else
    echo -e "${RED}✗${NC} No CiliumClusterwideNetworkPolicy resources found"
    ((FAILED++))
fi

echo ""

# 3. Check Network Policies exist
echo "3. Validating CiliumNetworkPolicy Resources"
echo "--------------------------------------------"

required_policies=(
    "default-deny-ingress:default"
    "allow-flux-system-internal:flux-system"
    "allow-kube-system-metrics:default"
    "allow-cilium-internal:kube-system"
    "allow-traefik-dmz:kube-system"
    "allow-monitoring-scrape:monitoring"
)

for policy in "${required_policies[@]}"; do
    IFS=':' read -r name namespace <<< "$policy"
    check_resource "cnp" "$name" "-n $namespace" || true
done

echo ""

# 4. Check policy enforcement mode
echo "4. Checking Policy Enforcement Configuration"
echo "---------------------------------------------"
ENFORCEMENT=$(kubectl get cm -n kube-system cilium-config -o jsonpath='{.data.enable-policy}' 2>/dev/null)
if [ "$ENFORCEMENT" = "default" ]; then
    echo -e "${GREEN}✓${NC} Policy enforcement mode: $ENFORCEMENT (enabled)"
    ((PASSED++))
else
    echo -e "${YELLOW}⚠${NC} Policy enforcement mode: $ENFORCEMENT"
    ((WARNINGS++))
fi

echo ""

# 5. Check host firewall configuration
echo "5. Validating Host Firewall Configuration"
echo "------------------------------------------"
HOST_FW=$(kubectl get cm -n kube-system cilium-config -o jsonpath='{.data.enable-host-firewall}' 2>/dev/null)
if [ "$HOST_FW" = "true" ]; then
    echo -e "${GREEN}✓${NC} Host firewall: enabled"
    ((PASSED++))
else
    echo -e "${YELLOW}⚠${NC} Host firewall: disabled"
    ((WARNINGS++))
fi

echo ""

# 6. Check Cilium identity allocation
echo "6. Validating Cilium Identity Allocation"
echo "----------------------------------------"
IDENTITY_MODE=$(kubectl get cm -n kube-system cilium-config -o jsonpath='{.data.identity-allocation-mode}' 2>/dev/null)
if [ "$IDENTITY_MODE" = "crd" ]; then
    echo -e "${GREEN}✓${NC} Identity allocation mode: $IDENTITY_MODE"
    ((PASSED++))
else
    echo -e "${YELLOW}⚠${NC} Identity allocation mode: $IDENTITY_MODE"
    ((WARNINGS++))
fi

echo ""

# 7. Check pod labels for network zones
echo "7. Validating Pod Network Zone Labels"
echo "-------------------------------------"
for zone in trusted dmz untrusted monitoring; do
    pod_count=$(kubectl get pods -A -l network-zone=$zone --no-headers 2>/dev/null | wc -l)
    if [ $pod_count -gt 0 ]; then
        echo -e "${GREEN}✓${NC} Found $pod_count pods labeled for zone: $zone"
        ((PASSED++))
    else
        echo -e "${YELLOW}⚠${NC} No pods labeled for zone: $zone"
        ((WARNINGS++))
    fi
done

echo ""

# 8. Test connectivity with simple pod
echo "8. Testing Basic Connectivity"
echo "-----------------------------"

# Check if a test pod can reach coredns
if kubectl run -q cilium-policy-test --image=alpine --restart=Never --rm -- \
    wget -q -O- http://coredns.kube-system.svc.cluster.local:5053 &> /dev/null 2>&1; then
    echo -e "${GREEN}✓${NC} Pod can reach kube-system services (DNS working)"
    ((PASSED++))
else
    echo -e "${YELLOW}⚠${NC} Pod cannot reach kube-system services"
    ((WARNINGS++))
fi

echo ""

# 9. Verify Hubble is running
echo "9. Checking Hubble Observability"
echo "--------------------------------"
HUBBLE_ENABLED=$(kubectl get cm -n kube-system cilium-config -o jsonpath='{.data.enable-hubble}' 2>/dev/null)
if [ "$HUBBLE_ENABLED" = "true" ]; then
    echo -e "${GREEN}✓${NC} Hubble enabled"
    ((PASSED++))

    HUBBLE_UI=$(kubectl get deployment -n kube-system hubble-ui 2>/dev/null | grep -q hubble-ui && echo "1" || echo "0")
    if [ $HUBBLE_UI -eq 1 ]; then
        echo -e "${GREEN}✓${NC} Hubble UI deployment found"
        ((PASSED++))
    else
        echo -e "${YELLOW}⚠${NC} Hubble UI deployment not found"
        ((WARNINGS++))
    fi
else
    echo -e "${RED}✗${NC} Hubble not enabled"
    ((FAILED++))
fi

echo ""

# 10. Check Cilium agent health
echo "10. Checking Cilium Agent Health"
echo "--------------------------------"
CILIUM_HEALTHY=$(cilium status 2>/dev/null | grep -q "ok" && echo "1" || echo "0")
if [ $CILIUM_HEALTHY -eq 1 ]; then
    echo -e "${GREEN}✓${NC} Cilium agent status healthy"
    ((PASSED++))
else
    echo -e "${YELLOW}⚠${NC} Cilium agent status may have issues"
    echo "  Run: cilium status"
    ((WARNINGS++))
fi

echo ""

# 11. Verify policy statistics
echo "11. Checking Policy Statistics"
echo "-----------------------------"
if cilium policy get --stats &> /dev/null; then
    echo -e "${GREEN}✓${NC} Policy statistics available"
    ((PASSED++))

    # Get denied packet count
    DENIED=$(cilium policy get --stats 2>/dev/null | grep -i "denied" | wc -l)
    if [ $DENIED -gt 0 ]; then
        echo -e "${YELLOW}⚠${NC} Found $DENIED denied policy entries (expected after cluster usage)"
        ((WARNINGS++))
    fi
else
    echo -e "${RED}✗${NC} Policy statistics unavailable"
    ((FAILED++))
fi

echo ""

# 12. Summary
echo "================================================"
echo "Validation Summary"
echo "================================================"
echo -e "Passed:  ${GREEN}$PASSED${NC}"
echo -e "Warnings: ${YELLOW}$WARNINGS${NC}"
echo -e "Failed:  ${RED}$FAILED${NC}"
echo ""

if [ $FAILED -eq 0 ]; then
    echo -e "${GREEN}✓ All critical checks passed!${NC}"
    if [ $WARNINGS -eq 0 ]; then
        echo -e "${GREEN}✓ No warnings.${NC}"
    else
        echo -e "${YELLOW}⚠ $WARNINGS warnings - review above${NC}"
    fi
    exit 0
else
    echo -e "${RED}✗ $FAILED checks failed - review above${NC}"
    exit 1
fi
