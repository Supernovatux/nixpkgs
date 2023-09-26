#!/usr/bin/env nix-shell
#!nix-shell -p coreutils curl.out nix jq gnused -i bash

set -eou pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
tmpfile="$(mktemp --suffix=.nix)"

trap 'rm -rf "$tmpfile"' EXIT

info() { echo "[INFO] $*"; }

echo_file() { echo "$@" >> "$tmpfile"; }

verlte() {
    [  "$1" = "$(echo -e "$1\n$2" | sort -V | head -n1)" ]
}

readonly hashes_nix="hashes.nix"
readonly nixpkgs=../../../../..

readonly current_version="$(nix-instantiate "$nixpkgs" --eval --strict -A graalvm-ce.version --json | jq -r)"

if [[ -z "${1:-}" ]]; then
  readonly gh_version="$(curl \
      ${GITHUB_TOKEN:+"-u \":$GITHUB_TOKEN\""} \
      -s https://api.github.com/repos/graalvm/graalvm-ce-builds/releases/latest | \
      jq --raw-output .tag_name)"
  readonly new_version="${gh_version//jdk-/}"
else
  readonly new_version="$1"
fi

info "Current version: $current_version"
info "New version: $new_version"
if verlte "$new_version" "$current_version"; then
  info "graalvm-ce $current_version is up-to-date."
  [[ -z "${FORCE:-}" ]]  && exit 0
else
  info "graalvm-ce $current_version is out-of-date. Updating..."
fi

declare -r -A products_urls=(
  [graalvm-ce]="https://github.com/graalvm/graalvm-ce-builds/releases/download/jdk-${new_version}/graalvm-community-jdk-${new_version}_@platform@_bin.tar.gz"

)

readonly platforms=(
  "linux-aarch64"
  "linux-x64"
  "macos-aarch64"
  "macos-x64"
)

info "Generating '$hashes_nix' file for 'graalvm-ce' $new_version. This will take a while..."

# Indentation of `echo_file` function is on purpose to make it easier to visualize the output
echo_file "# Generated by $0 script"
echo_file "{"
for product in "${!products_urls[@]}"; do
  url="${products_urls["${product}"]}"
echo_file "  \"$product\" = {"
  for platform in "${platforms[@]}"; do
    args=("${url//@platform@/$platform}")
    # Get current hashes to skip derivations already in /nix/store to reuse cache when the version is the same
    # e.g.: when adding a new product and running this script with FORCE=1
    if [[ "$current_version" == "$new_version" ]] && \
        previous_hash="$(nix-instantiate --eval "$hashes_nix" -A "$product.$platform.sha256" --json | jq -r)"; then
        args+=("$previous_hash" "--type" "sha256")
    else
        info "Hash in '$product' for '$platform' not found. Re-downloading it..."
    fi
    if hash="$(nix-prefetch-url "${args[@]}")"; then
echo_file "    \"$platform\" = {"
echo_file "      sha256 = \"$hash\";"
echo_file "      url = \"${url//@platform@/${platform}}\";"
echo_file "    };"
    else
        info "Error while downloading '$product' for '$platform'. Skipping it..."
    fi
  done
echo_file "  };"
done
echo_file "}"

info "Updating graalvm-ce version..."
# update-source-version does not work here since it expects src attribute
sed "s|$current_version|$new_version|" -i default.nix

info "Moving the temporary file to hashes.nix"
mv "$tmpfile" "$hashes_nix"

info "Done!"
