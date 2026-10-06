#!/usr/bin/env bash
# Shared dependency setup for the action and the local installer.
set -euo pipefail

LLVM_VERSION="${LLVM_VERSION:-22}"
if [[ ! "$LLVM_VERSION" =~ ^[0-9]+$ ]]; then
  echo "LLVM_VERSION must be a major version number" >&2
  exit 1
fi
: "${GITHUB_PATH:?An output file for toolchain paths is required}"

case "$(uname -s)" in
  Linux)
    privilege=""
    if [[ "$(id -u)" != 0 ]]; then privilege=sudo; fi
    run_privileged() {
      if [[ -n "$privilege" ]]; then "$privilege" "$@"; else "$@"; fi
    }

    # apt can regenerate the CA bundle even while installing prerequisites.
    # Persist already-trusted, bundle-only CAs before the first apt operation.
    # shellcheck source=scripts/preserve-extra-ca.sh
    source "$(dirname "${BASH_SOURCE[0]}")/preserve-extra-ca.sh"
    preserve_extra_ca "$privilege"

    # shellcheck source=/dev/null
    source /etc/os-release
    codename="${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}"
    if [[ ! "$codename" =~ ^[a-z][a-z0-9-]*$ ]]; then
      echo "Cannot determine the Debian/Ubuntu release codename" >&2
      exit 1
    fi
    run_privileged apt-get update
    run_privileged apt-get install -y ca-certificates curl

    # Scope the signing key to this repository; apt-key grants global trust.
    key_file="$(mktemp)"
    trap 'rm -f "$key_file"' EXIT
    curl --fail --silent --show-error --location \
      https://apt.llvm.org/llvm-snapshot.gpg.key -o "$key_file"
    run_privileged install -d -m 0755 /etc/apt/keyrings
    run_privileged install -m 0644 "$key_file" /etc/apt/keyrings/setup-llgo-llvm.asc
    printf 'deb [signed-by=/etc/apt/keyrings/setup-llgo-llvm.asc] https://apt.llvm.org/%s/ llvm-toolchain-%s-%s main\n' \
      "$codename" "$codename" "$LLVM_VERSION" |
      run_privileged tee /etc/apt/sources.list.d/setup-llgo-llvm.list >/dev/null
    run_privileged apt-get update
    run_privileged apt-get install -y \
      "llvm-$LLVM_VERSION-dev" "clang-$LLVM_VERSION" "libclang-$LLVM_VERSION-dev" \
      "lld-$LLVM_VERSION" "libunwind-$LLVM_VERSION-dev" "libc++-$LLVM_VERSION-dev" \
      build-essential cmake git pkg-config libgc-dev libssl-dev zlib1g-dev libffi-dev libuv1-dev
    printf '/usr/lib/llvm-%s/bin\n' "$LLVM_VERSION" >> "$GITHUB_PATH"
    ;;
  Darwin)
    export HOMEBREW_NO_AUTO_UPDATE=1
    export HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK=1
    # Preserve runner-image formulae on Intel, where newer bottles may be absent.
    if [[ "$(uname -m)" == arm64 ]]; then brew update; fi
    brew_install_missing() {
      local formula
      local missing=()
      for formula in "$@"; do
        if ! brew list --versions "$formula" >/dev/null; then
          missing+=("$formula")
        fi
      done
      if (( ${#missing[@]} > 0 )); then brew install "${missing[@]}"; fi
    }
    llvm_formula="llvm@$LLVM_VERSION"
    lld_formula="lld@$LLVM_VERSION"
    while IFS= read -r formula; do
      case "$formula" in
        llvm|llvm@*|lld|lld@*)
          if [[ "$formula" != "$llvm_formula" && "$formula" != "$lld_formula" ]]; then
            brew unlink "$formula" || true
          fi
          ;;
      esac
    done < <(brew list --formula)
    brew_install_missing "$llvm_formula" "$lld_formula" bdw-gc openssl libffi libuv pkg-config
    brew link --force --overwrite "$llvm_formula" "$lld_formula"
    brew link --overwrite libffi
    llvm_bin="$(brew --prefix "$llvm_formula")/bin"
    lld_bin="$(brew --prefix "$lld_formula")/bin"
    printf '%s\n' "$llvm_bin" "$lld_bin" >> "$GITHUB_PATH"
    brew list --versions "$llvm_formula" "$lld_formula"
    test "$("$llvm_bin/clang" -dumpversion | cut -d. -f1)" = "$LLVM_VERSION"
    "$lld_bin/ld.lld" --version | grep -Eq "(^|[[:space:]])$LLVM_VERSION\."
    ;;
  *)
    echo "Dependency installation supports Debian/Ubuntu and macOS" >&2
    exit 1
    ;;
esac
