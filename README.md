# Homelab

Git-driven configuration for a single-node Kubernetes cluster on [Talos Linux](https://talos.dev), an immutable, API-driven OS with no SSH and no shell.

## Highlights

- **Open source infrastructure with no secrets in git.** Everything from the Talos PKI to application credentials lives in 1Password and is injected at generation or sync time. The repo contains only `op://` references.
- **Signed, scanned deploys.** Images are secret-scanned, vulnerability-scanned, signed with keyless Cosign, and verified again before `kubectl apply`.
- **No exposed management plane.** Deploys reach the cluster over a Tailscale tunnel using short-lived OAuth credentials. Talos has no SSH.
- **Observability built in.** Prometheus, Loki, Alloy, and Alertmanager, with six custom Grafana dashboards and Uptime Kuma for external checks.
- **Rebuildable from bare metal.** The [setup guide](#setup) reproduces the cluster from a fresh Talos install.

## Architecture

Deploys are push-based. Every application repository shares the same [CI pipeline template](https://github.com/oberwager/d2-live/blob/main/.github/workflows/docker-publish.yml), which lives in the each service repo, like [d2-live](https://github.com/oberwager/d2-live).

```
push to main
     │
     ▼
 [build job]
     ├── Gitleaks, scan for committed secrets
     ├── Docker build,  SBOM + provenance attestation
     ├── Trivy: vulnerability scan, blocks on CRITICAL/HIGH
     ├── Cosign: keyless image signing via GitHub OIDC
     └── semver tag + GitHub Release (auto-generated notes)
          │
          ▼
    [deploy job]
          ├── Tailscale OAuth to cluster
          ├── Cosign verify signature
          └── kubectl apply
```

An image that fails scanning is never signed, and an unsigned image is rejected at deploy. Cosign signs keylessly against the GitHub Actions OIDC identity, so there are no long-lived signing keys to rotate or leak.

**Secrets.** [1Password Connect](https://developer.1password.com/docs/connect) runs in-cluster as the secret backend, and the [External Secrets Operator](https://external-secrets.io) syncs from it through a `ClusterSecretStore`. A [Kustomize component](kubernetes/components/external-secret/kustomization.yaml) patches the shared store reference and refresh interval onto every `ExternalSecret`, so individual manifests carry no boilerplate.

**Networking.** Tailscale runs in-cluster as a subnet router. CI deploys through the same tailnet with a short-lived OAuth client.

**TLS and ingress.** cert-manager issues Let's Encrypt certificates for every ingress. nginx runs as a DaemonSet bound to ports 80 and 443 on the host. A multi-node cluster would use a LoadBalancer or NodePort instead.

**OS.** Talos node configuration is declarative YAML applied through the Talos API. [`talhelper`](https://github.com/budimanjojo/talhelper) renders per-node machine configs, pulling secrets from 1Password at generation time.

**Databases.** [CloudNative-PG](https://cloudnative-pg.io) runs Postgres for the applications on the cluster, with backups.

## Repository layout

```
.
├── talos/
│   ├── talconfig.yaml          # Node definitions for talhelper
│   └── talsecret.yaml          # Secret template, values resolved from 1Password
├── kubernetes/
│   ├── kustomization.yaml      # Root: composes everything below
│   ├── apps/
│   │   ├── cert-manager/       # Issuers and ACME credentials
│   │   ├── external-secrets/   # ESO, 1Password Connect, ClusterSecretStore
│   │   ├── nginx/              # Ingress controller (DaemonSet)
│   │   ├── tailscale/          # Subnet router and exit node
│   │   ├── metrics/            # Prometheus, Loki, Alloy, Grafana, Alertmanager
│   │   │   ├── configs/        # Per-service config files
│   │   │   └── dashboards/     # Grafana dashboards as JSON
│   │   ├── kuma/               # Uptime Kuma
│   │   ├── postgres/           # CloudNative-PG clusters
│   │   └── local-path/         # Storage class with Retain policy
│   ├── components/
│   │   └── external-secret/    # Shared patch applied to every ExternalSecret
│   └── serviceaccounts/        # Scoped RBAC for CI deploys and Prometheus
└── .env.tpl                    # op:// references only, no values
```

## Stack

| Component                                                                | Role                                                     |
| ---                                                                      | ---                                                      |
| [Talos Linux](https://talos.dev)                                         | Immutable, API-driven Kubernetes OS with no SSH or shell |
| [talhelper](https://github.com/budimanjojo/talhelper)                    | Talos config templating with secret injection            |
| [External Secrets Operator](https://external-secrets.io)                 | Syncs secrets from 1Password into Kubernetes             |
| [1Password Connect](https://developer.1password.com/docs/connect)        | In-cluster 1Password API bridge                          |
| [cert-manager](https://cert-manager.io)                                  | Automatic TLS via Let's Encrypt                          |
| [ingress-nginx](https://kubernetes.github.io/ingress-nginx)              | Ingress controller (DaemonSet, hostNetwork)              |
| [Tailscale](https://tailscale.com)                                       | Subnet router + CI deploy tunnel                         |
| [CloudNative-PG](https://cloudnative-pg.io)                              | Operator-managed Postgres                                |
| [Prometheus](https://prometheus.io)                                      | Metrics                                                  |
| [Loki](https://grafana.com/oss/loki)                                     | Logs                                                     |
| [Grafana Alloy](https://grafana.com/docs/alloy/latest/)                  | OpenTelemetry collector                                  |
| [Grafana](https://grafana.com)                                           | Dashboards                                               |
| [Alertmanager](https://prometheus.io/docs/alerting/latest/alertmanager/) | Alert routing                                            |
| [Uptime Kuma](https://github.com/louislam/uptime-kuma)                   | Uptime monitoring                                        |
| [Cosign](https://docs.sigstore.dev)                                      | Keyless image signing + verification                     |
| [Trivy](https://trivy.dev)                                               | Container vulnerability scanning                         |
| [Gitleaks](https://gitleaks.io)                                          | Secret detection in CI                                   |

## Setup

Making this repo fully open-sourceable required stripping every secret out of git history and wiring up the entire bootstrap flow through 1Password. The steps below reproduce a cluster from zero with no secrets in plain text at any point.

<details>
<summary>Bootstrap instructions</summary>

### Prerequisites

- [Talos CLI (`talosctl`)](https://www.talos.dev/latest/introduction/getting-started/)
- [talhelper](https://github.com/budimanjojo/talhelper)
- [1Password CLI (`op`)](https://developer.1password.com/docs/cli/get-started/), signed in to a vault called `homelab-k8s`
- `yq`, `jq`

### 1. Install Talos Linux

Follow the [official installation docs](https://www.talos.dev/latest/talos-guides/install/) to boot Talos. Note your node's IP address.

### 2. Bootstrap Talos secrets into 1Password

Generate a fresh secret bundle and store it in 1Password so it never touches disk:

```bash
talhelper gensecret | yq eval -o=json | jq '{
  title: "talos",
  category: "SECURE_NOTE",
  sections: [
    {id: "cluster",                 label: "cluster"},
    {id: "secrets",                 label: "secrets"},
    {id: "trustdinfo",              label: "trustdinfo"},
    {id: "certs_etcd",              label: "certs.etcd"},
    {id: "certs_k8s",               label: "certs.k8s"},
    {id: "certs_k8saggregator",     label: "certs.k8saggregator"},
    {id: "certs_k8sserviceaccount", label: "certs.k8sserviceaccount"},
    {id: "certs_os",                label: "certs.os"}
  ],
  fields: [
    {section: {id: "cluster"},                 label: "id",                        type: "CONCEALED", value: .cluster.id},
    {section: {id: "cluster"},                 label: "secret",                    type: "CONCEALED", value: .cluster.secret},
    {section: {id: "secrets"},                 label: "bootstraptoken",            type: "CONCEALED", value: .secrets.bootstraptoken},
    {section: {id: "secrets"},                 label: "secretboxencryptionsecret", type: "CONCEALED", value: .secrets.secretboxencryptionsecret},
    {section: {id: "trustdinfo"},              label: "token",                     type: "CONCEALED", value: .trustdinfo.token},
    {section: {id: "certs_etcd"},              label: "crt",                       type: "CONCEALED", value: .certs.etcd.crt},
    {section: {id: "certs_etcd"},              label: "key",                       type: "CONCEALED", value: .certs.etcd.key},
    {section: {id: "certs_k8s"},               label: "crt",                       type: "CONCEALED", value: .certs.k8s.crt},
    {section: {id: "certs_k8s"},               label: "key",                       type: "CONCEALED", value: .certs.k8s.key},
    {section: {id: "certs_k8saggregator"},     label: "crt",                       type: "CONCEALED", value: .certs.k8saggregator.crt},
    {section: {id: "certs_k8saggregator"},     label: "key",                       type: "CONCEALED", value: .certs.k8saggregator.key},
    {section: {id: "certs_k8sserviceaccount"}, label: "key",                       type: "CONCEALED", value: .certs.k8sserviceaccount.key},
    {section: {id: "certs_os"},                label: "crt",                       type: "CONCEALED", value: .certs.os.crt},
    {section: {id: "certs_os"},                label: "key",                       type: "CONCEALED", value: .certs.os.key}
  ]
}' > /tmp/talos-op-template.json && op item create --vault "homelab-k8s" --template /tmp/talos-op-template.json
```

### 3. Generate Talos machine configs

Pull secrets from 1Password and render the node configs:

```bash
op run --env-file .env.tpl --no-masking -- \
  talhelper genconfig \
    --config-file talos/talconfig.yaml \
    --out-dir talos/.rendered \
    --secret-file talos/talsecret.yaml
```

### 4. Apply config and bootstrap the cluster

```bash
talosctl apply-config \
  --talosconfig talos/.rendered/talosconfig \
  --nodes <YOUR_NODE_IP> \
  --file talos/.rendered/<YOUR_NODE_HOSTNAME>.yaml

talosctl bootstrap \
  --talosconfig talos/.rendered/talosconfig \
  --nodes <YOUR_NODE_IP>
```

For multi-node clusters, apply the config to each node before bootstrapping. See [Talos docs](https://www.talos.dev/latest/talos-guides/install/) for details.

### 5. Get kubeconfig

```bash
talosctl kubeconfig --talosconfig talos/.rendered/talosconfig
```

### 6. Deploy cluster manifests

```bash
kubectl apply -k kubernetes/
```

This applies the full stack: cert-manager, ingress-nginx, External Secrets Operator, 1Password Connect, Tailscale, the observability stack, and all applications.

</details>
