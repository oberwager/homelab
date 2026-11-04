# Homelab

GitOps configuration for a single-node Kubernetes cluster running on [Talos Linux](https://talos.dev), an immutable, API-driven OS with no SSH and no shell.

## Architecture

The cluster uses push-based GitOps, every application repository shares the same [CI pipeline template](https://github.com/oberwager/d2-live/blob/main/.github/workflows/docker-publish.yml).

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

An image that fails scanning never gets signed, and an unsigned image is rejected at deploy. Cosign uses keyless signing tied to the GitHub Actions OIDC identity, so there are no long-lived signing keys to rotate or leak.

**Secrets** managed by ESO. [1Password Connect](https://developer.1password.com/docs/connect) runs in-cluster as the secret backend. The [External Secrets Operator](https://external-secrets.io) syncs secrets into Kubernetes via a `ClusterSecretStore`. A [Kustomize component](kubernetes/components/external-secret/kustomization.yaml) patches the shared store reference and refresh interval onto every `ExternalSecret` in the repo.

**Networking**: Tailscale runs as a subnet router inside the cluster. CI deploys through the same tailnet via a short-lived OAuth client.

**TLS**: cert-manager issues Let's Encrypt certificates for all ingresses. nginx runs as a DaemonSet, on a multi-node cluster this would be a LoadBalancer or NodePort setup but with a single node I bind to port 80/443 directly.

**OS**: Talos Linux. Node configuration is declarative YAML applied via the Talos API. [`talhelper`](https://github.com/budimanjojo/talhelper) templates per-node machine configs. Secrets are pulled from 1Password at generation time and never stored in the repo.

## Stack

| Component                                                                | Role                                                   |
| ---                                                                      | ---                                                    |
| [Talos Linux](https://talos.dev)                                         | Immutable, API-driven Kubernetes OS — no SSH, no shell |
| [talhelper](https://github.com/budimanjojo/talhelper)                    | Talos config templating with secret injection          |
| [External Secrets Operator](https://external-secrets.io)                 | Syncs secrets from 1Password into Kubernetes           |
| [1Password Connect](https://developer.1password.com/docs/connect)        | In-cluster 1Password API bridge                        |
| [cert-manager](https://cert-manager.io)                                  | Automatic TLS via Let's Encrypt                        |
| [ingress-nginx](https://kubernetes.github.io/ingress-nginx)              | Ingress controller (DaemonSet, hostNetwork)            |
| [Tailscale](https://tailscale.com)                                       | Subnet router + CI deploy tunnel                       |
| [CloudNative-PG](https://cloudnative-pg.io)                              | Operator-managed Postgres                              |
| [Prometheus](https://prometheus.io)                                      | Metrics                                                |
| [Loki](https://grafana.com/oss/loki)                                     | Logs                                                   |
| [Grafana Alloy](https://grafana.com/docs/alloy/latest/)                  | OpenTelemetry collector                                |
| [Grafana](https://grafana.com)                                           | Dashboards                                             |
| [Alertmanager](https://prometheus.io/docs/alerting/latest/alertmanager/) | Alert routing                                          |
| [Uptime Kuma](https://github.com/louislam/uptime-kuma)                   | Uptime monitoring                                      |
| [Cosign](https://docs.sigstore.dev)                                      | Keyless image signing + verification                   |
| [Trivy](https://trivy.dev)                                               | Container vulnerability scanning                       |
| [Gitleaks](https://gitleaks.io)                                          | Secret detection in CI                                 |

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
op run --env-file .env --no-masking -- \
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
