# homelab

One Kubernetes node running [Talos Linux](https://talos.dev). Git holds the config, 1Password holds the secrets, and CI applies every merge to `main`. The repo contains `op://` references and no secret values.

| | |
| --- | --- |
| OS | Talos, no SSH. [talhelper](https://github.com/budimanjojo/talhelper) renders the machine configs. |
| Ingress | ingress-nginx as a DaemonSet on host ports 80 and 443. cert-manager issues Let's Encrypt certs. |
| Secrets | External Secrets Operator reads 1Password Connect. A kustomize component patches the store onto every `ExternalSecret`. |
| Network | Tailscale subnet router and exit node. CI reaches the API server through it. |
| Data | CloudNative-PG for Postgres, `local-path` storage with a Retain policy. |
| Monitoring | Prometheus, Loki, Alloy, Grafana (six dashboards), Alertmanager into ntfy, Uptime Kuma. |

```
talos/              talhelper config and secret template
kubernetes/
  apps/             one directory per app, each with a kustomization
  components/       shared kustomize patches
  serviceaccounts/  CI service accounts and RBAC
scripts/            bootstrap helpers
.github/            workflows, the cluster login action, kdiff
renovate.json
.env.tpl            op:// references for talhelper
```

## How changes ship

- **Pull request:** `validate` renders the kustomization and runs kubeconform and gitleaks. It gets no secrets and no cluster access, because a PR runs whatever workflow code its branch holds.
- **Merge to `main`:** `deploy` runs `kubectl apply -k kubernetes/ --server-side --force-conflicts`, then waits for every Deployment, StatefulSet and DaemonSet to roll out. A stalled rollout fails the run.
- **Nightly:** `drift` diffs the cluster against `main` and opens an issue while they differ. Prometheus alerts on rollouts that stall between deploys.
- **Renovate** bumps images, release URLs, and the Talos and Kubernetes versions. Minor and patch image bumps merge once `validate` passes. Operators, Tailscale, Talos, Kubernetes and majors wait for review. Upgrade Talos and Kubernetes by hand with `talosctl`.

`main` needs a PR with passing `manifests` and `gitleaks` checks. To preview a change before you merge it:

```bash
KUBECTL_EXTERNAL_DIFF=$PWD/.github/scripts/kdiff \
  kubectl diff -k kubernetes/ --server-side --force-conflicts
```

Applies are server-side because the operator CRDs exceed the annotation size that client-side apply needs. Prometheus, Loki and Grafana use `Recreate`: a new pod can't take the database lock while the old one holds it.

App repos build, scan, sign (keyless Cosign) and deploy through a shared pipeline, for example [d2-live](https://github.com/oberwager/d2-live/blob/main/.github/workflows/docker-publish.yml). The deploy step verifies the signature before it applies.

## Access

- `gha-infra` is cluster-admin and belongs to this repo. Its token is a secret of the `production` environment, which is restricted to `main`.
- `gha-deployer` belongs to the app repos. It creates and updates the kinds they ship and cannot delete. It can still create workloads in any namespace, so a pod can run as `gha-infra`. Treat `K8S_SA_TOKEN` as sensitive. Per-namespace roles or a ValidatingAdmissionPolicy would close the gap.

## Bootstrap

You need `talosctl`, `talhelper`, `op` (signed in to the `homelab-k8s` vault), `yq`, `jq`, `kubectl` and `gh`.

```bash
# 1. Boot Talos on the node: https://www.talos.dev/latest/talos-guides/install/

# 2. Generate the Talos secrets into 1Password
scripts/talos-secrets-to-1password.sh

# 3. Render the machine configs, with secrets pulled from 1Password
op run --env-file .env.tpl --no-masking -- \
  talhelper genconfig --config-file talos/talconfig.yaml \
    --out-dir talos/.rendered --secret-file talos/talsecret.yaml

# 4. Apply the config (once per node), then bootstrap
talosctl apply-config --talosconfig talos/.rendered/talosconfig \
  --nodes <ip> --file talos/.rendered/<hostname>.yaml
talosctl bootstrap --talosconfig talos/.rendered/talosconfig --nodes <ip>

# 5. Fetch the kubeconfig and apply everything
talosctl kubeconfig --talosconfig talos/.rendered/talosconfig
kubectl apply -k kubernetes/ --server-side --force-conflicts
```

Step 5 also creates the CI service accounts. Every later apply runs from CI.

## CI setup

Create the `production` environment limited to `main`, and protect `main`. Add no required reviewers to `production`, since the nightly drift job runs in it too. Then install the Renovate GitHub App.

```bash
printf '%s' '{"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}' \
  | gh api -X PUT repos/<owner>/homelab/environments/production --input -
gh api -X POST repos/<owner>/homelab/environments/production/deployment-branch-policies \
  -f name=main -f type=branch

gh api -X PUT repos/<owner>/homelab/branches/main/protection --input - <<'JSON'
{
  "required_status_checks": { "strict": false, "contexts": ["manifests", "gitleaks"] },
  "enforce_admins": false,
  "required_pull_request_reviews": { "required_approving_review_count": 0 },
  "restrictions": null,
  "allow_force_pushes": false,
  "allow_deletions": false
}
JSON
```

### Secrets

One 1Password item, `GitHub Repo Secrets` in `homelab-k8s`, feeds every repo through `setup-repo-secrets.sh` (kept in the service template, which runs it for new services).

| Secret | Holds | Goes to |
| --- | --- | --- |
| `TS_OAUTH_CLIENT_ID`, `TS_OAUTH_AUDIENCE` | Tailscale federated credential | every repo |
| `K8S_URL` | `https://192.168.50.203:6443`, reachable over Tailscale | every repo |
| `K8S_SA_TOKEN` | file: `gha-deployer-token` Secret as YAML | every repo |
| `INFRA_K8S_SA_TOKEN` | file in section `infra`: `gha-infra-token` Secret as YAML | this repo, as a `production` environment secret |

`azure/k8s-set-context` reads the whole Secret object, so the files are `kubectl get secret -o yaml` output. The script skips anything in the `infra` section or named `INFRA_*` unless `INCLUDE_INFRA=1`, so app repos never receive the cluster-admin token.

```bash
umask 077; tmp=$(mktemp -d)
kubectl -n kube-system get secret gha-deployer-token -o yaml > "$tmp/K8S_SA_TOKEN"
kubectl -n kube-system get secret gha-infra-token    -o yaml > "$tmp/INFRA_K8S_SA_TOKEN"
op item edit "GitHub Repo Secrets" --vault homelab-k8s \
  "K8S_SA_TOKEN[file]=$tmp/K8S_SA_TOKEN" \
  "infra.INFRA_K8S_SA_TOKEN[file]=$tmp/INFRA_K8S_SA_TOKEN"
rm -rf "$tmp"

INCLUDE_INFRA=1 ../setup-repo-secrets.sh homelab
```

To rotate a token, delete its Secret in `kube-system`, reapply `kubernetes/serviceaccounts`, and run the block above again. The old token stops working when you delete the Secret.

The Tailscale credential trusts the OIDC subject `repo:oberwager@28853408/homelab@1188750354:environment:production`. Deploy and drift both send it, and the `repo:oberwager@28853408/*:environment:production` wildcard the app repos use already matches. Pull requests get no subject. If a job fails with `403` on the token exchange, the credential page shows the subject GitHub sent; add that string.
