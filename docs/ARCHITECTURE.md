# Architecture

## Overview

TaskApp runs on a self-provisioned, 3-node k3s Kubernetes cluster on AWS
(us-east-1), replacing the original single-EC2-instance deployment. The
cluster is provisioned by Terraform, configured by Ansible, and the
application itself is managed by Argo CD (GitOps) — no manual `kubectl
apply` is used for the final, graded state.

## Node topology

| Node | Role | Instance type | Private IP | Public IP |
|---|---|---|---|---|
| phoenix-control-plane | k3s server (control-plane) | t3.medium | 10.10.1.240 | Elastic IP (static) |
| phoenix-worker-1 | k3s agent (worker) | t3.small | 10.10.1.117 | dynamic |
| phoenix-worker-2 | k3s agent (worker) | t3.small | 10.10.1.90 | dynamic |

All 3 nodes sit in a single dedicated VPC (`10.10.0.0/16`), single public
subnet (`10.10.1.0/24`), created fresh for this capstone — separate from
the original single-server deployment, which remains untouched as a
reference/rollback point.

A single k3s server (no HA control-plane / etcd quorum) was used
deliberately — the capstone brief explicitly scopes multi-master control
planes as out of scope; the difficulty here is Kubernetes itself, not
etcd HA.

The control-plane is **tainted** (`node-role.kubernetes.io/control-plane=:NoSchedule`)
so application pods never schedule onto it — by default k3s allows this
(unlike upstream Kubernetes), but on small instances it's what caused a
resource-exhaustion incident (see below). Postgres, backend, and
frontend now run exclusively on the two dedicated workers.

The control-plane uses a static **Elastic IP**, allocated after a
resize incident (below) changed its public IP once. All external
references (domain, kubeconfig) point at this now-permanent address,
so future resizes or instance replacement won't break the app's URL
again.

## Request flow

Frontend and backend share one domain (same-origin), avoiding CORS
entirely and sidestepping a Vite build-time constraint: `VITE_API_URL`
is baked into the frontend's static JS at `docker build` time, not
read at container runtime, so a same-origin relative `/api` path
(the code's built-in fallback) needed no rebuild per environment.

## What each Core requirement fixes from the single-server deployment

| Requirement | Single-server problem it fixes |
|---|---|
| Namespace + ConfigMap/Secret split | No isolation between app config and secrets; Portainer env vars weren't separated from committed config |
| Postgres StatefulSet + PVC | DB lived on one host's local disk; no resilience to that host failing |
| Backend + frontend, 2+ replicas, spread across nodes | Single point of failure — one process, one host, no redundancy |
| Migration as a separate Job | Entrypoint-run migrations race under 2+ replicas (`db.create_all()` + user-seeding could double-fire) |
| Liveness/readiness/startup probes | No automated detection of a hung or unhealthy process; a crashed Flask worker just stayed down |
| Resource requests/limits | No isolation between workloads; one runaway process could starve the host |
| RollingUpdate maxUnavailable:0 | Deploys meant real downtime; now proven zero dropped requests during a rollout |
| Ingress + TLS (Let's Encrypt prod) | Single server had no reverse proxy/TLS termination layer; this is real, browser-trusted HTTPS on a real domain |
| GitOps (Argo CD) | Portainer's "push to redeploy" replaced with git as the actual source of truth; commit → auto-sync proven live |

## Advanced items implemented

- **PodDisruptionBudget** — backend `minAvailable: 2` (of up to 6), frontend `minAvailable: 1` (of 2) — protects the live failover demo from an unsafe drain
- **HPA** — backend scales 3-6 replicas on 50% CPU target (raised minReplicas from 2 to 3 after a first failover attempt showed 2 replicas left no slack against the PDB's `minAvailable: 2`); load-tested with `hey`, observed 103k+ requests at 861 req/sec, CPU spiking to 296% of target and scaling to 6 replicas under load
- **Security hardening** — `runAsNonRoot`, `seccompProfile: RuntimeDefault`, `allowPrivilegeEscalation: false`, all capabilities dropped, on backend, frontend, and the migration Job. Required switching the backend Dockerfile's `USER appuser` to a numeric `USER 1000` — Kubernetes can't verify a named user is non-root without a numeric UID.

## Observability — attempted, reverted (documented trade-off)

`kube-prometheus-stack` (Prometheus + Grafana + Alertmanager + node
exporters + operator) was installed via Helm and found too
resource-intensive for the (at-the-time) `t3.small` control-plane. The
stack was removed and the node rebooted to recover. Given the
capacity fixes below, a lighter-weight or full observability setup
would be the natural next Advanced item with more time.

## Incident: control-plane resource exhaustion (recurring, then fixed properly)

This happened twice during the build:

1. **First occurrence** — triggered by installing `kube-prometheus-stack`
   on the original `t3.small` control-plane (2GB RAM). Available memory
   dropped to ~75Mi of 1.9Gi, load average spiked to ~24 vs. a normal
   ~0.1. Fixed with a reboot; the monitoring stack was removed.

2. **Second occurrence** — recurred days later, without Prometheus this
   time. Root cause: k3s server itself (~1GB RSS) plus Argo CD's several
   controllers plus cert-manager plus, transiently, application pods
   that had rescheduled onto the control-plane during earlier failover
   testing — all competing for the same 2GB/2vCPU `t3.small`. This is a
   structural capacity problem, not a one-off.

**Real fix applied** (not just another reboot):
   - Resized the control-plane from `t3.small` to `t3.medium` via
     Terraform (3.7GB RAM, ~2.1GB available under full load post-fix)
   - Tainted the control-plane (`NoSchedule`) so application pods can
     never land there again, regardless of what else happens during
     testing
   - Added a static Elastic IP so this and any future resize/replace
     doesn't cascade into breaking the Ingress hostname, TLS cert, and
     kubeconfig every time

Throughout both incidents, the application layer itself (Postgres,
backend, frontend) was never actually down — PVC-backed storage and
GitOps reconciliation meant no data or state was lost; only
`kubectl`/API access was intermittently affected. See
`docs/RUNBOOK.md` for the exact recovery procedure.
