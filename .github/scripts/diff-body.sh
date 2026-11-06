#!/usr/bin/env bash
# Renders `kubectl diff` output as markdown for a PR comment or issue body.
#   diff-body.sh <diff.txt> <diff.err> <kubectl exit code>
# The diff is untrusted text (ConfigMaps and upstream manifests can contain
# anything, including backtick fences), so it is wrapped in a fence longer than
# any run of backticks inside it, and cut at a UTF-8 boundary.
set -euo pipefail

diff_file=$1 err_file=$2 code=$3
limit=60000

# A backtick fence one longer than the longest run in the file, minimum three.
fence() {
  local max n
  max=$(grep -o '`\+' "$1" 2>/dev/null | awk '{ if (length($0) > m) m = length($0) } END { print m + 0 }')
  n=$(( max < 3 ? 3 : max + 1 ))
  printf '%*s' "$n" '' | tr ' ' '`'
}

# First $limit bytes with any trailing partial multibyte character dropped.
# iconv exits 1 when it drops an incomplete trailing character, which is the point.
clip() { head -c "$limit" "$1" | iconv -c -f UTF-8 -t UTF-8 2>/dev/null || true; }

if [ "$code" -gt 1 ]; then
  # kubectl failed (for example a namespace in this change does not exist yet,
  # which `kubectl diff` reports as NotFound). Show why; drop PodSecurity noise.
  grep -v '^Warning:' "$err_file" > "${err_file}.clean" || true
  f=$(fence "${err_file}.clean")
  echo "The diff could not be computed (kubectl exit code $code). A new namespace, or a custom resource whose CRD is added in the same change, makes \`kubectl diff\` fail even though the change applies fine."
  echo
  echo "${f}"
  clip "${err_file}.clean"
  echo
  echo "${f}"
elif [ -s "$diff_file" ]; then
  f=$(fence "$diff_file")
  echo "<details><summary>kubectl diff</summary>"
  echo
  echo "${f}diff"
  clip "$diff_file"
  echo
  echo "${f}"
  echo
  echo "</details>"
  if [ "$(wc -c < "$diff_file")" -gt "$limit" ]; then
    echo
    echo "_Truncated at 60 kB; see the job log for the rest._"
  fi
else
  echo "No changes: the cluster already matches this branch."
fi
