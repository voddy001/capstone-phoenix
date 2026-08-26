# Cost

## Current monthly cost (AWS, us-east-1)

| Resource | Spec | Qty | Est. monthly cost |
|---|---|---|---|
| EC2 (control-plane) | t3.small | 1 | ~$15.00 |
| EC2 (workers) | t3.small | 2 | ~$30.00 |
| EBS (root volumes, gp3) | 8GB default × 3 | 3 | ~$2.00 |
| EBS (Postgres PVC, local-path on worker) | 2Gi | 1 | included above |
| S3 (Terraform state bucket) | negligible size | 1 | <$0.10 |
| DynamoDB (state lock table) | on-demand, negligible traffic | 1 | <$0.10 |
| Data transfer (egress) | low, single-app traffic | — | ~$1-2 |
| **Total** | | | **~$48-50/month** |

t3.small pricing (~$0.0208/hr on-demand in us-east-1) × 3 instances ×
730 hrs/month is the dominant cost by far — everything else here is
close to free at this scale.

## How this would be halved

1. **Spot instances for workers** (not the control-plane, which needs
   to stay stable) — t3.small spot pricing typically runs 60-70%
   cheaper than on-demand. Two workers on spot would cut roughly
   $18-21/month, the single biggest lever available here. Trade-off:
   spot instances can be reclaimed with 2 minutes' notice, so this only
   makes sense once pod rescheduling/PDB behavior (already built) is
   trusted to handle it gracefully — which, given the PDB and
   multi-replica setup already in place, it should.

2. **Smaller root volumes** — currently using the AWS default (8GB gp3
   per instance); this app's actual footprint is a fraction of that.
   Trimming to 4-5GB root volumes saves a small amount directly and
   reduces gp3 IOPS/throughput baseline cost slightly.

3. **Reserved Instances or a Savings Plan**, if this were a
   longer-lived deployment rather than a 3-week class project — 1-year
   no-upfront RIs typically save ~30-40% over on-demand for steady-state
   workloads like a control-plane that's always running.

Combining (1) and (2) — spot workers plus trimmed volumes — gets close
to halving the total, from ~$48-50/month to roughly ~$24-27/month,
without changing the architecture itself.

## What's deliberately *not* optimized further

The control-plane stays on-demand `t3.small` rather than spot, since
losing it (even briefly) means losing `kubectl`/API access to the whole
cluster — not worth the savings for a single instance. Also, per the
capstone brief, a multi-master HA control-plane was explicitly out of
scope, which is itself a major cost-avoidance decision on top of being
a scope decision — an HA control-plane would need at least 3 control-plane-class
instances instead of 1.
