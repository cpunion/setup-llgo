#!/usr/bin/env bash
# Exercise package selection and CA ordering without network or host writes.
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/setup-llgo-dependencies-test.XXXXXX")"
trap 'rm -rf "$test_root"' EXIT
export DEPENDENCY_TEST_ROOT="$test_root"
export DEPENDENCY_TEST_LOG="$test_root/commands"
mkdir -p "$test_root/scripts" "$test_root/bin" "$test_root/llvm/bin" "$test_root/lld/bin"
cp "$script_dir/install-dependencies.sh" "$test_root/scripts/install-dependencies.sh"

cat > "$test_root/scripts/preserve-extra-ca.sh" <<'FIXTURE'
preserve_extra_ca() {
  printf 'preserve:%s\n' "$*" >> "$DEPENDENCY_TEST_LOG"
  return "${MOCK_CA_STATUS:-0}"
}
FIXTURE

cat > "$test_root/bin/mock-command" <<'FIXTURE'
#!/usr/bin/env bash
set -euo pipefail
name="${0##*/}"
printf '%s:%s\n' "$name" "$*" >> "$DEPENDENCY_TEST_LOG"
case "$name" in
  uname)
    case "$1" in
      -s) printf '%s\n' "$MOCK_OS" ;;
      -m) printf '%s\n' "${MOCK_ARCH:-x86_64}" ;;
      *) exit 91 ;;
    esac ;;
  id) printf '%s\n' "${MOCK_UID:-0}" ;;
  sudo) exec "$@" ;;
  apt-get|curl|install) ;;
  tee)
    # Consume repository configuration without writing the supplied /etc path.
    cat > "$DEPENDENCY_TEST_ROOT/repository-line"
    ;;
  brew)
    case "$1" in
      update|unlink|install|link) ;;
      --prefix)
        case "$2" in
          llvm@22) printf '%s/llvm\n' "$DEPENDENCY_TEST_ROOT" ;;
          lld@22) printf '%s/lld\n' "$DEPENDENCY_TEST_ROOT" ;;
          *) exit 92 ;;
        esac ;;
      list)
        case "$2" in
          --formula) printf 'llvm@21\nllvm@22\nlld@21\nlld@22\nopenssl\n' ;;
          --versions)
            if [[ "$#" == 3 && "${MOCK_BREW_MISSING:-false}" == true ]]; then
              case "$3" in llvm@22|libffi) exit 1 ;; esac
            fi ;;
          *) exit 93 ;;
        esac ;;
      *) exit 94 ;;
    esac ;;
  clang) printf '22.1.8\n' ;;
  ld.lld) printf 'LLD 22.1.8\n' ;;
  *) exit 95 ;;
esac
FIXTURE
chmod +x "$test_root/bin/mock-command"
for command_name in uname id sudo apt-get curl install tee brew; do
  ln -s mock-command "$test_root/bin/$command_name"
done
ln -s "$test_root/bin/mock-command" "$test_root/llvm/bin/clang"
ln -s "$test_root/bin/mock-command" "$test_root/lld/bin/ld.lld"

# Only the distribution metadata source is intercepted; every other source,
# including the copy of the real installer, still runs normally.
source() {
  if [[ "$1" == /etc/os-release ]]; then
    # Read by the installer after sourcing the mocked distribution metadata.
    # shellcheck disable=SC2034
    VERSION_CODENAME="${MOCK_CODENAME:-bookworm}"
  else
    builtin source "$@"
  fi
}
export -f source

fail() {
  echo "FAIL: $*" >&2
  if [[ -f "$test_root/output" ]]; then cat "$test_root/output" >&2; fi
  exit 1
}

run_dependencies() {
  : > "$DEPENDENCY_TEST_LOG"
  : > "$test_root/path"
  env PATH="$test_root/bin:$PATH" GITHUB_PATH="$test_root/path" LLVM_VERSION=22 \
    MOCK_OS=Linux MOCK_UID=0 MOCK_CA_STATUS=0 MOCK_BREW_MISSING=false "$@" \
    "$BASH" "$test_root/scripts/install-dependencies.sh" > "$test_root/output" 2>&1
}

run_dependencies || fail 'Linux root dependency installation failed'
first_operation="$(awk '/^preserve:|^apt-get:/ { print; exit }' "$DEPENDENCY_TEST_LOG")"
[[ "$first_operation" == preserve: ]] || fail 'An apt operation preceded CA preservation'
grep -Fxq 'apt-get:install -y ca-certificates curl' "$DEPENDENCY_TEST_LOG" || fail 'Missing HTTPS prerequisites'
for package in llvm-22-dev clang-22 libclang-22-dev lld-22 libunwind-22-dev libc++-22-dev \
  build-essential cmake git pkg-config libgc-dev libssl-dev zlib1g-dev libffi-dev libuv1-dev; do
  grep '^apt-get:install ' "$DEPENDENCY_TEST_LOG" | grep -Fq " $package" || fail "Missing package: $package"
done
grep -Fxq '/usr/lib/llvm-22/bin' "$test_root/path" || fail 'LLVM path was not exported'
grep -Fxq 'deb [signed-by=/etc/apt/keyrings/setup-llgo-llvm.asc] https://apt.llvm.org/bookworm/ llvm-toolchain-bookworm-22 main' \
  "$test_root/repository-line" || fail 'LLVM repository key was not scoped'
echo 'PASS: Linux preserves CA before apt and installs the complete dependency set'

run_dependencies MOCK_UID=1000 || fail 'Unprivileged Linux setup failed'
grep -Fxq 'preserve:sudo' "$DEPENDENCY_TEST_LOG" || fail 'CA preservation did not receive sudo'
for privileged_command in 'apt-get update' 'install -d -m 0755 /etc/apt/keyrings' \
  'tee /etc/apt/sources.list.d/setup-llgo-llvm.list'; do
  grep -Fxq "sudo:$privileged_command" "$DEPENDENCY_TEST_LOG" || fail "Missing sudo for $privileged_command"
done
echo 'PASS: Unprivileged Linux writes use sudo'

if run_dependencies MOCK_CA_STATUS=77; then fail 'CA preservation failure was ignored'; fi
if grep -Eq '^(apt-get|curl|install|tee):' "$DEPENDENCY_TEST_LOG"; then
  fail 'Package operations ran after CA preservation failed'
fi
echo 'PASS: CA validation failure stops before network or privileged package operations'

if run_dependencies LLVM_VERSION='22;false'; then fail 'Invalid LLVM version was accepted'; fi
[[ ! -s "$DEPENDENCY_TEST_LOG" ]] || fail 'Invalid LLVM version executed commands'
echo 'PASS: Invalid LLVM versions fail before running commands'

for arch in x86_64 arm64; do
  run_dependencies MOCK_OS=Darwin MOCK_ARCH="$arch" MOCK_BREW_MISSING=true || fail "macOS $arch setup failed"
  if grep -Eq '^(preserve|apt-get|sudo):' "$DEPENDENCY_TEST_LOG"; then fail 'macOS ran Linux setup'; fi
  if [[ "$arch" == arm64 ]]; then
    grep -Fxq 'brew:update' "$DEPENDENCY_TEST_LOG" || fail 'Apple Silicon skipped metadata refresh'
  elif grep -Fxq 'brew:update' "$DEPENDENCY_TEST_LOG"; then
    fail 'Intel unexpectedly refreshed Homebrew metadata'
  fi
  grep -Fxq 'brew:install llvm@22 libffi' "$DEPENDENCY_TEST_LOG" || fail 'Homebrew installed already-present formulae'
  for formula in llvm@22 lld@22 bdw-gc openssl libffi libuv pkg-config; do
    grep -Fxq "brew:list --versions $formula" "$DEPENDENCY_TEST_LOG" || fail "Missing formula: $formula"
  done
  grep -Fxq 'brew:unlink llvm@21' "$DEPENDENCY_TEST_LOG" || fail 'Old LLVM was not unlinked'
  grep -Fxq 'brew:unlink lld@21' "$DEPENDENCY_TEST_LOG" || fail 'Old LLD was not unlinked'
  if grep -Eq '^brew:unlink (llvm|lld)@22$' "$DEPENDENCY_TEST_LOG"; then fail 'Selected LLVM was unlinked'; fi
  grep -Fxq "$test_root/llvm/bin" "$test_root/path" || fail 'macOS LLVM path missing'
  grep -Fxq "$test_root/lld/bin" "$test_root/path" || fail 'macOS LLD path missing'
  echo "PASS: macOS $arch installs only missing dependencies and exports selected LLVM/LLD"
done

echo 'All dependency installer checks passed.'
