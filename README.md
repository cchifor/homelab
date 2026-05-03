# homelab

OpenTofu IaC + Helm charts for a hybrid k3s home-lab on Proxmox VE + Radxa Q6A workers.

The repo splits cleanly into two layers:

| Directory | Layer | What lives here |
|---|---|---|
| **[`platform/`](platform/)** | **Infrastructure** | Terraform-managed cluster bootstrap (Proxmox LXC + VM + k3s) and foundational platform services (cert-manager, Longhorn, Rancher, Traefik, MinIO). Operator-side bash scripts (SSH key push, prep, readiness check). Treat as the substrate that everything else runs on. |
| **[`apps/`](apps/)** | **Application** | Workloads that run *on* the cluster — locally-developed Helm charts in `apps/charts/` and raw k8s manifests in `apps/manifests/`. Independent of the platform's lifecycle. |

```
homelab/
├── platform/                # Cluster + foundational services (Terraform)
│   ├── *.tf, modules/, files/, scripts/
│   └── README.md            # ← Operator setup guide; start here for first install
│
├── apps/                    # Workloads on the cluster
│   ├── charts/              # Locally-developed Helm charts (you build these)
│   │   └── README.md        # ← Chart development conventions
│   ├── manifests/           # Raw kubectl-applied YAML
│   │   └── dind-runner/     # Privileged docker-in-docker StatefulSet (example)
│   └── README.md            # ← How to add/install/test apps
│
├── docs/PLAN.md             # Implementation plan (historical)
├── .github/workflows/ci.yml # CI: terraform fmt+validate, bash -n, helm lint, kubectl validate
├── LICENSE                  # MIT
└── README.md                # ← You are here
```

## When to touch which layer

- **You changed the cluster topology** (added a worker, swapped storage, replaced a VM template, bumped a chart version for a foundational service): edit something under `platform/`, run `terraform apply` from there.
- **You're deploying a new app** (Home Assistant, Nextcloud, your own web app, a CI runner): create a chart in `apps/charts/<name>/` or a manifest in `apps/manifests/<name>/`, then `helm install` / `kubectl apply` against the live cluster.
- **You're writing operator tooling** (something that prepares hosts, manages Proxmox state, provisions cluster prereqs): goes in `platform/scripts/`.

## Quick links

- **First-time setup** (or fresh install): [`platform/README.md`](platform/README.md) — three operator scripts + two-phase Terraform apply.
- **Deploying an app**: [`apps/README.md`](apps/README.md).
- **Writing a chart**: [`apps/charts/README.md`](apps/charts/README.md).
- **Implementation plan + history of decisions**: [`docs/PLAN.md`](docs/PLAN.md).

## License

MIT. See [`LICENSE`](LICENSE).
