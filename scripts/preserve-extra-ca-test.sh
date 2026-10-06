#!/usr/bin/env bash
# Unit regressions use temporary certificates and never change system trust.
# Adapted from goplus/llcppg PR #940's test at 1801047609c67eada9ed19bcc30d3349744b1971.
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
helper="$script_dir/preserve-extra-ca.sh"
# shellcheck source=scripts/preserve-extra-ca.sh
source "$helper"

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/setup-llgo-ca-test.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT
passed=0

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

pass() {
  passed=$((passed + 1))
  printf 'PASS: %s\n' "$1"
}

make_certificate() {
  local name="$1"
  local constraint="$2"
  # The leaf's misleading subject must not satisfy the Basic Constraints test.
  printf '[req]\ndistinguished_name=subject\nx509_extensions=extensions\nprompt=no\n[subject]\nCN=%s\n[extensions]\nbasicConstraints=critical,CA:%s\n' \
    "${3:-$name}" "$constraint" > "$work_dir/$name.conf"
  openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 1 \
    -config "$work_dir/$name.conf" -keyout "$work_dir/$name.key" \
    -out "$work_dir/$name.crt" >/dev/null 2>&1
}

make_certificate distribution TRUE
make_certificate extra-one TRUE
make_certificate extra-two TRUE
make_certificate leaf FALSE 'CA:TRUE'

new_case() {
  case_dir="$work_dir/$1"
  system_dir="$case_dir/system sources"
  local_dir="$case_dir/local sources"
  bundle="$case_dir/trust bundle.crt"
  mkdir -p "$system_dir" "$local_dir"
  cp "$work_dir/distribution.crt" "$system_dir/distribution.crt"
  cp "$work_dir/distribution.crt" "$bundle"
}

run_preservation() {
  # Expanded by the child shell, not by this test process.
  # shellcheck disable=SC2016
  "$BASH" -c 'source "$1"; shift; preserve_extra_ca "$@"' \
    bash "$helper" "${1:-}" "$bundle" "$system_dir" "$local_dir"
}

local_certificate_count() {
  find "$local_dir" -type f -name '*.crt' | wc -l | tr -d ' '
}

assert_preserved() {
  local fingerprint
  fingerprint="$(ca_certificate_fingerprint "$work_dir/$1.crt")"
  [ -f "$local_dir/setup-llgo-extra-ca-$fingerprint.crt" ] || fail "$1 was not preserved"
  cmp "$work_dir/$1.crt" "$local_dir/setup-llgo-extra-ca-$fingerprint.crt" || fail "$1 changed"
}

new_case no-extra
run_preservation
[ "$(local_certificate_count)" -eq 0 ] || fail 'Managed certificates were duplicated'
pass 'Managed certificates leave local sources unchanged'

new_case missing-bundle
rm "$bundle"
run_preservation
touch "$bundle"
run_preservation
[ "$(local_certificate_count)" -eq 0 ] || fail 'Absent or empty bundle created certificates'
pass 'Absent and empty bundles allow initial package installation'

new_case extras
cat "$work_dir/extra-one.crt" "$work_dir/extra-two.crt" >> "$bundle"
cp "$bundle" "$case_dir/original.crt"
run_preservation
[ "$(local_certificate_count)" -eq 2 ] || fail 'Expected two extra CA certificates'
assert_preserved extra-one
assert_preserved extra-two
cmp "$bundle" "$case_dir/original.crt" || fail 'The original bundle changed'
run_preservation > "$case_dir/repeated-output"
[ "$(local_certificate_count)" -eq 2 ] || fail 'Repeated preservation created duplicates'
[ ! -s "$case_dir/repeated-output" ] || fail 'Registered certificates were preserved again'
pass 'Preservation is provider independent, idempotent, and leaves the bundle intact'

new_case duplicate-extra
cat "$work_dir/extra-one.crt" "$work_dir/extra-one.crt" >> "$bundle"
run_preservation
[ "$(local_certificate_count)" -eq 1 ] || fail 'Duplicate PEM entries created multiple sources'
pass 'Repeated bundle entries are deduplicated by SHA-256 fingerprint'

new_case registered-local
cp "$work_dir/extra-one.crt" "$local_dir/company-root.crt"
cat "$work_dir/extra-one.crt" >> "$bundle"
run_preservation
[ "$(local_certificate_count)" -eq 1 ] || fail 'An existing local CA was duplicated'
cmp "$local_dir/company-root.crt" "$work_dir/extra-one.crt" || fail 'An existing CA changed'
pass 'Existing local sources are retained without duplication'

new_case multiple-managed
cat "$work_dir/extra-one.crt" "$work_dir/extra-two.crt" > "$system_dir/multiple.crt"
cat "$work_dir/extra-one.crt" "$work_dir/extra-two.crt" >> "$bundle"
run_preservation
[ "$(local_certificate_count)" -eq 0 ] || fail 'Multi-certificate sources were not recognized'
pass 'All certificates in a managed source are recognized'

new_case symlink-file
ln -s "$work_dir/extra-one.crt" "$system_dir/linked-root.crt"
cat "$work_dir/extra-one.crt" >> "$bundle"
run_preservation
[ "$(local_certificate_count)" -eq 0 ] || fail 'A managed file symlink was not recognized'
pass 'Managed certificate file symlinks are recognized'

new_case symlink-directory
mkdir "$case_dir/external sources"
cp "$work_dir/extra-one.crt" "$case_dir/external sources/company.crt"
ln -s "$case_dir/external sources" "$local_dir/linked directory.crt"
cat "$work_dir/extra-one.crt" >> "$bundle"
run_preservation
[ "$(local_certificate_count)" -eq 0 ] || fail 'A linked directory caused a duplicate CA'
pass 'Linked directories, including ones named .crt, match updater traversal'

new_case dangling-links
ln -s "$case_dir/missing.crt" "$local_dir/dangling.crt"
ln -s "$case_dir/missing-directory" "$system_dir/dangling-directory.crt"
cat "$work_dir/extra-one.crt" >> "$bundle"
run_preservation
[ "$(local_certificate_count)" -eq 1 ] || fail 'Dangling links interfered with preservation'
assert_preserved extra-one
pass 'Dangling certificate links are ignored as they are by the updater'

new_case symlink-root
mv "$local_dir" "$case_dir/real local directory"
ln -s "$case_dir/real local directory" "$local_dir"
cp "$work_dir/extra-one.crt" "$local_dir/company.crt"
cat "$work_dir/extra-one.crt" >> "$bundle"
run_preservation
[ "$(find -L "$local_dir" -type f -name '*.crt' | wc -l | tr -d ' ')" -eq 1 ] || fail 'A linked source root was missed'
pass 'Source root directories may themselves be symlinks'

new_case disabled-system
cp "$work_dir/extra-one.crt" "$system_dir/disabled.crt"
printf 'distribution.crt\n!disabled.crt\n' > "$case_dir/ca-certificates.conf"
cat "$work_dir/extra-one.crt" >> "$bundle"
run_preservation
[ "$(local_certificate_count)" -eq 0 ] || fail 'A disabled root was promoted to local trust'
pass 'Disabled distribution roots are not promoted to local sources'

new_case missing-source-directories
rm "$system_dir/distribution.crt"
rmdir "$system_dir" "$local_dir"
cp "$work_dir/extra-one.crt" "$bundle"
run_preservation
[ "$(local_certificate_count)" -eq 1 ] || fail 'Missing directories prevented preservation'
pass 'An injected bundle can be preserved before CA package installation'

for invalid_case in incomplete nested unexpected-end invalid-x509 invalid-source non-ca; do
  new_case "$invalid_case"
  # Stage a valid extra first: no certificate may be installed before all pass.
  cat "$work_dir/extra-one.crt" >> "$bundle"
  case "$invalid_case" in
    incomplete) printf '\n-----BEGIN CERTIFICATE-----\ninvalid\n' >> "$bundle" ;;
    nested) printf '\n-----BEGIN CERTIFICATE-----\n-----BEGIN CERTIFICATE-----\n' >> "$bundle" ;;
    unexpected-end) printf '\n-----END CERTIFICATE-----\n' >> "$bundle" ;;
    invalid-x509) printf '\n-----BEGIN CERTIFICATE-----\ninvalid\n-----END CERTIFICATE-----\n' >> "$bundle" ;;
    invalid-source) printf 'not a certificate\n' > "$system_dir/broken.crt" ;;
    non-ca) cat "$work_dir/leaf.crt" >> "$bundle" ;;
  esac
  # Exercise a conditional directly: relying on set -e would accept failures here.
  if preserve_extra_ca '' "$bundle" "$system_dir" "$local_dir" > "$case_dir/output" 2>&1; then
    fail "$invalid_case input was accepted"
  fi
  [ "$(local_certificate_count)" -eq 0 ] || fail "$invalid_case partially modified trust"
  pass "$invalid_case fails before any certificate is installed"
done

new_case no-openssl
mkdir "$case_dir/empty-bin"
# shellcheck disable=SC2016
if PATH="$case_dir/empty-bin" "$BASH" -c 'source "$1"; shift; preserve_extra_ca "$@"' \
  bash "$helper" '' "$bundle" "$system_dir" "$local_dir" > "$case_dir/output" 2>&1; then
  fail 'A nonempty bundle was ignored without OpenSSL'
fi
grep -q 'OpenSSL is required' "$case_dir/output" || fail 'Missing OpenSSL diagnostic'
pass 'Missing OpenSSL fails before dependency installation'

new_case privilege-wrapper
# The wrapper expands these variables when invoked.
# shellcheck disable=SC2016
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$1" >> "$CA_TEST_LOG"\nexec "$@"\n' > "$case_dir/privilege wrapper"
chmod +x "$case_dir/privilege wrapper"
cat "$work_dir/extra-one.crt" >> "$bundle"
CA_TEST_LOG="$case_dir/wrapper-log" run_preservation "$case_dir/privilege wrapper"
printf 'mkdir\ninstall\n' > "$case_dir/expected-log"
cmp "$case_dir/wrapper-log" "$case_dir/expected-log" || fail 'Writes did not use the privilege wrapper'
assert_preserved extra-one
pass 'Privileged writes use the single executable wrapper, even with spaces in its path'

new_case failed-write
printf '#!/usr/bin/env bash\nexit 17\n' > "$case_dir/reject-write"
chmod +x "$case_dir/reject-write"
cat "$work_dir/extra-one.crt" >> "$bundle"
if preserve_extra_ca "$case_dir/reject-write" "$bundle" "$system_dir" "$local_dir" > "$case_dir/output" 2>&1; then
  fail 'Failed privileged writes were reported as successful'
fi
[ "$(local_certificate_count)" -eq 0 ] || fail 'Failed writes modified local trust'
pass 'Privileged write failures propagate to callers'

printf '\nAll %s CA preservation checks passed.\n' "$passed"
