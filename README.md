# openshell-kubevirt

Tracking and iteration repo for running **OpenShell + Hermes Agent** on **KubeVirt** via **agent-sandbox** `runtimeBackend: VirtualMachine`.

Forks and product code stay in their upstreams; handoff notes, runbooks, and the **Hermes bootc / KubeVirt guest images** (`images/hermes/`) live here. Two guest variants: **nemoclaw** (public nemoclaw guest) and **hermes-minimal** (no NemoClaw).

## Start here

- **[`AGENT-SANDBOX-VM.md`](./AGENT-SANDBOX-VM.md)** — piece-by-piece demo of the agent-sandbox `VirtualMachine` backend only (metadata, PVCs, Secret disks, RBAC).
- **[`TRACKING.md`](./TRACKING.md)** — living CRC handoff for the full Hermes / OpenShell stack (branches, redeploy gotchas, next actions).
- **[`REDEPLOY.md`](./REDEPLOY.md)** — pin CRC controller/gateway from nightly GHCR; **upgrade Hermes disk in place** (keep PVC) or recreate; **always re-attach providers** after delete/recreate.
- **[`images/hermes/`](./images/hermes/)** — dual Containerfiles + guest bootstrap for nemoclaw and hermes-minimal bootc / containerDisk images.
- **[`images/hermes/OPENSHELL-POLICY.md`](./images/hermes/OPENSHELL-POLICY.md)** — Hermes instructions: view/diagnose/update OpenShell policy entries (includes always-attach provider set).
- **[`signal/`](./signal/)** — in-cluster signal-cli for Hermes (`./signal/link.sh`).

## Related repos

| Repo | Fork branch | Tip (rebased 2026-08-12) | Same-fork compare vs `main` |
|------|-------------|--------------------------|-----------------------------|
| [kubernetes-sigs/agent-sandbox](https://github.com/kubernetes-sigs/agent-sandbox) → [andyetanotherorg/agent-sandbox](https://github.com/andyetanotherorg/agent-sandbox) | `kubevirt-backend` | [`a21b574`](https://github.com/andyetanotherorg/agent-sandbox/commit/a21b574d1f003209f49ae3c87621b6c606664a1a) | [compare](https://github.com/andyetanotherorg/agent-sandbox/compare/main...kubevirt-backend) |
| [NVIDIA/OpenShell](https://github.com/NVIDIA/OpenShell) → [andyetanotherorg/OpenShell](https://github.com/andyetanotherorg/OpenShell) | `vm-runtime-backend` | [`1c79e1d`](https://github.com/andyetanotherorg/OpenShell/commit/1c79e1d73400821eb906267e1cc9915d25e020de) | [compare](https://github.com/andyetanotherorg/OpenShell/compare/main...vm-runtime-backend) |
| [NVIDIA/NemoClaw](https://github.com/NVIDIA/NemoClaw) → [andyetanotherorg/NemoClaw](https://github.com/andyetanotherorg/NemoClaw) | `vm-runtime-backend` | [`832c188`](https://github.com/andyetanotherorg/NemoClaw/commit/832c188792a2c58be72246d1eaafae3d09eef582) | [compare](https://github.com/andyetanotherorg/NemoClaw/compare/main...vm-runtime-backend) |

See [`TRACKING.md`](./TRACKING.md) for verify notes from the rebase Tasks.

## Seat internal registry (honr-registry tip bake)

On the MicroShift seat, tip images are built in-cluster and pushed to **`honr-registry.default.svc:5000`** (Service `honr-registry` in `default`). Do **not** pin this seat to stale GHCR nightlies unless those layers are rebuilt from the tips below into the internal registry. Digest table + bake notes: [`TRACKING.md`](./TRACKING.md) § *seat internal registry tip images*.

| Image | Tip source |
|-------|------------|
| `honr-registry.default.svc:5000/agent-sandbox-controller` | andyetanotherorg/agent-sandbox `@kubevirt-backend` |
| `honr-registry.default.svc:5000/openshell-gateway` | andyetanotherorg/OpenShell `@vm-runtime-backend` |
| `honr-registry.default.svc:5000/openshell-supervisor` | andyetanotherorg/OpenShell `@vm-runtime-backend` |
| `honr-registry.default.svc:5000/nemoclaw-hermes` | andyetanotherorg/NemoClaw `@vm-runtime-backend` |
| `honr-registry.default.svc:5000/hermes-sandbox-bootc` | this repo `images/hermes` + tip supervisor/nemoclaw |

## Nightly CI

Workflow: [`.github/workflows/nightly-rebuild.yml`](.github/workflows/nightly-rebuild.yml)

- **Schedule:** 06:00 UTC daily
- **Manual:** Actions → *Nightly rebase and rebuild* → Run workflow
  - `rebase` (default on): rebase forks onto upstream `main` and force-push when clean; fail on conflicts
  - `push_images` (default on): build/push GHCR images
  - `build_container_disk` (default on): bootc-image-builder → `hermes-sandbox-kubevirt` + `hermes-minimal-kubevirt`
  - `build_hermes` / `build_hermes_minimal` (default off): rebuild one variant’s bootc without full `push_images`
  - `build_site_hermes` (default on): checkout public [`shanemcd/toolbox`](https://github.com/shanemcd/toolbox) `openshell-kubevirt/` → push `hermes-site-bootc` + `hermes-site-kubevirt` to `ghcr.io/andyetanotherorg`

Rebases run in parallel for agent-sandbox, OpenShell, and NemoClaw. Image builds that can run in parallel do; `hermes-sandbox-bootc` (nemoclaw) waits on supervisor + `nemoclaw-hermes`; `hermes-minimal-bootc` waits on supervisor only; containerDisk jobs wait on their bootc; site Hermes layers on the hermes-minimal bootc.

Cross-repo git uses a GitHub App installation token (`actions/create-github-app-token`). GHCR push uses `GITHUB_TOKEN`.

### Required repo settings

| Kind | Name | Purpose |
|------|------|---------|
| Variable | `APP_CLIENT_ID` | GitHub App client ID |
| Secret | `APP_PRIVATE_KEY` | GitHub App private key (PEM) |

App permissions: **Contents: Read and write**, **Workflows: Read and write** (needed when upstream rebases touch `.github/workflows/*`). Install on `agent-sandbox`, `OpenShell`, and `NemoClaw`. Site Hermes sources are checked out from public `toolbox` (no App install required).

```bash
gh variable set APP_CLIENT_ID --repo andyetanotherorg/openshell-kubevirt --body '<client-id>'
gh secret set APP_PRIVATE_KEY --repo andyetanotherorg/openshell-kubevirt < /path/to/app.pem
```

`hermes-site-*` GHCR packages were first published from toolbox and may still be linked there. If `build-hermes-site` cannot push, add **openshell-kubevirt** with Write under each package’s Manage Actions access.
### GHCR images (amd64) — nightly CI publish path

> Seat deploy should prefer **honr-registry tip digests** (above / TRACKING). The GHCR table below is the nightly workflow output path (`ghcr.io/andyetanotherorg`), not the seat pin.

| Image | Source |
|-------|--------|
| `ghcr.io/andyetanotherorg/agent-sandbox-controller` | agent-sandbox `kubevirt-backend` |
| `ghcr.io/andyetanotherorg/openshell-gateway` | OpenShell `vm-runtime-backend` |
| `ghcr.io/andyetanotherorg/openshell-supervisor` | OpenShell `vm-runtime-backend` |
| `ghcr.io/andyetanotherorg/nemoclaw-hermes` | NemoClaw `vm-runtime-backend` (input to nemoclaw bootc) |
| `ghcr.io/andyetanotherorg/hermes-sandbox-bootc` | [`images/hermes/Containerfile.nemoclaw`](./images/hermes/Containerfile.nemoclaw) |
| `ghcr.io/andyetanotherorg/hermes-sandbox-kubevirt` | nemoclaw bootc → qcow2 containerDisk (`/disk/fedora.qcow2`) |
| `ghcr.io/andyetanotherorg/hermes-minimal-bootc` | [`images/hermes/Containerfile.minimal`](./images/hermes/Containerfile.minimal) |
| `ghcr.io/andyetanotherorg/hermes-minimal-kubevirt` | minimal bootc → qcow2 containerDisk |
| `ghcr.io/andyetanotherorg/hermes-site-bootc` | public [`shanemcd/toolbox`](https://github.com/shanemcd/toolbox) `openshell-kubevirt/` on hermes-minimal bootc |
| `ghcr.io/andyetanotherorg/hermes-site-kubevirt` | site bootc → qcow2 containerDisk (CRC / create `--from`) |

Tags: `nightly`, `YYYYMMDD`, `sha-<short>` (plus `kubevirt` on openshell-supervisor; site also tags `latest`).

**Latest green proof (2026-08-13):** [Actions run 31667054629](https://github.com/andyetanotherorg/openshell-kubevirt/actions/runs/31667054629) — minimal bake (`rebase=false`, `push_images=true`, no containerDisk/site). Image tag table in [`TRACKING.md`](./TRACKING.md) § *nightly-rebuild green on ghcr.io/andyetanotherorg*.

## Published images

- **Seat tip bake:** `honr-registry.default.svc:5000` digests in [`TRACKING.md`](./TRACKING.md)
- Nightly OCI layers + containerDisk: see **GHCR images** above
- Quay mirror (optional): [`quay.io/shanemcd/hermes-sandbox-kubevirt:latest`](https://quay.io/repository/shanemcd/hermes-sandbox-kubevirt)
