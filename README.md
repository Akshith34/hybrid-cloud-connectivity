# Hybrid Cloud Connectivity — AWS + Azure
### Direct Connect · ExpressRoute · Transit Gateway · Virtual WAN · PrivateLink

[![Connectivity Tests](https://github.com/Akshith34/hybrid-cloud-connectivity/actions/workflows/connectivity-test.yml/badge.svg)](https://github.com/Akshith34/hybrid-cloud-connectivity/actions)
[![Terraform](https://img.shields.io/badge/Terraform-1.6+-623CE4?logo=terraform)](https://terraform.io)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

---

## Overview

This repository contains the **Infrastructure as Code, BGP routing configurations, and operational runbooks** for a production-grade hybrid cloud network connecting on-premises data centers to AWS and Azure using dedicated private circuits.

**Key outcomes:**
- Eliminated public internet exposure for all sensitive financial data flows
- Replaced 12+ point-to-point VPN tunnels with a unified hub-and-spoke topology
- Achieved **99.99% network availability** using redundant BGP links and automatic failover
- Met data sovereignty requirements across 4 regional offices in collaboration with network, security, and compliance teams

---

## Architecture

```
                        ┌─────────────────────────────────┐
                        │       On-Premises Data Center    │
                        │                                  │
                        │  ┌──────────┐  ┌─────────────┐  │
                        │  │ Router A │  │  Router B   │  │
                        │  │ (Primary)│  │ (Redundant) │  │
                        │  └────┬─────┘  └──────┬──────┘  │
                        └───────┼───────────────┼─────────┘
                                │ BGP           │ BGP
                    ┌───────────┼───────────────┼───────────┐
                    │  Private  │  Circuits     │           │
                    │           │               │           │
          ┌─────────▼───────┐           ┌──────▼──────────┐
          │   AWS Direct    │           │  Azure Express   │
          │   Connect       │           │  Route           │
          │   10 Gbps       │           │  10 Gbps         │
          └─────────┬───────┘           └──────┬───────────┘
                    │                          │
          ┌─────────▼───────┐           ┌──────▼───────────┐
          │  AWS Transit    │           │  Azure Virtual   │
          │  Gateway (Hub)  │           │  WAN (Hub)       │
          │                 │           │                  │
          │  ┌───────────┐  │           │  ┌────────────┐  │
          │  │  VPC A    │  │           │  │  VNet A    │  │
          │  │(Finance)  │  │           │  │ (Finance)  │  │
          │  └───────────┘  │           │  └────────────┘  │
          │  ┌───────────┐  │           │  ┌────────────┐  │
          │  │  VPC B    │  │◄─────────►│  │  VNet B    │  │
          │  │   (HR)    │  │  IPSec    │  │   (HR)     │  │
          │  └───────────┘  │  VPN      │  └────────────┘  │
          │  ┌───────────┐  │           │  ┌────────────┐  │
          │  │  VPC C    │  │           │  │  VNet C    │  │
          │  │ (Shared)  │  │           │  │ (Shared)   │  │
          │  └───────────┘  │           │  └────────────┘  │
          └─────────────────┘           └──────────────────┘
                    │                          │
          ┌─────────▼───────┐           ┌──────▼───────────┐
          │  AWS PrivateLink │           │  Azure Private   │
          │  Endpoints       │           │  Endpoints       │
          │  (S3, RDS, etc.) │           │  (Storage, SQL)  │
          └─────────────────┘           └──────────────────┘
```

### Network Design Principles

| Principle | Implementation |
|-----------|---------------|
| **Zero public internet** | All traffic flows via Direct Connect / ExpressRoute |
| **High availability** | Dual redundant BGP links, automatic failover <30s |
| **Hub-and-spoke** | TGW + vWAN replace 12+ point-to-point VPNs |
| **Data sovereignty** | Private Endpoints keep data off public internet |
| **Least privilege** | Route filtering prevents unwanted cross-spoke traffic |

---

## Repository Structure

```
hybrid-cloud-connectivity/
├── terraform/
│   ├── aws/
│   │   ├── transit-gateway/     # TGW, route tables, attachments
│   │   ├── direct-connect/      # DX connections, VIFs, BGP
│   │   └── privatelink/         # VPC endpoints, endpoint services
│   ├── azure/
│   │   ├── vwan/                # Virtual WAN hub, connections
│   │   ├── expressroute/        # ER circuits, peerings, gateways
│   │   └── private-endpoints/   # Private endpoints, DNS zones
│   └── modules/
│       ├── tgw-attachments/     # Reusable TGW VPC attachment module
│       ├── bgp-routing/         # BGP route configuration module
│       └── private-endpoints/   # Reusable private endpoint module
├── scripts/
│   ├── verify-connectivity.sh   # End-to-end connectivity validation
│   ├── bgp-health-check.sh      # BGP session health monitoring
│   └── route-audit.sh           # Route table audit and drift detection
├── runbooks/
│   ├── 01-direct-connect-failover.md
│   ├── 02-bgp-route-flap.md
│   ├── 03-expressroute-failover.md
│   └── 04-private-endpoint-troubleshooting.md
├── docs/
│   └── architecture-decisions/  # ADRs
└── .github/
    └── workflows/
        └── connectivity-test.yml
```

---

## Key Components

### 1. AWS Transit Gateway (Hub-and-Spoke)
- **Central hub** routing traffic between all VPCs and on-premises
- **Route tables** isolate spoke VPCs (Finance cannot reach HR directly)
- **TGW Connect** provides high-bandwidth GRE tunnels for inter-region traffic
- Replaced **12 point-to-point VPN connections** with single managed hub
- Supports up to **5,000 VPC attachments** — scales with org growth

### 2. AWS Direct Connect
- **Dedicated 10 Gbps** private circuit — no shared internet bandwidth
- **Two redundant connections** via different Direct Connect locations for HA
- **Private VIF** connects to TGW for VPC access
- **Transit VIF** used for multi-VPC/multi-account connectivity
- BGP communities used for route preference and traffic engineering

### 3. Azure Virtual WAN
- **Standard tier** vWAN with hub in East US + West US
- **Branch connections** (offices) connect via ExpressRoute into vWAN hub
- **VNet connections** attach spoke VNets to hub with automatic route propagation
- Replaces manual UDR management — routes auto-propagated to all spokes

### 4. Azure ExpressRoute
- **10 Gbps** dedicated circuit via carrier partner
- **Active-active** dual connections for 99.95% SLA
- **FastPath** enabled to bypass gateway for high-throughput workloads
- **Global Reach** used for on-premises to on-premises traffic via Azure backbone

### 5. AWS PrivateLink + Azure Private Endpoints
- **AWS**: VPC endpoints for S3, RDS, Secrets Manager, and internal microservices
- **Azure**: Private endpoints for Storage, SQL, Key Vault, and Service Bus
- **Private DNS zones** auto-resolve service FQDNs to private IPs
- Zero data traverses public internet — meets financial data compliance requirements

---

## BGP Configuration

### Route Advertisement Strategy

```
On-Premises → AWS (via Direct Connect):
  Advertise: 10.0.0.0/8 (corporate supernet)
  Receive:   172.16.0.0/12 (AWS VPC CIDRs)
  Communities: 7224:9300 (local preference high for primary link)

On-Premises → Azure (via ExpressRoute):
  Advertise: 10.0.0.0/8 (corporate supernet)
  Receive:   192.168.0.0/16 (Azure VNet CIDRs)
  AS Path:   65000 (on-prem) ↔ 65515 (Azure)
```

### Failover Behavior
- Primary link failure detected via BGP hold timer (**90 second default, tuned to 30s**)
- Secondary link pre-established — failover is **sub-30 seconds**
- Route withdrawal triggers automatic traffic shift to backup circuit

---

## Getting Started

### Prerequisites
```bash
terraform >= 1.6
aws-cli >= 2.0
az cli >= 2.50
```

### Deploy AWS Transit Gateway
```bash
cd terraform/aws/transit-gateway
terraform init
terraform plan -var-file="prod.tfvars"
terraform apply -var-file="prod.tfvars"
```

### Deploy Azure Virtual WAN
```bash
cd terraform/azure/vwan
terraform init
terraform plan -var-file="prod.tfvars"
terraform apply -var-file="prod.tfvars"
```

### Verify Connectivity
```bash
# Run end-to-end connectivity check
./scripts/verify-connectivity.sh --env prod --verbose

# Check BGP session health
./scripts/bgp-health-check.sh --all-sessions

# Audit route tables for drift
./scripts/route-audit.sh --compare-baseline
```

---

## Monitoring & Alerting

| Signal | Tool | Threshold |
|--------|------|-----------|
| BGP session down | CloudWatch + Azure Monitor | Immediate |
| Direct Connect bandwidth | CloudWatch | >80% utilization |
| ExpressRoute circuit health | Azure Monitor | Any degradation |
| Private endpoint DNS resolution | Route 53 Resolver logs | Any failure |
| Route table drift | Lambda + EventBridge | Any unauthorized change |

---

## Compliance & Security

- **Data sovereignty**: All financial data flows via private circuits only — verified via VPC Flow Logs + NSG Flow Logs
- **Encryption**: MACsec enabled on Direct Connect for layer 2 encryption
- **Route filtering**: Prefix lists prevent route leakage between spokes
- **Audit trail**: All route changes logged to CloudTrail + Azure Activity Log
- **Change control**: All Terraform changes require PR approval + plan review

---

## License

MIT — see [LICENSE](LICENSE)
