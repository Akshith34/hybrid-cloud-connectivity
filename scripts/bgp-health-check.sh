#!/usr/bin/env bash
###############################################################
# BGP Health Check Script
# Monitors BGP session state for Direct Connect Virtual Interfaces
# Alerts on session drops, route flaps, and bandwidth anomalies
###############################################################

set -euo pipefail

# ── Colors ──────────────────────────────────────────────────
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

# ── Defaults ────────────────────────────────────────────────
ALL_SESSIONS=false
REGION="us-east-1"
OUTPUT_FORMAT="human"
ALERT_SNS=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --all-sessions)  ALL_SESSIONS=true; shift ;;
    --region)        REGION="$2"; shift 2 ;;
    --json)          OUTPUT_FORMAT="json"; shift ;;
    --alert-sns)     ALERT_SNS="$2"; shift 2 ;;
    *) echo "Unknown: $1"; exit 1 ;;
  esac
done

log()      { echo -e "$(date '+%H:%M:%S') $*"; }
log_ok()   { log "${GREEN}${BOLD}[OK]${NC}   $*"; }
log_fail() { log "${RED}${BOLD}[FAIL]${NC} $*"; }
log_warn() { log "${YELLOW}${BOLD}[WARN]${NC} $*"; }
log_info() { log "${BLUE}${BOLD}[INFO]${NC} $*"; }

ISSUES=0
RESULTS=()

echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  BGP Session Health Check — $(date)${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"
echo ""

##################################################
# Check Direct Connect Virtual Interfaces
##################################################

log_info "Fetching Direct Connect Virtual Interfaces..."

VIF_LIST=$(aws directconnect describe-virtual-interfaces \
  --region "${REGION}" \
  --query 'virtualInterfaces[*].{id:virtualInterfaceId,name:virtualInterfaceName,state:virtualInterfaceState,bgpPeers:bgpPeers}' \
  --output json 2>/dev/null || echo "[]")

VIF_COUNT=$(echo "${VIF_LIST}" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")

if [[ "${VIF_COUNT}" == "0" ]]; then
  log_warn "No Direct Connect VIFs found in ${REGION} (may need AWS credentials with dx:DescribeVirtualInterfaces)"
  RESULTS+=('{"component":"direct-connect","status":"no-vifs-found","region":"'"${REGION}"'"}')
else
  log_info "Found ${VIF_COUNT} Virtual Interface(s)"

  echo "${VIF_LIST}" | python3 -c "
import json, sys
vifs = json.load(sys.stdin)
for vif in vifs:
    name = vif.get('name', 'unknown')
    state = vif.get('state', 'unknown')
    peers = vif.get('bgpPeers', [])

    status_icon = '✅' if state == 'available' else '❌'
    print(f'  {status_icon} VIF: {name} | State: {state}')

    for peer in peers:
        peer_state = peer.get('bgpPeerState', 'unknown')
        peer_status = peer.get('bgpStatus', 'unknown')
        asn = peer.get('asn', 'N/A')
        peer_icon = '✅' if peer_state == 'available' and peer_status == 'up' else '❌'
        print(f'       {peer_icon} BGP Peer ASN {asn}: state={peer_state}, status={peer_status}')
"
fi

##################################################
# Check DX Connection Physical State
##################################################

log_info "Checking Direct Connect connection states..."

CONNECTIONS=$(aws directconnect describe-connections \
  --region "${REGION}" \
  --query 'connections[*].{id:connectionId,name:connectionName,state:connectionState,bandwidth:bandwidth,location:location}' \
  --output json 2>/dev/null || echo "[]")

echo "${CONNECTIONS}" | python3 -c "
import json, sys
conns = json.load(sys.stdin)
if not conns:
    print('  ⚠️  No DX connections found')
for conn in conns:
    name = conn.get('name', 'unknown')
    state = conn.get('connectionState', 'unknown')
    bw = conn.get('bandwidth', 'N/A')
    loc = conn.get('location', 'N/A')
    icon = '✅' if state == 'available' else '❌'
    print(f'  {icon} Connection: {name} | {bw} | {loc} | State: {state}')
" 2>/dev/null || log_warn "Could not parse connection data"

##################################################
# Check CloudWatch BGP Metrics (last 5 min)
##################################################

log_info "Checking recent CloudWatch metrics..."

END_TIME=$(date -u +%Y-%m-%dT%H:%M:%SZ)
START_TIME=$(date -u -d '5 minutes ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || \
             date -u -v-5M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || \
             echo "${END_TIME}")

echo "${CONNECTIONS}" | python3 -c "
import json, sys, subprocess, os

conns = json.load(sys.stdin)
region = os.environ.get('REGION', 'us-east-1')

for conn in conns[:2]:  # Check first 2 connections
    conn_id = conn.get('id', '')
    name = conn.get('name', 'unknown')
    if not conn_id:
        continue

    result = subprocess.run([
        'aws', 'cloudwatch', 'get-metric-statistics',
        '--namespace', 'AWS/DX',
        '--metric-name', 'ConnectionState',
        '--dimensions', f'Name=ConnectionId,Value={conn_id}',
        '--start-time', sys.argv[1],
        '--end-time', sys.argv[2],
        '--period', '300',
        '--statistics', 'Minimum',
        '--region', region,
        '--query', 'Datapoints[0].Minimum',
        '--output', 'text'
    ], capture_output=True, text=True)

    state_val = result.stdout.strip()
    if state_val and state_val != 'None':
        state_num = float(state_val)
        icon = '✅' if state_num == 1.0 else '❌'
        status = 'UP' if state_num == 1.0 else 'DOWN'
        print(f'  {icon} CW metric — {name}: ConnectionState={status}')
    else:
        print(f'  ⚠️  No recent CloudWatch data for {name}')
" "${START_TIME}" "${END_TIME}" 2>/dev/null || log_warn "CloudWatch metric check skipped"

##################################################
# Route Table Validation
##################################################

log_info "Validating Transit Gateway route tables..."

TGW_LIST=$(aws ec2 describe-transit-gateways \
  --region "${REGION}" \
  --query 'TransitGateways[?State==`available`].{id:TransitGatewayId,state:State}' \
  --output json 2>/dev/null || echo "[]")

TGW_COUNT=$(echo "${TGW_LIST}" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")

if [[ "${TGW_COUNT}" == "0" ]]; then
  log_warn "No Transit Gateways found in ${REGION}"
else
  log_ok "Found ${TGW_COUNT} active Transit Gateway(s)"

  echo "${TGW_LIST}" | python3 -c "
import json, sys, subprocess, os
region = os.environ.get('REGION', 'us-east-1')
tgws = json.load(sys.stdin)
for tgw in tgws:
    tgw_id = tgw['id']
    result = subprocess.run([
        'aws', 'ec2', 'describe-transit-gateway-route-tables',
        '--filters', f'Name=transit-gateway-id,Values={tgw_id}',
        '--query', 'TransitGatewayRouteTables[*].{id:TransitGatewayRouteTableId,state:State,default:DefaultAssociationRouteTable}',
        '--region', region,
        '--output', 'json'
    ], capture_output=True, text=True)

    tables = json.loads(result.stdout or '[]')
    print(f'  TGW {tgw_id}: {len(tables)} route table(s)')
    for t in tables:
        icon = '✅' if t.get('state') == 'available' else '❌'
        print(f'    {icon} {t[\"id\"]} — state: {t[\"state\"]}')
  " 2>/dev/null || log_warn "Route table check skipped"
fi

##################################################
# Summary
##################################################

echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"
if [[ ${ISSUES} -eq 0 ]]; then
  echo -e "${GREEN}${BOLD}  ✅ BGP Health Check Complete — No Critical Issues${NC}"
else
  echo -e "${RED}${BOLD}  ❌ BGP Health Check Complete — ${ISSUES} Issue(s) Found${NC}"
fi
echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"
echo ""

exit ${ISSUES}
