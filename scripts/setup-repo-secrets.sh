#!/usr/bin/env bash
# AI Generated.
# Copies the fields and files of a 1Password item into GitHub Actions secrets on
# the given repo.
# Override defaults with GH_ORG, OP_ITEM, OP_VAULT.
#
# Infra secrets: anything in a section labelled `infra`, and anything whose name
# starts with INFRA_, is a cluster-admin credential that only the homelab repo
# may hold. It is skipped unless INCLUDE_INFRA=1, so an app repo can never
# receive it:
#   INCLUDE_INFRA=1 ./setup-repo-secrets.sh homelab
# When included, infra secrets are stored as secrets of the INFRA_ENV environment
# (default `production`), not as repository secrets. Restrict that environment to
# the main branch in the repo settings, and pull request workflows can never read
# them. The environment must already exist.
set -euo pipefail

REPO=${1:?Usage: ./setup-repo-secrets.sh <repo-name>}
GH_ORG="${GH_ORG:-oberwager}"
OP_ITEM="${OP_ITEM:-GitHub Repo Secrets}"
OP_VAULT="${OP_VAULT:-homelab-k8s}"
INCLUDE_INFRA="${INCLUDE_INFRA:-0}"
INFRA_ENV="${INFRA_ENV:-production}"

echo "Setting up secrets for ${GH_ORG}/${REPO}..."
if [ "$INCLUDE_INFRA" = "1" ]; then
  echo "  (including infra secrets, stored in the ${INFRA_ENV} environment)"
fi

item_json=$(op item get "${OP_ITEM}" --vault "${OP_VAULT}" --format json)

# Reads the secret value on stdin. Infra secrets go to the environment.
secret_set() {
  local name="$1" scope="$2"
  if [ "$scope" = "env" ]; then
    gh secret set "$name" --repo "${GH_ORG}/${REPO}" --env "${INFRA_ENV}"
  else
    gh secret set "$name" --repo "${GH_ORG}/${REPO}"
  fi
}

# The field and file lists are built in variables first. A failure inside a
# `done < <(jq ...)` process substitution is invisible to `set -e`, so the loop
# would just end early and still print "Done." with secrets missing.
# The last column is where the secret is stored: "env" for infra, "repo" otherwise.
fields=$(jq -r --arg inc "$INCLUDE_INFRA" '.fields[]
  | select((.label // "") != "" and .value != null and .value != "" and .label != "notesPlain")
  | ((((.section.label // "") | ascii_downcase) == "infra") or (.label | startswith("INFRA_"))) as $infra
  | select($inc == "1" or ($infra | not))
  | "\(.label)\t\(.value | @base64)\t\(if $infra then "env" else "repo" end)"' <<<"$item_json")

# File fields (like K8S_SA_TOKEN). Each line is "<name><TAB><section label or ->
# <TAB><scope>". Every column is non-empty: `read` collapses adjacent tabs, so an
# empty column would shift the ones after it.
files=$(jq -r --arg inc "$INCLUDE_INFRA" '.files[]?
  | select((.name // "") != "")
  | ((((.section.label // "") | ascii_downcase) == "infra") or (.name | startswith("INFRA_"))) as $infra
  | select($inc == "1" or ($infra | not))
  | "\(.name)\t\(.section.label // "-")\t\(if $infra then "env" else "repo" end)"' <<<"$item_json")

# Secret values travel base64-encoded through the loop and over stdin to gh,
# never as command-line arguments (those are visible in `ps`). The loop reads
# from fd 3 so gh can't swallow the loop's own input.
if [ -n "$fields" ]; then
  while IFS=$'\t' read -r -u 3 label b64 scope; do
    echo "  Setting ${label} (${scope})..."
    printf '%s' "$b64" | base64 --decode | secret_set "${label}" "${scope}"
  done 3<<<"$fields"
fi

if [ -n "$files" ]; then
  while IFS=$'\t' read -r -u 3 name section scope; do
    echo "  Setting ${name} (file, ${scope})..."
    ref="op://${OP_VAULT}/${OP_ITEM}/${name}"
    # A file in a section is read through its section when we know the label.
    if [ "$section" != "-" ] && op read "op://${OP_VAULT}/${OP_ITEM}/${section}/${name}" >/dev/null 2>&1; then
      ref="op://${OP_VAULT}/${OP_ITEM}/${section}/${name}"
    fi
    op read "$ref" | secret_set "${name}" "${scope}"
  done 3<<<"$files"
fi

echo "Done."
