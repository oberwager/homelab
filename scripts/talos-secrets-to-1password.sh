#!/usr/bin/env bash
# Generates a fresh Talos secret bundle and stores it in 1Password (vault homelab-k8s).
# The bundle only exists in a private temp dir for the duration of the call.
set -euo pipefail

umask 077
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

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
}' > "$tmp/talos-op-template.json"

op item create --vault "homelab-k8s" --template "$tmp/talos-op-template.json"
