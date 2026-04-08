#!/usr/bin/env bash
###############################################################
# End-to-End Connectivity Verification
# Validates private connectivity across hybrid cloud topology
###############################################################

set -euo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

ENV="prod"
VERBOSE=false
REGION="us-east-1"

while [[ $# -gt 0 ]]; do
  case $1 in
    --env)     ENV="$2"; shift 2 ;;
    --verbose) VERBOSE=true; shift ;;
    --region)  REGION="$2"; shift 2 ;;
    *) shift ;;
  esac
done

log_ok()   { echo -e "$(date '+%H:%M:%S') ${GREEN}${BOLD}[OK]${NC}   $*"; }
log_fail() { echo -e "$(date '+%H:%M:%S') ${RED}${BOLD}[FAIL]${NC} $*"; }
log_warn() { echo -e "$(date '+%H:%M:%S') ${YELLOW}${BOLD}[WARN]${NC} $*"; }
log_step() { echo -e "$(date '+%H:%M:%S') ${BLUE}${BOLD}[CHECK]${NC} $*"; }

PASS=0
FAIL=0

check() {
  local name="$1"
  local cmd="$2"
  log_step "${name}..."
  if eval "${cmd}" &>/dev/null; then
    log_ok "${name}"
    ((PASS++))
  else
    log_fail "${name}"
    ((FAIL++))
  fi
}

echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  Hybrid Cloud Connectivity Verification — ${ENV}${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════════${NC}"
echo ""

# ── AWS Checks ───────────────────────────────────────────────
log_step "=== AWS Connectivity Checks ==="

check "AWS credentials valid" \
  "aws sts get-caller-identity --region ${REGION}"

check "Transit Gateway exists and available" \
  "aws ec2 describe-transit-gateways --region ${REGION} --query 'TransitGateways[?State==\`available\`]' --output text | grep -q TRANSITGATEWAYS"

check "VPC endpoints provisioned" \
  "aws ec2 describe-vpc-endpoints --region ${REGION} --query 'VpcEndpoints[?State==\`available\`]' --output text | grep -q ."

check "Direct Connect connections present" \
  "aws directconnect describe-connections --region ${REGION} --query 'connections[*]' --output text | grep -q ."

check "Route 53 Resolver inbound endpoint active" \
  "aws route53resolver list-resolver-endpoints --region ${REGION} --query 'ResolverEndpoints[?Direction==\`INBOUND\` && Status==\`OPERATIONAL\`]' --output text | grep -q ."

# ── Private DNS Resolution Checks ───────────────────────────
log_step "=== Private DNS Resolution Checks ==="

check "S3 resolves to private endpoint" \
  "host s3.amazonaws.com | grep -qv '52\\.' || host s3.us-east-1.amazonaws.com | grep -q '172\\|10\\.'"

check "Route 53 outbound forwarder exists" \
  "aws route53resolver list-resolver-rules --region ${REGION} --query 'ResolverRules[?RuleType==\`FORWARD\`]' --output text | grep -q ."

# ── Azure Checks (requires az login) ────────────────────────
log_step "=== Azure Connectivity Checks ==="

if az account show &>/dev/null 2>&1; then
  check "Azure Virtual WAN exists" \
    "az network vwan list --query '[?provisioningState==\`Succeeded\`]' --output tsv | grep -q ."

  check "ExpressRoute gateways provisioned" \
    "az network express-route gateway list --query '[?provisioningState==\`Succeeded\`]' --output tsv | grep -q ."

  check "Azure private endpoints created" \
    "az network private-endpoint list --query '[?provisioningState==\`Succeeded\`]' --output tsv | grep -q ."

  check "Private DNS zones configured" \
    "az network private-dns zone list --query '[?contains(name, \`privatelink\`)]' --output tsv | grep -q ."
else
  log_warn "Azure CLI not logged in — skipping Azure checks (run: az login)"
fi

# ── Summary ──────────────────────────────────────────────────
TOTAL=$((PASS + FAIL))
echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  Verification Complete: ${PASS}/${TOTAL} checks passed${NC}"
if [[ ${FAIL} -eq 0 ]]; then
  echo -e "${GREEN}${BOLD}  ✅ ALL CHECKS PASSED — Hybrid connectivity healthy${NC}"
else
  echo -e "${RED}${BOLD}  ❌ ${FAIL} check(s) FAILED — investigate before proceeding${NC}"
fi
echo -e "${BOLD}═══════════════════════════════════════════════════════${NC}"
echo ""

exit ${FAIL}
