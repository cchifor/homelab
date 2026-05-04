# immich-values — DEFERRED

[Immich](https://immich.app/) is the Google Photos alternative — face/object AI search, mobile auto-upload, sharing, timeline. Worth installing eventually.

**Status: deferred to a future phase.** The chart works in principle but needs an external pgvector / pgvecto.rs PostgreSQL that we don't yet have set up.

## Why deferred

The `immich-charts/immich` chart removed its bundled PostgreSQL subchart in version 0.10.0 (released mid-2025). The reason: Immich requires PostgreSQL with the `pgvecto.rs` (or `pgvector`) extension installed for AI vector similarity search, and the upstream Bitnami postgres image doesn't ship that extension.

The chart's release notes point users at one of:
- **CloudNativePG operator** with a custom image that includes pgvecto.rs
- **Tensorchord's `pgvecto-rs` image** deployed standalone (`tensorchord/pgvecto-rs:pg16-v0.2.0`)
- **Self-managed Postgres** outside the cluster with the extension installed manually

## Pre-pinned values (ready to use once Postgres is sorted)

`apps/charts/immich-values/values.yaml` is already configured for:
- 100 GiB Longhorn library PVC (pre-created manifest in this dir)
- Public via cloudflare-tunnel at `immich.chifor.dev`
- Server + ML + microservices components enabled
- CPU-only ML (workers are ARM64 with Mali GPU; no Plex-style hardware ML)

What's missing: the chart values still need a working `postgresql.host`/`postgresql.username`/`postgresql.password` set pointing at an external pgvecto.rs Postgres.

## Suggested path forward

1. Install **CloudNativePG operator** in the cluster (one helm chart, ~50 MB)
2. Define a `Cluster` resource using `tensorchord/cnpg-pgvecto.rs:16-v0.2.0` image (or current equivalent)
3. CloudNativePG creates a Postgres StatefulSet with `pgvecto.rs` extension built in, plus a Secret with credentials
4. Reference the Secret in the Immich chart values
5. `helm install immich`, validate

Estimated effort: 30–60 minutes once the dependencies are pinned. Punted to later because phase 3 wanted to avoid scope creep into "set up a third PostgreSQL operator just for one app."

## Pre-existing artefacts in this dir

- `values.yaml` — chart values (with `existingClaim: immich-library` for the photos PVC)
- `.secrets.env` (gitignored) — placeholder DB password, kept for the future install

The pre-created `immich-library` PVC currently exists in the `immich` namespace; check with `kubectl -n immich get pvc`. Either keep it (it'll Bind once a real PV is requested) or delete with `kubectl -n immich delete pvc immich-library` if you're aborting the install entirely.

## Alternatives if Immich's pgvecto.rs hassle isn't worth it

- **PhotoPrism** — similar feature set, simpler chart, doesn't need a special Postgres extension
- **Photoview** — minimalist; great for personal use
- **Lychee** — lightweight gallery, simpler stack

Any of these can swap in for the "Google Photos alternative" slot in the homelab line-up.
