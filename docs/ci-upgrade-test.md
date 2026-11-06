# CI upgrade test plan

## Goal

Prove that a PR's `kubernetes/` tree installs and upgrades in place from `main`, on a clean cluster, with no secrets and no tailnet. The job then runs on every PR, and Renovate can merge more bumps without a human looking.

`validate` renders the YAML and checks schemas. It cannot catch the failures that cost us time, because each one needed a live apply:

- The kustomize `labels` block injected `part-of` into Deployment selectors. Selectors are immutable, so the apply failed.
- Tailscale's new pod needed `NET_ADMIN`, PodSecurity `baseline` rejected it, and the old pod kept serving for 157 days.
- Prometheus and Loki hold a database lock on a hostPath volume. A `RollingUpdate` started the new pod while the old pod held the lock, and the new pod crash-looped.
- A StatefulSet will not roll forward over a crash-looping pod. Kuma stayed broken until we deleted the pod by hand.
- The ingress-nginx manifest is vendored by hand. An image-only bump can leave the RBAC behind the controller.

## Design

Add `.github/workflows/cluster-test.yml`. Trigger it on `pull_request` and on pushes to `renovate/**` branches. Give it `permissions: contents: read`, no secrets, and no `id-token`. A PR can run arbitrary workflow code, so the job gets nothing worth stealing.

Start with `kind`. `talosctl cluster create` (Talos in Docker) is closer to production but slower and flakier, so it comes in phase 4.

1. **Create the cluster.** Use `test/kind.yaml` with port mappings for 80 and 443.
2. **Build the overlay.** Put it in `test/kustomization.yaml` and `test/patches/`. It references `../kubernetes` and leaves production manifests untouched. It patches out what needs the outside world:
   - Replace the `onepassword` ClusterSecretStore with the ESO `fake` provider. Seed fake values for the four items the ExternalSecrets read: `cloudflare-api-token-secret`, `ghcr-pat`, `grafana-admin`, `tailscale-auth`.
   - Drop `apps/external-secrets/1password-connect.yaml`. Connect needs real credentials.
   - Replace the `letsencrypt-prod` ClusterIssuer with a `selfSigned` issuer under the same name, so Ingress annotations still resolve.
   - Drop `apps/tailscale`. It needs a real auth key and tailnet.
   - Drop `apps/local-path`. kind ships its own provisioner in the same namespace.
   - Delete the hostPath PVs in `metrics`, `kuma` and `external-secrets`, and change `storageClassName: manual` to `standard` in those PVCs and in Kuma's `volumeClaimTemplates`.
   - Keep nginx's `hostPort` 80 and 443 and let the kind port mappings expose them. Keep node-exporter's `hostNetwork`.
3. **Install the baseline.** Check out the PR's base commit (for a Renovate branch with no PR, `origin/main`). Run `kubectl apply -k test/ --server-side --force-conflicts` and wait for every Deployment, StatefulSet and DaemonSet. Reuse the loop from the `Wait for rollouts` step in `deploy.yml`, moved into `.github/scripts/wait-rollouts.sh` so both workflows call it.
4. **Upgrade.** Check out the PR head and apply the same overlay with the same flags production uses. Wait again. This step reproduces the selector, PodSecurity, lock and stalled-rollout failures.
5. **Smoke test.** Run `test/smoke.sh`.

## Smoke tests

- Create a test Ingress and request it with a `Host` header. The ingress controller must answer.
- Create a Certificate against the selfSigned issuer. cert-manager must mark it Ready.
- Create a fake ExternalSecret. ESO must sync it into a Secret.
- Create a one-instance CNPG Cluster. It must reach healthy and accept an `INSERT`.
- Query Prometheus. Every scrape target must report `up`. Alertmanager must answer on `/-/healthy`.
- Grafana `/api/health` and Loki `/ready` must return OK.
- Check the rollout alerts by expression, not by waiting. The `for:` windows (10 to 30 minutes) exceed a CI budget, so run the expressions from `kubernetes/apps/metrics/configs/cluster.yml` as queries: `kube_deployment_status_condition{condition="Progressing",status="false"} == 1`, the StatefulSet and DaemonSet equivalents, and `DeploymentReplicasMismatch`. Each query must return nothing.
- Ignore these alerts in a throwaway cluster: `NodeHighCpuUsage`, `NodeHighMemoryUsage`, `NodeDiskPressure`, `CronJobFailed`, `CronJobNotScheduled`.

## Limits

The test does not cover:

- Data migrations: Kuma 2, Grafana 13, CNPG instance-manager upgrades, and anything that holds real data.
- Hardware-specific behaviour: hostPath directories, Talos, Tailscale.
- The real 1Password and Cloudflare paths.

These PRs stay manual: stateful majors, Talos, Kubernetes, and operators that restart database pods. Each needs a verified backup first.

## Phases

| Phase | What | Files | Effort |
| --- | --- | --- | --- |
| 1 | Render, schema, gitleaks. Exists. | `validate.yml` | done |
| 2 | Upgrade test on kind | `cluster-test.yml`, `test/kind.yaml`, `test/kustomization.yaml`, `test/patches/*`, `test/smoke.sh`, `.github/scripts/wait-rollouts.sh` | 1 to 2 days, spent tuning the overlay until it passes |
| 3 | Post-deploy gate on the real cluster | `deploy.yml`, `.github/scripts/post-deploy-gate.sh` | half a day |
| 4 | Talos in Docker for fidelity | `test/talos/`, a second job in `cluster-test.yml` | 1 to 2 days, expect flakiness |

Phase 3 runs after `Wait for rollouts`. Watch for about ten minutes: no new firing alert, all Prometheus targets up, key URLs return 200. On failure, open an issue and revert the merge commit.

## Renovate

Once the phase 2 job is a required check, change `renovate.json`:

- Add `"minimumReleaseAge": "3 days"`.
- Narrow automerge. The current rule matches every minor, patch and digest bump from the `kubernetes` and `github-actions` managers. That includes Prometheus, Loki, Grafana, Kuma and 1Password Connect, and `validate` is the sole gate. Add a rule that sets `automerge: false` for those stateful images.
- Keep `needs-review` for cert-manager, External Secrets, CloudNative-PG, ingress-nginx, Tailscale, Talos, Kubernetes and all majors.

Required status check names must match job names. Today `manifests` and `gitleaks` match the `validate.yml` job ids. Name the new job `upgrade-test` and add that string to the branch protection contexts.

## Open decisions

- kind first, or go straight to Talos in Docker?
- Runner time budget. Expect 8 to 12 minutes per run. Public repos get free minutes.
- Should a failing upgrade test block automerge alone, or also block merging by hand? Admin bypass stays available either way.
