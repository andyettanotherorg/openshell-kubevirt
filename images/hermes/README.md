# Hermes bootc (KubeVirt guest)

Build context for two guest variants that share this directory’s OpenShell
bootstrap (systemd units, virtio prep, supervisor modes). Site CLIs (`gh`,
`glab`, `gws`, `jirahhh`, `oc`/`kubectl`) live in
[`shanemcd/toolbox`](https://github.com/shanemcd/toolbox) `openshell-kubevirt/`
and layer on the **hermes-minimal** bootc image.

| Variant | Containerfile | GHCR bootc | GHCR containerDisk | Workload |
|---------|---------------|------------|--------------------|----------|
| **nemoclaw** (default) | `Containerfile.nemoclaw` | `hermes-sandbox-bootc` | `hermes-sandbox-kubevirt` | `nemoclaw-start-vm` (config seals / MCP integrity) |
| **hermes-minimal** | `Containerfile.minimal` | `hermes-minimal-bootc` | `hermes-minimal-kubevirt` | `hermes-start.sh` → gateway + dashboard processes (`:9119`) |

Both images symlink `/usr/local/bin/sandbox-entrypoint` to the variant
entrypoint. Shared scripts default `OPENSHELL_SANDBOX_COMMAND` to that path.
The nemoclaw guest still uses `nemoclaw-start-vm` (gateway only); PTY
`sitecustomize` + `/dev/pts` remount are shared so Landlock-safe PTYs work if
a dashboard is started. Nested gateway+dashboard is **hermes-minimal /
site only** (process supervisor — not nested systemd; Landlock denies
user-manager cgroups).

```bash
cp -n hermes.env.example hermes.env
: > extra-ca-certs.pem

# NemoClaw variant (needs localhost/nemoclaw-hermes:kubevirt)
podman build \
  --build-arg OPENSHELL_SUPERVISOR_IMAGE=localhost/openshell-supervisor:kubevirt \
  -f Containerfile.nemoclaw \
  -t localhost/hermes-sandbox-bootc:latest .

# Minimal variant (installs Hermes from pinned NousResearch tarball)
podman build \
  --build-arg OPENSHELL_SUPERVISOR_IMAGE=localhost/openshell-supervisor:kubevirt \
  -f Containerfile.minimal \
  -t localhost/hermes-minimal-bootc:latest .
```

Hermes version pins for **minimal** (`HERMES_VERSION` / `HERMES_SEMVER` /
`HERMES_TARBALL_SHA256`) live as `ARG`s in `Containerfile.minimal`. The
nemoclaw variant takes Hermes from the `nemoclaw-hermes` image.

## Supervisor modes (runtime switch)

| Mode | How | Hermes | Landlock |
|------|-----|--------|----------|
| **combined** (default) | `openshell-sandbox` `--mode network,process` | child of supervisor | yes |
| **network** | `openshell-sandbox` `--mode network` + `sandbox-workload` | sibling in sandbox netns | no |

```bash
# On the guest (root):
openshell-supervisor-mode status
openshell-supervisor-mode network    # split / no Landlock
openshell-supervisor-mode combined   # default Pod-like path

# Persist across recreate:
openshell sandbox create ... --env "SUPERVISOR_MODE=network"
# omit SUPERVISOR_MODE for combined
```

Network mode forces Hermes through the OpenShell proxy by entering the sandbox
netns (`nsenter`), sourcing snapshotted `provider.env` + `/etc/sandbox/env`,
and trusting `/etc/openshell-tls/{ca-bundle,openshell-ca}.pem`.
`trust-openshell-ca.sh` (ExecStartPost) also installs `openshell-ca.pem` into
`/etc/pki/ca-trust/source/anchors/` + `update-ca-trust` so tools that ignore
`SSL_CERT_FILE` still trust the MITM proxy.

L7 identity: network-only never spawns a process leaf, so the supervisor must
adopt the sibling workload PID. OpenShell (`vm-runtime-backend`) watches
`/run/openshell/entrypoint.pid` (written by `sandbox-workload-run.sh`) and uses
that PID as the `/proc/<pid>/net/tcp` anchor — the network leaf stays in the
host netns while Hermes is in the sandbox netns.

Boot: `openshell-sandbox` runs prep as `ExecStartPre` (writes
`/run/openshell/want-workload` when `SUPERVISOR_MODE=network`).
`sandbox-workload` is `WantedBy=openshell-sandbox` with `After=` +
`ConditionPathExists` on that gate — no path unit or scripted `systemctl start`.

Rootless podman: image enables linger for `sandbox` (`/var/lib/systemd/linger/sandbox`)
so `user@10001` provides `/run/user/10001` + session bus at boot.
`sandbox-workload-run.sh` sets `XDG_RUNTIME_DIR` and `DBUS_SESSION_BUS_ADDRESS`
after the uid drop context is prepared.

Override the workload with `OPENSHELL_SANDBOX_COMMAND` / gateway `sandbox_command`
if needed.

## Dashboard (hermes-minimal / site)

`hermes-start.sh` keeps OpenShell’s Landlock/netns tree and runs:

| Process | Role |
|---------|------|
| `hermes gateway run` | Messaging gateway |
| `hermes dashboard` | Web UI on `127.0.0.1:9119` with `HERMES_TUI_DIR=/opt/hermes/ui-tui` |

Proxy/TLS env from OpenShell is inherited by both children (and snapshotted
to `/sandbox/.hermes/runtime/workload.env` for debugging). Optional
`hermes-*.service` user units ship in the image for experiments, but the
default entrypoint does **not** nest `systemd --user` — combined-mode
Landlock cannot allocate that manager’s cgroups.

| Extra | Role |
|-------|------|
| `sitecustomize.py` | In Hermes venv `site-packages` + `PYTHONPATH`; routes `openpty` to `/dev/pts/ptmx` (OpenShell denies `/dev/ptmx`) |
| `workload.env` | Written by `hermes-start` each boot; carries `HTTPS_PROXY` / CA for inspection |

`prepare-sandbox-volumes.sh` remounts `/dev/pts` with `ptmxmode=666` so
`/dev/pts/ptmx` is usable inside the Landlock tree.

Host: only port-forward after the sandbox is Ready:

```bash
export OPENSHELL_GATEWAY=crc
openshell forward service <sandbox> --target-port 9119 --local 9119
# → http://127.0.0.1:9119
```

Inspect inside the guest:

```bash
openshell sandbox exec -- bash -lc 'pgrep -af "hermes gateway|hermes dashboard"; tail -n 50 /sandbox/.hermes/runtime/*.log'
```