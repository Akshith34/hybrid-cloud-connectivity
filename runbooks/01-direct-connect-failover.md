# Runbook: Direct Connect Circuit Failover
**Severity**: P1 | **RTO Target**: <30 minutes | **Impact**: On-premises to AWS connectivity degraded

> **When to use**: Primary Direct Connect circuit has failed or is showing degraded performance. BGP session is down or flapping on primary VIF.

---

## Pre-Conditions: When to Use This Runbook

Trigger when **ANY** of the following fire:
- [ ] PagerDuty: `dx-primary-connection-down` alarm
- [ ] PagerDuty: `dx-primary-bgp-session-down` alarm
- [ ] Network team reports loss of connectivity from on-premises to AWS VPCs
- [ ] CloudWatch `ConnectionState` metric = 0 for primary DX connection

> ✅ **Good news**: Secondary circuit is pre-established with active BGP. Failover is automatic via BGP — traffic should already be routing via secondary. This runbook confirms the failover and coordinates recovery.

---

## Step 0: Confirm Failover Has Occurred (5 min)

```bash
# Check BGP session states on both circuits
./scripts/bgp-health-check.sh --all-sessions --region us-east-1

# Expected output for failed primary:
# ❌ VIF: transit-vif-primary | State: down
# ✅ VIF: transit-vif-secondary | State: available
# ✅ BGP Peer ASN 65000: state=available, status=up
```

Also verify in AWS Console:
- **Direct Connect → Virtual Interfaces** → primary VIF shows "down"
- **Transit Gateway → Route Tables** → routes still present (via secondary)

Post in `#incident-response`:
```
⚠️ P1: Primary Direct Connect circuit DOWN
Secondary circuit: ACTIVE ✅ — traffic routing normally
Impact: Redundancy lost — single point of failure until primary restored
Incident: INC-XXXXX | Runbook: runbooks/01-direct-connect-failover.md
```

---

## Step 1: Validate Traffic Is Flowing via Secondary (5 min)

```bash
# Check bandwidth on secondary VIF — should show traffic
aws cloudwatch get-metric-statistics \
  --namespace AWS/DX \
  --metric-name VirtualInterfaceBpsIngress \
  --dimensions Name=VirtualInterfaceId,Value=<SECONDARY_VIF_ID> \
  --start-time $(date -u -d '5 minutes ago' +%Y-%m-%dT%H:%M:%SZ) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ) \
  --period 300 \
  --statistics Average \
  --region us-east-1

# Should show non-zero bytes — confirms traffic has shifted to secondary
```

Run end-to-end check:
```bash
./scripts/verify-connectivity.sh --env prod --verbose
# All AWS checks should still pass via secondary circuit
```

---

## Step 2: Identify Root Cause

**Contact carrier/provider** with DX connection ID:
```bash
# Get connection details for ticket
aws directconnect describe-connections \
  --region us-east-1 \
  --query 'connections[?connectionName==`dx-primary`].{id:connectionId,location:location,state:connectionState}'
```

Common causes:
| Cause | Indicator | Action |
|-------|-----------|--------|
| Carrier maintenance | Pre-announced maintenance window | Wait for completion |
| Physical fiber cut | No prior warning | Emergency ticket to carrier |
| Device failure at DX location | AWS health dashboard | AWS support ticket |
| BGP misconfiguration | BGP state = idle/active | Check router config |
| MACsec key mismatch | BGP established but no traffic | Re-key MACsec |

---

## Step 3: While on Secondary — Monitor Closely

Secondary circuit now carries **all traffic** with no redundancy. Monitor:

```bash
# Watch secondary bandwidth every 5 minutes
watch -n 300 "./scripts/bgp-health-check.sh --all-sessions"

# Alert thresholds to watch:
# Bandwidth > 8 Gbps = approaching capacity (10 Gbps link)
# BGP hold timer expiry warnings = instability risk
```

If secondary starts showing issues — **escalate immediately** to network team. You now have zero redundancy.

---

## Step 4: Primary Circuit Recovery

When carrier confirms primary is restored:

```bash
# 4a. Verify physical connection is back
aws directconnect describe-connections \
  --region us-east-1 \
  --query 'connections[?connectionName==`dx-primary`].connectionState'
# Expected: "available"

# 4b. Verify BGP re-established on primary VIF
./scripts/bgp-health-check.sh --all-sessions
# Expected: Both VIFs showing ✅

# 4c. Verify routes re-learned on primary
aws ec2 search-transit-gateway-routes \
  --transit-gateway-route-table-id <RT_ID> \
  --filters Name=type,Values=propagated \
  --region us-east-1
```

BGP will automatically re-advertise routes on primary. Traffic will gradually shift back based on BGP preference (community `7224:9300` gives primary higher local preference).

---

## Step 5: Post-Incident

1. Mark incident as resolved in PagerDuty
2. Confirm both circuits healthy:
   ```bash
   ./scripts/bgp-health-check.sh --all-sessions
   # Expected: ✅ ✅ on both primary and secondary
   ```
3. Run full connectivity verification:
   ```bash
   ./scripts/verify-connectivity.sh --env prod
   ```
4. Schedule Post-Incident Review within 48 hours
5. Request carrier SLA credit if applicable (track outage duration)

---

## Escalation Contacts

| Role | Contact | When |
|------|---------|------|
| Network Engineering | `@network-eng` | BGP config issues |
| AWS Enterprise Support | Case via console | AWS infrastructure issues |
| DX Carrier NOC | See `docs/carrier-contacts.md` | Physical circuit issues |
| Security Team | `@security-oncall` | If MACsec key rotation needed |
