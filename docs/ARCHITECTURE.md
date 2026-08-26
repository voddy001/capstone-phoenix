# Architecture

## Overview

TaskApp runs on a self-provisioned, 3-node k3s Kubernetes cluster on AWS
(us-east-1), replacing the original single-EC2-instance deployment. The
cluster is provisioned by Terraform, configured by Ansible, and the
application itself is managed by Argo CD (GitOps) — no manual `kubectl
apply` is used for the final, graded state.

## Node topology

| Node | Role | Instance type | Private IP |
|---|---|---|---|
| phoenix-control-plane | k3s server (control-plane) | t3.small | 10.10.1.240 |
| phoenix-worker-1 | k3s agent (worker) | t3.small | 10.10.1.117 |
| phoenix-worker-2 | k3s agent (worker) | t3.small | 10.10.1.90 |

All 3 nodes sit in a single dedicated VPC (`10.10.0.0/16`), single public
subnet (`10.10.1.0/24`), created fresh for this capstone — separate from
the original single-server deployment, which remains untouched as a
reference/rollback point.

A single k3s server (no HA control-plane / etcd quorum) was used
deliberately — the capstone brief explicitly scopes multi-master control
planes as out of scope; the difficulty here is Kubernetes itself, not
etcd HA.

## Request flow

User browser
  → DNS (nip.io wildcard, resolves taskapp.<control-plane-ip>.nip.io → control-plane public IP)
  → Traefik Ingress (k3s built-in), TLS terminated here (cert-manager + Let's Encrypt production issuer)
  → path /       → frontend Service → frontend Deployment (nginx, static React build, 2 replicas)
  → path /api/*  → backend Service  → backend Deployment (Flask + Gunicorn, 2-6 replicas via HPA)
  → backend → postgres Service (headless) → postgres-0 (StatefulSet, PVC-backed)
  
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
- **HPA** — backend scales 2-6 replicas on 50% CPU target; load-tested with `hey`, observed scaling to 296% CPU / 6 replicas under load, back down after
- **Security hardening** — `runAsNonRoot`, `seccompProfile: RuntimeDefault`, `allowPrivilegeEscalation: false`, all capabilities dropped, on backend, frontend, and the migration Job

## Observability — attempted, reverted (documented trade-off)

`kube-prometheus-stack` (Prometheus + Grafana + Alertmanager + node
exporters + operator) was installed via Helm and found too
resource-intensive for 3× `t3.small` nodes. The control-plane hit severe
memory pressure (available memory dropped to ~75Mi of 1.9Gi, load
average spiked to ~24 vs. a normal ~0.1), which in turn made the k3s API
server itself intermittently unreachable. The stack was removed and the
control-plane rebooted to recover; the app layer (Postgres, backend,
frontend) was unaffected throughout, since PVC-backed storage and
GitOps reconciliation meant no state was lost. See `docs/RUNBOOK.md`
for the recovery procedure. Given more headroom (e.g. `t3.medium`
control-plane, or a leaner Grafana-only setup without the full
Prometheus/Alertmanager bundle), this would be the natural next Advanced
item.
