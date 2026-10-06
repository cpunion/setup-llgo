#!/usr/bin/env bash
# Install LLGo on Linux/macOS with the same resolver, builder and dependencies as
# the action. Requires Node.js 20+ and an existing Go 1.21+ launcher.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
case "$(uname -s)" in
  Linux|Darwin) ;;
  *) echo 'The standalone installer supports Linux and macOS.' >&2; exit 1 ;;
esac
command -v node >/dev/null || { echo 'Node.js 20+ is required.' >&2; exit 1; }
node -e 'if (Number(process.versions.node.split(".")[0]) < 20) process.exit(1)' || {
  echo 'Node.js 20+ is required.' >&2; exit 1;
}
command -v go >/dev/null || { echo 'An existing Go 1.21+ launcher is required.' >&2; exit 1; }

go_version="${GO_VERSION:-}"
if [[ -z "$go_version" && -f go.mod ]]; then
  go_version="$(awk '/^go[[:space:]]/ { print $2; exit }' go.mod)"
fi
go_version="${go_version:-1.27.0}"
if [[ ! "$go_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "GO_VERSION must be an exact version such as 1.27.0: $go_version" >&2
  exit 1
fi
launcher_version="$(env -u GOEXPERIMENT -u GOROOT GOTOOLCHAIN=local GOWORK=off go env GOVERSION)"
if [[ ! "$launcher_version" =~ ^go([0-9]+)\.([0-9]+)(\.|$) ]] ||
   (( BASH_REMATCH[1] < 1 || (BASH_REMATCH[1] == 1 && BASH_REMATCH[2] < 21) )); then
  echo "An existing Go 1.21+ launcher is required; found $launcher_version." >&2
  exit 1
fi

echo "Selecting Go $go_version through the Go module proxy"
go_root="$(env -u GOEXPERIMENT -u GOROOT GOTOOLCHAIN="go$go_version" GOWORK=off go env GOROOT)"
[[ -x "$go_root/bin/go" ]] || { echo "Go toolchain is missing: $go_root/bin/go" >&2; exit 1; }
export PATH="$go_root/bin:$PATH" GOROOT="$go_root" GOTOOLCHAIN=local
actual_go="$(env -u GOEXPERIMENT GOWORK=off go env GOVERSION)"
[[ "$actual_go" == "go$go_version" ]] || {
  echo "Expected go$go_version on PATH, found $actual_go." >&2; exit 1;
}

install_root="${LLGO_INSTALL_ROOT:-$HOME/.cache/setup-llgo}"
mkdir -p "$install_root"
install_root="$(cd "$install_root" && pwd)"
state_dir="$(mktemp -d "$install_root/.state.XXXXXX")"
trap 'rm -rf "$state_dir"' EXIT
original_github_env="${GITHUB_ENV:-}"
original_github_path="${GITHUB_PATH:-}"
export GITHUB_OUTPUT="$state_dir/output" GITHUB_ENV="$state_dir/env" GITHUB_PATH="$state_dir/path"
touch "$GITHUB_OUTPUT" "$GITHUB_ENV" "$GITHUB_PATH"
export RUNNER_TEMP="$install_root"

case "${INSTALL_DEPENDENCIES:-true}" in
  true) LLVM_VERSION="${LLVM_VERSION:-22}" bash "$script_dir/install-dependencies.sh" ;;
  false) ;;
  *) echo 'INSTALL_DEPENDENCIES must be true or false.' >&2; exit 1 ;;
esac
while IFS= read -r entry; do
  [[ -z "$entry" ]] || export PATH="$entry:$PATH"
done < "$GITHUB_PATH"

env "INPUT_LLGO-VERSION=${LLGO_VERSION:-latest}" \
  "INPUT_INSTALL-METHOD=${INSTALL_METHOD:-auto}" \
  "INPUT_TOKEN=${GH_TOKEN:-${GITHUB_TOKEN:-}}" \
  SETUP_LLGO_PHASE=prepare SETUP_LLGO_RESULT="$state_dir/result.json" \
  node "$script_dir/../dist/index.js"
read_result() {
  node -e '
    const result = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    const value = result[process.argv[2]];
    if (typeof value !== "string" || !value || /[\r\n]/.test(value))
      throw new Error("Invalid installer result: " + process.argv[2]);
    process.stdout.write(value);
  ' "$state_dir/result.json" "$1"
}
install_dir="$(read_result directory)"
method="$(read_result method)"
ref="$(read_result ref)"
case "$install_dir" in
  "$install_root"/setup-llgo-*) ;;
  *) echo "Unexpected LLGo installation directory: $install_dir" >&2; exit 1 ;;
esac
env -u GOEXPERIMENT GOWORK=off SETUP_LLGO_PHASE=install SETUP_LLGO_SOURCE="$install_dir" \
  SETUP_LLGO_METHOD="$method" SETUP_LLGO_REF="$ref" \
  node "$script_dir/../dist/index.js"

export LLGO_ROOT="$install_dir"
activation="$install_dir/env.sh"
{
  printf 'export GOROOT=%q\n' "$go_root"
  printf 'export GOTOOLCHAIN=local\n'
  printf 'export LLGO_ROOT=%q\n' "$install_dir"
  # Expand PATH when the activation file is sourced, not while writing it.
  # shellcheck disable=SC2016
  printf 'export PATH=%q:"$PATH"\n' "$go_root/bin"
  while IFS= read -r entry; do
    # shellcheck disable=SC2016
    [[ -z "$entry" ]] || printf 'export PATH=%q:"$PATH"\n' "$entry"
  done < "$GITHUB_PATH"
} > "$activation"
if [[ -n "$original_github_env" ]]; then
  cat "$GITHUB_ENV" >> "$original_github_env"
  printf 'GOROOT=%s\nGOTOOLCHAIN=local\n' "$go_root" >> "$original_github_env"
fi
if [[ -n "$original_github_path" ]]; then
  printf '%s\n' "$go_root/bin" >> "$original_github_path"
  cat "$GITHUB_PATH" >> "$original_github_path"
fi
printf '\nLLGo installed. Activate it in your shell:\n  source %q\n' "$activation"
