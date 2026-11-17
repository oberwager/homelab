# homelab

My homelab runs on a single Talos node. All configuration is kept in this repo, and every change is applied through Github Actions. 
Secrets live in 1Password, and the External Secrets Operator copies them into the cluster.

|            |                                                                                                                                                     |
| ---        | ---                                                                                                                                                 |
| OS         | Talos, no SSH. [talhelper](https://github.com/budimanjojo/talhelper) renders the machine configs.                                                   |
| Ingress    | Cilium Gateway API, with a floating VIP announced over L2 (not tied to one node's IP). cert-manager issues Let's Encrypt certs.                     |
| Secrets    | External Secrets Operator reads 1Password Connect. A kustomize component patches the store onto every `ExternalSecret`.                             |
| Network    | Tailscale subnet router and exit node. CI reaches the API server through it.                                                                        |
| Data       | CloudNative-PG for Postgres, `local-path` storage with a Retain policy. No backup of the node itself since reprovisioning is faster than restoring. |
| Monitoring | Prometheus, Loki, Alloy, Grafana (six dashboards), Alertmanager into ntfy, Uptime Kuma.                                                             |

```
talos/              talhelper config and secret template
kubernetes/
  apps/             one directory per app, each with a kustomization
  components/       shared kustomize patches
  serviceaccounts/  CI service accounts and RBAC
scripts/            bootstrap helpers
renovate.json
.env.tpl            op:// references for talhelper
```

`main` needs a PR with passing `manifests` and `gitleaks` checks. To preview a change before you merge it:

```bash
just k8s-diff
```

Applies are server-side because the operator CRDs exceed the annotation size that client-side apply needs. Cilium is a Helm chart, so `kubectl apply -k` won't work; the justfile and CI use `kubectl kustomize --enable-helm | kubectl apply -f -`.

App repos build, scan, sign (keyless Cosign) and deploy through a shared pipeline, for example [d2-live](https://github.com/oberwager/d2-live/blob/main/.github/workflows/docker-publish.yml).

## Access

- `gha-infra` is cluster-admin and belongs to this repo. Its token is a secret of the `production` environment, which is restricted to `main`.
- `gha-deployer` belongs to the app repos. It creates and updates the kinds they ship and cannot delete.

## Bootstrap

You need `talosctl`, `talhelper`, `op` (signed in to the `homelab-k8s` vault), `yq`, `jq`, `kubectl`, `helm`, `kubeconform`, `gh` and [`just`](https://github.com/casey/just). `just` (no arguments) lists every recipe.

```bash
# 1. Boot Talos on each node: https://www.talos.dev/latest/talos-guides/install/
#    and list them (hostname, IP, controlPlane) under `nodes:` in talos/talconfig.yaml

# 2. Generate the Talos secrets into 1Password (first cluster only -- never rerun this against an existing one)
just talos-secrets-bootstrap

# 3. Configure the nodes, bootstrap etcd, set up the secrets backend, apply everything
just bootstrap
```

`just bootstrap` runs `talos-bootstrap`, `secrets-bootstrap` and `k8s-bootstrap` in order, and each can be run on its own if one step fails. `k8s-bootstrap` applies the CRDs first and then retries the full tree while Cilium, cert-manager and external-secrets come up. It also creates the CI service accounts.

Every later apply runs from CI. For changes by hand, run `just k8s-diff`, then `just k8s-apply`. Talos changes work the same way with `just talos-diff` and `just talos-apply`. Both act on every node in `talconfig.yaml`, or on one if you pass its hostname or IP, e.g. `just talos-diff talos-3k8-fga`.

### 1Password items

Everything lives in the `homelab-k8s` vault.

| Item                          | Field                                | Used by                                                                                                                                                                                                                                                                               |
| ---                           | ---                                  | ---                                                                                                                                                                                                                                                                                   |
| `talos`                       | one section per secret               | Written by `scripts/talos-secrets-to-1password.sh`, read by `op run --env-file .env.tpl`.                                                                                                                                                                                             |
| `cloudflare-api-token-secret` | `api-token`                          | The cert-manager DNS-01 solver for `letsencrypt-prod` (ACME email `tls@lucas.tools`). Needs a Cloudflare API token with DNS edit rights on the zone.                                                                                                                                  |
| `ghcr-pat`                    | `token`                              | A ClusterExternalSecret copies it as a `kubernetes.io/dockerconfigjson` pull secret into every namespace labelled `ghcr-pat=true`. The template writes the field into the registry auth value as is, so store base64 of `<github-user>:<PAT>`. The PAT needs read access to packages. |
| `grafana-admin`               | `password`                           | Grafana admin password.                                                                                                                                                                                                                                                               |
| `tailscale-auth`              | `TS_AUTHKEY`                         | The subnet router joins the tailnet with it. State then persists in the `tailscale-state` Secret.                                                                                                                                                                                     |
| `postgres-backup-r2`          | `ACCESS_KEY_ID`, `ACCESS_SECRET_KEY` | Cloudflare R2 credentials for the `postgres-backup` bucket. The ExternalSecrets of the three Postgres clusters read it, and each cluster backs up under its own prefix.                                                                                                               |
| `GitHub Repo Secrets`         | fields and files                     | CI. See [Secrets](#secrets).                                                                                                                                                                                                                                                          |

## CI setup

Create the `production` environment limited to `main`, and protect `main`. Add no required reviewers to `production`, since the nightly drift job runs in it too. Then install the Renovate GitHub App.

```bash
just ci-setup
```

### Secrets

One 1Password item, `GitHub Repo Secrets` in `homelab-k8s`, feeds every repo through `scripts/setup-repo-secrets.sh`. The service template has its own copy and runs it for new services.

| Secret                                    | Holds                                                     | Goes to                                         |
| ---                                       | ---                                                       | ---                                             |
| `TS_OAUTH_CLIENT_ID`, `TS_OAUTH_AUDIENCE` | Tailscale federated credential                            | every repo                                      |
| `K8S_URL`                                 | `https://192.168.50.203:6443`, reachable over Tailscale   | every repo                                      |
| `K8S_SA_TOKEN`                            | file: `gha-deployer-token` Secret as YAML                 | every repo                                      |
| `INFRA_K8S_SA_TOKEN`                      | file in section `infra`: `gha-infra-token` Secret as YAML | this repo, as a `production` environment secret |

`azure/k8s-set-context` reads the whole Secret object, so the files are `kubectl get secret -o yaml` output.

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
