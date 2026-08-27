# Cost

## Current monthly cost (AWS, us-east-1)

| Resource | Spec | Qty | Est. monthly cost |
|---|---|---|---|
| EC2 (control-plane) | t3.medium | 1 | ~$30.00 |
| EC2 (workers) | t3.small | 2 | ~$30.00 |
| EBS (root volumes, gp3) | 8GB default × 3 | 3 | ~$2.00 |
| EBS (Postgres PVC, local-path on worker) | 2Gi | 1 | included above |
| Elastic IP (attached) | 1 | 1 | $0.00 (free while attached to a running instance) |
| S3 (Terraform state bucket) | negligible size | 1 | <$0.10 |
| DynamoDB (state lock table) | on-demand, negligible traffic | 1 | <$0.10 |
| Data transfer (egress) | low, single-app traffic | — | ~$1-2 |
| **Total** | | | **~$63-65/month** |

The control-plane was upgraded from `t3.small` to `t3.medium` partway
through the project after two resource-exhaustion incidents (see
`docs/ARCHITECTURE.md`) — k3s itself plus Argo CD plus cert-manager
genuinely didn't fit in 2GB of RAM with any headroom. This raised the
control-plane's cost from ~$15/month to ~$30/month, the main driver of
the total going from ~$48-50/month to ~$63-65/month.

Note: an Elastic IP is free *only* while attached to a running
instance — if the control-plane were ever stopped (not just resized)
without releasing the EIP, AWS would start charging for the idle
allocation. Worth remembering if the cluster is ever paused rather than
torn down.

## How this would be halved

1. **Spot instances for workers** (not the control-plane, which needs
   to stay stable and is already the pricier of the two node types) —
   t3.small spot pricing typically runs 60-70% cheaper than on-demand.
   Two workers on spot would cut roughly $18-21/month. Trade-off: spot
   instances can be reclaimed with 2 minutes' notice — the existing
   PDB and multi-replica setup should absorb this gracefully, as
   already demonstrated during the live failover test.

2. **Right-size the control-plane again once stable** — `t3.medium` was
   chosen to fix an active incident with headroom to spare
   (`2.1Gi` available under full load). A more surgical fix might be
   `t3.small` plus explicitly reducing Argo CD's controller replica
   count / resource requests, which could recover some of this cost —
   untested here, flagged as a possible future optimization rather
   than applied under time pressure mid-incident.

3. **Reserved Instances or a Savings Plan**, if this were a
   longer-lived deployment rather than a class project — 1-year
   no-upfront RIs typically save ~30-40% over on-demand for steady-state
   workloads.

Combining (1) and a partial version of (2) could plausibly bring the
total back down toward ~$35-40/month without losing the stability
headroom the resize was specifically meant to provide.

## What's deliberately *not* optimized further

The control-plane stays on-demand (not spot) since losing it, even
briefly, means losing `kubectl`/Argo CD access to the whole cluster —
not worth the savings for a single instance that everything else
depends on. Per the capstone brief, a multi-master HA control-plane
was explicitly out of scope, which avoids needing 3 control-plane-class
instances instead of 1 — itself the largest cost-avoidance decision in
this whole setup.
