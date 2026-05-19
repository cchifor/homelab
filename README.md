# homelab

OpenTofu IaC + Helm charts for a hybrid k3s home-lab on Proxmox VE + 4× Radxa Q6A workers, with a parallel Incus cluster on the same 4 nodes for one-off VMs alongside k3s.

## Topology (as-deployed)

```
Proxmox host (192.168.0.185, N150 / 32 GiB)
├── k3s-server-01 VM         .187    control-plane (Debian 12)
├── nas-minio LXC            .186    MinIO (Longhorn backup target)
├── openclaw / plex LXCs     .188-.189   optional, gated by *_enabled vars
└── claude-worker VM         .190    optional, gated by claude_worker_enabled

LAN /23 — 192.168.0.0–.1.255
├── rdxa1   .131   k3s-agent + Incus    (database-leader)
│   └── claude-worker-1     .141   VM in Incus
├── rdxa2   .132   k3s-agent + Incus    (database)
│   └── claude-worker-2     .142
├── rdxa3   .133   k3s-agent + Incus    (database)
│   └── claude-worker-3     .143
└── rdxa4   .134   k3s-agent + Incus    (database)
    └── claude-worker-4     .144
```

Renumbered from `q6a-1..4` (on `.174 / .200 / .129 / .1.167`) to the unified `rdxa1..4 / .131-.134` scheme on 2026-05-19. The Incus cluster was rebuilt fresh during that operation; see [`platform/README.md`](platform/README.md) § *Rebuilding the Incus cluster* for the procedure.

## Layers

| Directory | Layer | What lives here |
|---|---|---|
| **[`platform/`](platform/)** | **Infrastructure** | Terraform-managed cluster bootstrap (Proxmox LXC + VM + k3s) and foundational platform services (cert-manager, Longhorn, Rancher, Traefik, MinIO). Incus VM resources for the 4 `claude-worker-N` VMs. Operator-side bash scripts (SSH key push, prep, readiness check). Treat as the substrate that everything else runs on. |
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
- **Operator-side Incus client setup** (for the `lxc/incus` Terraform provider): [`platform/README.md`](platform/README.md) § *Operator-side Incus client setup*. Required before `tofu apply` can touch the 4 `claude-worker-N` VMs.
- **Importing the live Incus VMs into Terraform state**: [`platform/README.md`](platform/README.md) § *Importing the live Incus VMs into Terraform state* — the 4 VMs were created out-of-band during the 2026-05-19 cluster rebuild and need a one-time `tofu import`.
- **Rebuilding the Incus cluster** (after IP renumber, cert rotation, or quorum loss): [`platform/README.md`](platform/README.md) § *Rebuilding the Incus cluster*. Step-by-step procedure that preserves VM disks via `incus admin recover`.
- **Deploying an app**: [`apps/README.md`](apps/README.md).
- **Writing a chart**: [`apps/charts/README.md`](apps/charts/README.md).
- **Implementation plan + history of decisions**: [`docs/PLAN.md`](docs/PLAN.md).

## License

MIT. See [`LICENSE`](LICENSE).
