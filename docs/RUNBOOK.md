# Runbook

## Provision from zero

### 1. Infrastructure (Terraform)

```bash
cd infra/terraform
terraform init
terraform plan
terraform apply
```

Requires `terraform.tfvars` (gitignored) with your public IP:
Find it: `curl -s https://checkip.amazonaws.com`

Requires an existing EC2 key pair in the deploy region, referenced via
the `key_name` variable (default currently set to `phoenix-cluster`).

Outputs the 3 node IPs — note the control-plane's is now a **static
Elastic IP**, so it stays constant across resizes/replacements; worker
IPs are still dynamic:
```bash
terraform output
```

### 2. Cluster bring-up (Ansible)

```bash
cd infra/ansible
# update inventory.ini with current IPs from terraform output if they changed
ansible all -i inventory.ini -m ping   # verify connectivity first
ansible-playbook -i inventory.ini site.yaml
```

Idempotent — safe to re-run. Installs base hardening (ufw, SSH lockdown)
on all 3 nodes, k3s server on control-plane, k3s agent on both workers.

### 3. Connect kubectl locally

k3s's API (port 6443) is deliberately **not** exposed to the internet —
only reachable via SSH tunnel:

```bash
ssh -i ~/phoenix-cluster.pem -L 6443:localhost:6443 -N -f ubuntu@<control-plane-public-ip>
```

Fetch kubeconfig (one-time, or after cluster rebuild):
```bash
ssh -i ~/phoenix-cluster.pem ubuntu@<control-plane-public-ip> "sudo cat /etc/rancher/k3s/k3s.yaml" > ~/.kube/phoenix-config
export KUBECONFIG=~/.kube/phoenix-config
```

Verify:
```bash
kubectl get nodes
```

### 4. Platform + app (GitOps)

Everything in `manifests/` and `gitops/` is Argo CD-managed. From a
completely fresh cluster:

```bash
# Ingress: k3s ships Traefik by default, nothing to install

# cert-manager
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.16.2/cert-manager.yaml

# Argo CD
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Point Argo CD at this repo
kubectl apply -f gitops/taskapp-application.yaml
```

Argo CD then creates the `taskapp` namespace and syncs everything in
`manifests/` automatically: namespace, ConfigMap, Postgres StatefulSet,
migration Job, backend/frontend Deployments, Ingress, PDBs, HPA.

**One manual step required outside GitOps**: the `taskapp-secrets`
Kubernetes Secret is deliberately *not* stored in git. Create it once
per fresh cluster:
```bash
POSTGRES_PASSWORD=$(openssl rand -base64 24)
SECRET_KEY=$(openssl rand -base64 32)
kubectl create secret generic taskapp-secrets \
  --namespace=taskapp \
  --from-literal=POSTGRES_USER=taskuser \
  --from-literal=POSTGRES_PASSWORD="$POSTGRES_PASSWORD" \
  --from-literal=SECRET_KEY="$SECRET_KEY" \
  --from-literal=DATABASE_URL="postgresql://taskuser:${POSTGRES_PASSWORD}@postgres:5432/taskmanager"
```

**Also outside GitOps**: taint the control-plane so app pods never
schedule onto it (see "Note: control-plane sizing and static IP" below
for why):
```bash
kubectl taint nodes <control-plane-node-name> node-role.kubernetes.io/control-plane=:NoSchedule
```

## Day-to-day access (after the environment already exists)

Your home IP changes periodically (residential ISP). If SSH/kubectl
time out with "connection timed out" (not "refused"), this is almost
always the cause:

```bash
curl -s https://checkip.amazonaws.com
cat infra/terraform/terraform.tfvars   # compare
# if different:
nano infra/terraform/terraform.tfvars  # update my_ip
cd infra/terraform && terraform apply
```

Reopen the SSH tunnel (dies when your machine sleeps or terminal closes):
```bash
pkill -9 -f "6443:localhost:6443"   # clear any zombie tunnel first
ssh -i ~/phoenix-cluster.pem -L 6443:localhost:6443 -N -f ubuntu@<control-plane-public-ip>
```

## Deploy a change

All changes go through git — Argo CD owns the cluster's live state:
```bash
# edit manifests/*.yaml
git add manifests/
git commit -m "describe the change"
git push
```

Argo CD polls every ~3 minutes by default. To force an immediate sync
rather than wait:
```bash
kubectl annotate application taskapp -n argocd argocd.argoproj.io/refresh=hard --overwrite
```

## Scale

Backend auto-scales via HPA (3-6 replicas on 50% CPU — raised from a
2-replica floor after a failover test showed 2 left no slack against
the PDB's `minAvailable: 2`). To manually adjust the range, edit
`manifests/09-hpa.yaml` and push. Frontend has a static replica count
in `manifests/05-frontend.yaml` — edit and push to change.

## Roll back

Since Argo CD tracks git as the source of truth, rolling back is a git
revert:
```bash
git revert <bad-commit-sha>
git push
```
Argo CD will sync the reverted state automatically. Alternatively, use
Argo CD's own UI (History and Rollback panel on the Application) to
roll back to a previous synced revision directly, without a git
revert — useful if you need to roll back faster than a git operation.

## Recover from a dead worker node

Pods on the dead node will be rescheduled onto remaining healthy nodes
automatically once Kubernetes marks the node `NotReady` (default ~5
minute detection window). PodDisruptionBudgets ensure this doesn't drop
below minimum available replicas during a *voluntary* drain; an
involuntary node failure is handled by normal Kubernetes rescheduling.

To manually drain a node for maintenance (safe, respects PDBs):
```bash
kubectl drain <node-name> --ignore-daemonsets --delete-emptydir-data
```
To bring it back into rotation:
```bash
kubectl uncordon <node-name>
```

Live-tested: draining a worker with only 2 backend replicas correctly
failed (PDB `minAvailable: 2` blocked it — proof the PDB works). After
raising `minReplicas` to 3, the same drain succeeded cleanly with zero
dropped requests throughout (verified via a continuous curl loop).

## Recover from a dead backend pod

Automatic — the Deployment's controller replaces it immediately, and
readiness/liveness probes ensure traffic isn't routed to it until
healthy again. No manual action needed.

## Recover from a bad migration

The migration Job (`taskapp-db-init`) is idempotent — it checks
`User.query.count() == 0` before seeding, so re-running it is always
safe. If a future migration needed to be re-applied after a code
change:
```bash
kubectl delete job taskapp-db-init -n taskapp
git add manifests/03-migration-job.yaml   # after bumping the image tag
git commit -m "..."
git push
kubectl annotate application taskapp -n argocd argocd.argoproj.io/refresh=hard --overwrite
```
(Jobs are immutable once created — the old Job must be deleted before
Argo CD can apply an updated one.)

## Recover from control-plane resource exhaustion

Encountered twice during this project (see `docs/ARCHITECTURE.md` for
the full incident history — the second time led to a permanent fix:
resizing to `t3.medium` and tainting the node against app pods).

Symptoms: SSH/kubectl work but hang or time out despite correct
security group rules and IP.

Diagnosis (SSH directly into the affected node):
```bash
ssh -i ~/phoenix-cluster.pem ubuntu@<node-ip> "free -h && uptime"
```
Available memory near 0 and/or load average far above core count
confirms resource exhaustion.

Fix (short-term):
```bash
ssh -i ~/phoenix-cluster.pem ubuntu@<node-ip> "sudo reboot"
# wait ~60-90s
ssh -i ~/phoenix-cluster.pem ubuntu@<node-ip> "free -h && uptime"   # confirm recovery
```
Safe: Postgres data persists via PVC; all other state is GitOps-managed
and Argo CD reconciles automatically once the node is back.

If this recurs, treat it as a capacity problem, not a one-off — see
the "Note" below.

## Note: control-plane sizing and static IP

The control-plane runs `t3.medium` (not `t3.small`) after two resource
exhaustion incidents during this build. It's also tainted
(`node-role.kubernetes.io/control-plane=:NoSchedule`) so application
pods never schedule there; only k3s, Argo CD, and cert-manager run on
it. If application pods ever show up on the control-plane node via
`kubectl get pods -A -o wide`, the taint may have been removed —
reapply with:
```bash
kubectl taint nodes <control-plane-node-name> node-role.kubernetes.io/control-plane=:NoSchedule --overwrite
```

The control-plane also has a static **Elastic IP** attached (not the
default dynamic public IP), specifically so future resizes or instance
replacement never again change the domain, kubeconfig, or TLS cert —
all three had to be manually updated once, the first time the
control-plane was resized before the EIP existed. Note: an Elastic IP
is only free while attached to a *running* instance — if the
control-plane is ever stopped without releasing the EIP, AWS begins
charging for the idle allocation (see `docs/COST.md`).
