talconfig := "talos/talconfig.yaml"
rendered := "talos/.rendered"
talosctl := "talosctl --talosconfig talos/.rendered/talosconfig"
render := "kubectl kustomize --enable-helm kubernetes/"
set shell := ["bash", "-euo", "pipefail", "-c"]

# Prints "<hostname> <ip> <controlPlane>" (tab-separated) for every node in
# talconfig.yaml, or only the one whose hostname or IP matches $NODE when it's set.
nodes := "yq -r '.nodes[] | select(strenv(NODE) == \"\" or .hostname == strenv(NODE) or .ipAddress == strenv(NODE)) | [.hostname, .ipAddress, .controlPlane] | @tsv' " + talconfig

[private]
default:
    @just --list --unsorted

# first-time only: generate a fresh Talos secret bundle into 1Password.
[confirm("This generates a FRESH secret bundle. Only for a brand new cluster. (y/N)")]
[group('setup')]
[doc('step 1 · generate cluster secrets into 1Password (new cluster only)')]
talos-secrets-bootstrap:
    scripts/talos-secrets-to-1password.sh

# Create a brand new cluster from booted Talos nodes: apply machine configs, bootstrap etcd,
# set up the secrets backend, apply the manifest tree. Run `just talos-secrets-bootstrap` first.
[confirm("Bootstrap a brand new cluster from the nodes in talconfig.yaml? (y/N)")]
[group('setup')]
[doc('step 2 · build the cluster: nodes, secrets backend, all apps')]
bootstrap:
    {{just_executable()}} --yes talos-bootstrap
    {{just_executable()}} --yes secrets-bootstrap
    {{just_executable()}} --yes k8s-bootstrap

# first-time only: branch protection + the `production` environment for CI,
# on whatever GitHub repo this checkout points at.
[confirm("Set up branch protection and the production environment on this repo's GitHub remote? (y/N)")]
[group('setup')]
[doc('step 3 · configure GitHub branch protection and the production environment')]
ci-setup:
    #!/usr/bin/env bash
    set -euo pipefail
    repo=$(gh repo view --json nameWithOwner -q .nameWithOwner)
    echo "configuring $repo"
    printf '%s' '{"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}' \
      | gh api -X PUT "repos/$repo/environments/production" --input -
    gh api -X POST "repos/$repo/environments/production/deployment-branch-policies" \
      -f name=main -f type=branch
    printf '%s' '{"required_status_checks":{"strict":false,"contexts":["manifests","gitleaks"]},"enforce_admins":false,"required_pull_request_reviews":{"required_approving_review_count":0},"restrictions":null,"allow_force_pushes":false,"allow_deletions":false}' \
      | gh api -X PUT "repos/$repo/branches/main/protection" --input -

# first-time only: push machine configs to freshly booted (maintenance mode) nodes,
# bootstrap etcd on the first control plane node, and fetch the kubeconfig.
[confirm("Bootstrap brand new nodes? Only for first-time setup. Check talconfig.yaml's node list. (y/N)")]
[group('setup steps (part of just bootstrap)')]
[doc('configure fresh Talos nodes and start Kubernetes')]
talos-bootstrap: talos-render
    #!/usr/bin/env bash
    set -euo pipefail
    cluster=$(yq -r .clusterName {{talconfig}})
    rows=$(NODE="" {{nodes}})
    first_cp=""
    while IFS=$'\t' read -r host ip cp <&3; do
      echo "=== $host ($ip)"
      talosctl apply-config --insecure --nodes "$ip" --file "{{rendered}}/$cluster-$host.yaml"
      if [[ -z "$first_cp" && "$cp" == "true" ]]; then first_cp=$ip; fi
    done 3<<<"$rows"
    [[ -n "$first_cp" ]] || { echo "no controlPlane node in {{talconfig}}" >&2; exit 1; }

    echo "waiting for $first_cp to install and reboot..."
    until {{talosctl}} --nodes "$first_cp" version >/dev/null 2>&1; do sleep 10; done
    {{talosctl}} bootstrap --nodes "$first_cp"
    {{talosctl}} kubeconfig --nodes "$first_cp" --force

    # Nodes stay NotReady until Cilium is applied (no CNI ships with Talos here),
    # so wait for the API server only, not `talosctl health`.
    echo "waiting for the API server..."
    until kubectl get --raw /readyz >/dev/null 2>&1; do sleep 10; done

# first-time only: stand up the 1Password Connect server + bootstrap secrets
# that let external-secrets talk to 1Password at all. Everything else syncs
# through ExternalSecrets once this exists.
[confirm("Create a new 1Password Connect server and bootstrap secrets? (y/N)")]
[group('setup steps (part of just bootstrap)')]
[doc('connect the cluster to 1Password')]
secrets-bootstrap:
    op connect server create homelab-k8s --vaults homelab-k8s
    kubectl apply -f kubernetes/apps/external-secrets/00-namespace.yaml
    kubectl -n external-secrets create secret generic op-credentials \
      --from-file=1password-credentials.json
    rm 1password-credentials.json
    op connect token create homelab-k8s --server homelab-k8s --vault homelab-k8s,r \
      | tr -d '\n' \
      | kubectl -n external-secrets create secret generic op-access-token --from-file=token=/dev/stdin

# first-time only: apply the manifest tree to an empty cluster. A single apply fails
# there: custom resources can't bind until their CRDs are established, Cilium's
# operator creates the L2/LB-IPAM CRDs itself at runtime, and the cert-manager and
# external-secrets webhooks reject requests until their pods are up. So apply the
# CRDs first, then retry the full tree until it goes through.
[confirm("Apply the full manifest tree to a fresh cluster? (y/N)")]
[group('setup steps (part of just bootstrap)')]
[doc('install all apps on an empty cluster')]
k8s-bootstrap:
    #!/usr/bin/env bash
    set -euo pipefail
    rendered=$(mktemp); trap 'rm -f "$rendered"' EXIT
    {{render}} > "$rendered"
    yq 'select(.kind == "CustomResourceDefinition")' "$rendered" \
      | kubectl apply --server-side --force-conflicts -f -
    kubectl wait --for=condition=Established crd --all --timeout=120s
    for i in $(seq 1 20); do
      kubectl apply -f "$rendered" --server-side --force-conflicts && exit 0
      echo "apply attempt $i/20 failed (expected while controllers start), retrying in 20s..."
      sleep 20
    done
    echo "manifest tree still not applying cleanly after 20 attempts" >&2
    exit 1

# preview what a k8s-apply would actually change
[group('kubernetes')]
[doc('preview changes to the cluster')]
k8s-diff:
    {{render}} | KUBECTL_EXTERNAL_DIFF=$PWD/.github/scripts/kdiff \
      kubectl diff -f - --server-side --force-conflicts

# apply the full manifest tree, same as CI's deploy.yml.
[confirm("Did you review `just k8s-diff` output first? (y/N)")]
[group('kubernetes')]
[doc('apply changes to the cluster (CI normally does this)')]
k8s-apply:
    {{render}} | kubectl apply -f - --server-side --force-conflicts

# render the kustomize tree and check it against upstream schemas, same as CI's validate.yml
[group('kubernetes')]
[doc('check the manifests for errors, like CI does')]
k8s-validate:
    {{render}} > /tmp/k8s-rendered.yaml
    kubeconform -summary -ignore-missing-schemas \
      -schema-location default \
      -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{{{.Group}}/{{{{.ResourceKind}}_{{{{.ResourceAPIVersion}}.json' \
      /tmp/k8s-rendered.yaml

# diff the rendered machine config against what's live, for every node.
# Run this before every talos-apply.
[group('talos')]
[doc('preview node config changes (all nodes, or one)')]
talos-diff node="": talos-render
    #!/usr/bin/env bash
    set -euo pipefail
    cluster=$(yq -r .clusterName {{talconfig}})
    rows=$(NODE="{{node}}" {{nodes}})
    [[ -n "$rows" ]] || { echo "no node in {{talconfig}} matches '{{node}}'" >&2; exit 1; }
    while IFS=$'\t' read -r host ip _ <&3; do
      echo "=== $host ($ip)"
      {{talosctl}} apply-config --dry-run --nodes "$ip" --file "{{rendered}}/$cluster-$host.yaml"
    done 3<<<"$rows"

# apply the rendered machine config to every node (or just `node`), without rebooting.
[confirm("Did you review `just talos-diff` output first? (y/N)")]
[group('talos')]
[doc('apply node config changes without rebooting (all nodes, or one)')]
talos-apply node="": talos-render
    #!/usr/bin/env bash
    set -euo pipefail
    cluster=$(yq -r .clusterName {{talconfig}})
    rows=$(NODE="{{node}}" {{nodes}})
    [[ -n "$rows" ]] || { echo "no node in {{talconfig}} matches '{{node}}'" >&2; exit 1; }
    while IFS=$'\t' read -r host ip _ <&3; do
      echo "=== $host ($ip)"
      {{talosctl}} apply-config --nodes "$ip" \
        --file "{{rendered}}/$cluster-$host.yaml" --mode=no-reboot
    done 3<<<"$rows"

# reboot every node (or just `node`), one at a time, waiting for each to come back.
[confirm("Reboot now? Each node drops (with anything routed through it) for ~1-2 minutes. (y/N)")]
[group('talos')]
[doc('reboot nodes one at a time (all nodes, or one)')]
talos-reboot node="":
    #!/usr/bin/env bash
    set -euo pipefail
    rows=$(NODE="{{node}}" {{nodes}})
    [[ -n "$rows" ]] || { echo "no node in {{talconfig}} matches '{{node}}'" >&2; exit 1; }
    while IFS=$'\t' read -r host ip _ <&3; do
      echo "=== rebooting $host ($ip)"
      {{talosctl}} reboot --nodes "$ip" --wait
    done 3<<<"$rows"

# regenerate talos/.rendered/ from talconfig.yaml, with secrets from 1Password
[group('talos')]
[doc('regenerate node configs from talconfig.yaml')]
talos-render:
    op run --env-file .env.tpl --no-masking -- \
      talhelper genconfig --config-file {{talconfig}} \
        --out-dir {{rendered}} --secret-file talos/talsecret.yaml
