#!/usr/bin/env bash
# Exercise standalone orchestration without downloads or package installation.
set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/setup-llgo-install-test.XXXXXX")"
test_root="$(cd "$test_root" && pwd)"
trap 'rm -rf "$test_root"' EXIT
TEST_REAL_NODE="$(command -v node)"
export TEST_REAL_NODE
export TEST_ROOT="$test_root" TEST_TRACE="$test_root/trace"
mkdir -p "$test_root/fixture/scripts" "$test_root/fixture/dist" "$test_root/bin" \
  "$test_root/Go toolchain/bin" "$test_root/LLVM tools" "$test_root/consumer"
cp "$script_dir/install.sh" "$test_root/fixture/scripts/install.sh"
touch "$test_root/fixture/dist/index.js" "$TEST_TRACE"

cat > "$test_root/bin/go" <<'FIXTURE'
#!/usr/bin/env bash
set -eu
[[ -z "${GOEXPERIMENT+x}" && -z "${GOROOT+x}" && "$GOWORK" == off ]]
if [[ "$GOTOOLCHAIN" == local ]]; then
  echo "${MOCK_LAUNCHER_VERSION:-go1.24.0}"
else
  printf 'download:%s\n' "$GOTOOLCHAIN" >> "$TEST_TRACE"
  [[ "${MOCK_DOWNLOAD_FAIL:-false}" != true ]] || exit 42
  printf '%s\n' "$TEST_ROOT/Go toolchain"
fi
FIXTURE
cat > "$test_root/Go toolchain/bin/go" <<'FIXTURE'
#!/usr/bin/env bash
set -eu
[[ "$GOTOOLCHAIN" == local && "$GOROOT" == "$TEST_ROOT/Go toolchain" ]]
echo "${MOCK_ACTUAL_GO_VERSION:-go1.27.0}"
FIXTURE
cat > "$test_root/bin/node" <<'FIXTURE'
#!/usr/bin/env bash
set -eu
if [[ "$1" == -e ]]; then
  if [[ "$2" == *process.versions.node* && "${MOCK_OLD_NODE:-false}" == true ]]; then exit 1; fi
  exec "$TEST_REAL_NODE" "$@"
fi
[[ -f "$GITHUB_OUTPUT" && -f "$GITHUB_ENV" && -f "$GITHUB_PATH" ]]
[[ "$GOTOOLCHAIN" == local && "$(command -v go)" == "$TEST_ROOT/Go toolchain/bin/go" ]]
case "$SETUP_LLGO_PHASE" in
  prepare)
    printf 'prepare:%s:%s\n' "$(printenv INPUT_LLGO-VERSION)" "$(printenv INPUT_INSTALL-METHOD)" >> "$TEST_TRACE"
    [[ "${MOCK_PREPARE_FAIL:-false}" != true ]] || exit 43
    destination="$(mktemp -d "$RUNNER_TEMP/setup-llgo-XXXXXX")"
    [[ "${MOCK_BAD_DIRECTORY:-false}" != true ]] || destination="$TEST_ROOT/sentinel"
    "$TEST_REAL_NODE" -e 'require("fs").writeFileSync(process.argv[1], JSON.stringify({directory: process.argv[2], method: "source", ref: "refs/heads/main", revision: "a".repeat(40)}))' "$SETUP_LLGO_RESULT" "$destination"
    ;;
  install)
    [[ "$GOWORK" == off && -z "${GOEXPERIMENT+x}" ]]
    printf 'install:%s:%s\n' "$SETUP_LLGO_METHOD" "$SETUP_LLGO_REF" >> "$TEST_TRACE"
    [[ "${MOCK_BUILD_FAIL:-false}" != true ]] || exit 44
    mkdir -p "$SETUP_LLGO_SOURCE/bin"
    printf '#!/usr/bin/env bash\necho "llgo mock"\n' > "$SETUP_LLGO_SOURCE/bin/llgo"
    chmod +x "$SETUP_LLGO_SOURCE/bin/llgo"
    printf '%s\n' "$SETUP_LLGO_SOURCE/bin" >> "$GITHUB_PATH"
    printf 'LLGO_ROOT=%s\n' "$SETUP_LLGO_SOURCE" >> "$GITHUB_ENV"
    ;;
  *) exit 45 ;;
esac
FIXTURE
cat > "$test_root/fixture/scripts/install-dependencies.sh" <<'FIXTURE'
#!/usr/bin/env bash
set -eu
printf 'dependencies:%s\n' "$LLVM_VERSION" >> "$TEST_TRACE"
printf '%s\n' "$TEST_ROOT/LLVM tools" >> "$GITHUB_PATH"
FIXTURE
chmod +x "$test_root/bin/go" "$test_root/bin/node" "$test_root/Go toolchain/bin/go"

installer="$test_root/fixture/scripts/install.sh"
install_root="$test_root/install root ' quoted"
mkdir -p "$install_root"
printf 'keep\n' > "$install_root/sentinel"
run_install() {
  env -u GITHUB_ENV -u GITHUB_PATH -u GITHUB_OUTPUT -u GO_VERSION \
    -u LLGO_VERSION -u INSTALL_METHOD -u INSTALL_DEPENDENCIES -u LLVM_VERSION \
    PATH="$test_root/bin:$PATH" LLGO_INSTALL_ROOT="$install_root" \
    GOROOT=/stale/goroot GOEXPERIMENT=dwarf5 GOWORK=/stale/go.work \
    "$@" bash "$installer" > "$test_root/output" 2>&1
}
expect_failure() {
  local expected="$1"
  shift
  if run_install "$@"; then
    echo "Expected failure: $expected" >&2
    exit 1
  fi
  grep -Fq "$expected" "$test_root/output"
}

cd "$test_root/consumer"
touch "$test_root/action-env" "$test_root/action-path"
run_install GO_VERSION=1.27.0 LLGO_VERSION=main INSTALL_METHOD=source \
  GITHUB_ENV="$test_root/action-env" GITHUB_PATH="$test_root/action-path"
grep -Fxq 'download:go1.27.0' "$TEST_TRACE"
grep -Fxq 'dependencies:22' "$TEST_TRACE"
grep -Fxq 'prepare:main:source' "$TEST_TRACE"
grep -Fxq 'install:source:refs/heads/main' "$TEST_TRACE"
installs=("$install_root"/setup-llgo-*)
[[ ${#installs[@]} == 1 && -f "${installs[0]}/env.sh" ]]
activation="${installs[0]}/env.sh"
# Expand the activation checks in the child shell after sourcing its environment.
# shellcheck disable=SC2016
env PATH="$test_root/bin:$PATH" GOROOT=/stale/goroot GOTOOLCHAIN=auto \
  bash -ec 'source "$1"; [[ "$(go env GOVERSION)" == go1.27.0 ]]; [[ "$(llgo version)" == "llgo mock" ]]; [[ "$LLGO_ROOT/env.sh" == "$1" ]]; [[ ":$PATH:" == *":$TEST_ROOT/LLVM tools:"* ]]' bash "$activation"
grep -Fxq "GOROOT=$test_root/Go toolchain" "$test_root/action-env"
grep -Fxq 'GOTOOLCHAIN=local' "$test_root/action-env"
grep -Fxq "$test_root/Go toolchain/bin" "$test_root/action-path"
grep -Fxq "${installs[0]}/bin" "$test_root/action-path"

: > "$TEST_TRACE"
run_install GO_VERSION=1.27.0 INSTALL_DEPENDENCIES=false
grep -Fxq 'prepare:latest:auto' "$TEST_TRACE"
if grep -q '^dependencies:' "$TEST_TRACE"; then
  echo 'Dependencies ran despite INSTALL_DEPENDENCIES=false.' >&2
  exit 1
fi
installs=("$install_root"/setup-llgo-*)
[[ ${#installs[@]} == 2 && -f "$activation" ]]
[[ "$(< "$install_root/sentinel")" == keep ]]

printf 'module example.test/consumer\n\ngo 1.28.1\n' > go.mod
run_install GO_VERSION= MOCK_ACTUAL_GO_VERSION=go1.28.1 INSTALL_DEPENDENCIES=false
grep -Fxq 'download:go1.28.1' "$TEST_TRACE"
run_install GO_VERSION=1.27.0 INSTALL_DEPENDENCIES=false
rm go.mod
run_install GO_VERSION= INSTALL_DEPENDENCIES=false

expect_failure 'GO_VERSION must be an exact version' GO_VERSION=1.27
expect_failure 'Go 1.21+ launcher is required' MOCK_LAUNCHER_VERSION=go1.20.0
expect_failure 'Selecting Go 1.27.0' MOCK_DOWNLOAD_FAIL=true
expect_failure 'Expected go1.27.0 on PATH, found go1.26.0.' MOCK_ACTUAL_GO_VERSION=go1.26.0
expect_failure 'Node.js 20+ is required.' MOCK_OLD_NODE=true
expect_failure 'INSTALL_DEPENDENCIES must be true or false.' INSTALL_DEPENDENCIES=invalid
expect_failure 'Selecting Go 1.27.0' MOCK_PREPARE_FAIL=true
expect_failure 'Selecting Go 1.27.0' MOCK_BUILD_FAIL=true
expect_failure 'Unexpected LLGo installation directory:' MOCK_BAD_DIRECTORY=true
[[ "$(< "$install_root/sentinel")" == keep ]]
shopt -s nullglob
state_dirs=("$install_root"/.state.*)
[[ ${#state_dirs[@]} == 0 ]]
echo 'Standalone installer checks passed.'
