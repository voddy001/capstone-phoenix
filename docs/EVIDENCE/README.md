# Evidence

| File | Shows |
|---|---|
| 01-nodes-ready.png | `kubectl get nodes` — all 3 nodes Ready, multi-node cluster |
| 02-pods-spread-across-nodes.png | `kubectl get pods -o wide` — replicas on different nodes |
| 03-tls-cert-valid.png | `curl -vI` showing Let's Encrypt issuer, verified cert |
| 04-postgres-persistence.png | Row inserted, pod deleted+recreated, same row still present |
| 05-zero-downtime-rollout.png | Rolling restart + continuous curl loop, all 200s |
| 06-hpa-scaling.png | Load test (861 req/sec) driving HPA from 3 to 6 replicas |
| 07-Argo-CD-UI.png | Argo CD UI, taskapp Application Synced + Healthy |
| 08-commit-sync-proof.png | Latest git commit SHA matching Argo CD's synced revision |
| 09-failover-drain.png | `kubectl drain` output — pod eviction respecting PDB |
| 10-zero-downtime-during-that-drain.png | Continuous curl loop during the drain, all 200s |
| 11-post-recovery-state.png | PDBs + pods rebalanced across nodes after uncordon |

Note: 03 and 05 were captured before the control-plane resize/Elastic IP
fix documented in ARCHITECTURE.md — domain shown is the original
`44.202.207.122`, later superseded by the static `54.211.238.0`. This
doesn't affect what each screenshot demonstrates.
