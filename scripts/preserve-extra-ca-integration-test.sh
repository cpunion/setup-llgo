#!/usr/bin/env bash

set -euo pipefail

# HTTPS fixture adapted from goplus/llcppg PR #940, commit
# 1801047609c67eada9ed19bcc30d3349744b1971 (.github/scripts/test-preserve-extra-ca.sh).
# Run on Linux with ca-certificates, OpenSSL, Python 3, curl, and Git installed.
# Every update-ca-certificates path points into a disposable fixture; no sudo needed.

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[ "$(uname -s)" = Linux ] || fail "This integration test requires Linux"
for command_name in update-ca-certificates openssl python3 curl git sha256sum; do
  command -v "$command_name" >/dev/null || fail "This integration test requires $command_name"
done

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/preserve-extra-ca.sh
source "$script_dir/preserve-extra-ca.sh"

system_bundle=/etc/ssl/certs/ca-certificates.crt
[ -f "$system_bundle" ] || fail "The system CA bundle is missing"
system_bundle_before="$(sha256sum "$system_bundle")"
work_dir="$(mktemp -d /tmp/setup-llgo-ca-integration.XXXXXX)"
server_pid=

cleanup() {
  local status=$?
  if [ -n "$server_pid" ]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  if [ "$(sha256sum "$system_bundle")" != "$system_bundle_before" ]; then
    echo "FAIL: The real system CA bundle changed" >&2
    status=1
  fi
  rm -rf "$work_dir"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

make_root() {
  local name="$1"
  openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 1 \
    -subj "/CN=setup-llgo integration $name" \
    -addext 'basicConstraints=critical,CA:TRUE' \
    -addext 'keyUsage=critical,keyCertSign,cRLSign' \
    -keyout "$work_dir/$name.key" -out "$work_dir/$name.crt" >/dev/null 2>&1
}

make_root distribution
make_root extra
extra_fingerprint="$(openssl x509 -in "$work_dir/extra.crt" -outform DER | sha256sum)"
extra_fingerprint="${extra_fingerprint%% *}"
extra_fingerprint="$(printf '%s' "$extra_fingerprint" | tr '[:lower:]' '[:upper:]')"
extra_filename="setup-llgo-extra-ca-$extra_fingerprint.crt"

mkdir "$work_dir/server" "$work_dir/empty-ca"
openssl req -new -newkey rsa:2048 -nodes -subj /CN=127.0.0.1 \
  -keyout "$work_dir/server.key" -out "$work_dir/server.csr" >/dev/null 2>&1
printf '%s\n' 'subjectAltName=IP:127.0.0.1' 'basicConstraints=critical,CA:FALSE' \
  'keyUsage=critical,digitalSignature,keyEncipherment' 'extendedKeyUsage=serverAuth' \
  > "$work_dir/server.ext"
openssl x509 -req -sha256 -days 1 -in "$work_dir/server.csr" \
  -CA "$work_dir/extra.crt" -CAkey "$work_dir/extra.key" -set_serial 1 \
  -extfile "$work_dir/server.ext" -out "$work_dir/server.crt" >/dev/null 2>&1

# Ignore ambient Git settings, including options that disable TLS verification.
fixture_git() (
  # A read-only checkout mount can contain a .git file pointing outside the
  # container. Keep Git's repository discovery inside the disposable fixture.
  cd "$work_dir"
  env -i PATH="$PATH" LC_ALL=C GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
    GIT_AUTHOR_NAME='CA integration test' GIT_AUTHOR_EMAIL=ca-test@example.invalid \
    GIT_COMMITTER_NAME='CA integration test' GIT_COMMITTER_EMAIL=ca-test@example.invalid \
    git "$@"
)

fixture_git -c init.defaultBranch=main init --bare "$work_dir/server/repo.git" >/dev/null
empty_tree="$(fixture_git --git-dir="$work_dir/server/repo.git" mktree </dev/null)"
fixture_commit="$(fixture_git --git-dir="$work_dir/server/repo.git" commit-tree "$empty_tree" -m 'CA fixture')"
fixture_git --git-dir="$work_dir/server/repo.git" update-ref refs/heads/main "$fixture_commit"
fixture_git --git-dir="$work_dir/server/repo.git" update-server-info

python3 - "$work_dir/server" "$work_dir/server.crt" "$work_dir/server.key" "$work_dir/port" \
  > "$work_dir/server.log" 2>&1 <<'PY' &
import functools
import http.server
import pathlib
import ssl
import sys

directory, certificate, private_key, port_file = sys.argv[1:]
handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=directory)
server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain(certificate, private_key)
server.socket = context.wrap_socket(server.socket, server_side=True)
pathlib.Path(port_file).write_text(str(server.server_port))
server.serve_forever()
PY
server_pid=$!
attempts=0
while [ ! -s "$work_dir/port" ]; do
  kill -0 "$server_pid" 2>/dev/null || fail "The HTTPS fixture exited: $(cat "$work_dir/server.log")"
  attempts=$((attempts + 1))
  [ "$attempts" -lt 100 ] || fail "The HTTPS fixture did not start"
  sleep 0.1
done
https_url="https://127.0.0.1:$(cat "$work_dir/port")/repo.git"

new_case() {
  case_dir="$work_dir/$1"
  system_dir="$case_dir/system"
  local_dir="$case_dir/local"
  bundle="$case_dir/etc/fixture-bundle.crt"
  mkdir -p "$system_dir" "$local_dir" "$case_dir/etc" "$case_dir/hooks"
  cp "$work_dir/distribution.crt" "$system_dir/distribution.crt"
  printf 'distribution.crt\n' > "$case_dir/ca-certificates.conf"
}

rebuild_bundle() {
  if ! update-ca-certificates --fresh \
    --certsdir "$system_dir" --localcertsdir "$local_dir" \
    --etccertsdir "$case_dir/etc" --certbundle fixture-bundle.crt \
    --certsconf "$case_dir/ca-certificates.conf" --hooksdir "$case_dir/hooks" \
    > "$case_dir/update.log" 2>&1; then
    fail "Fixture bundle regeneration failed: $(cat "$case_dir/update.log")"
  fi
}

check_curl() {
  env -i PATH="$PATH" LC_ALL=C curl --disable --noproxy '*' --max-time 10 \
    --fail --silent --show-error --cacert "$bundle" --capath "$work_dir/empty-ca" \
    "$https_url/HEAD"
}

check_git() {
  fixture_git -c http.sslVerify=true -c http.sslCAInfo="$bundle" \
    -c http.sslCAPath="$work_dir/empty-ca" -c http.proxy= \
    -c http.lowSpeedTime=5 -c http.lowSpeedLimit=1 ls-remote "$https_url" refs/heads/main
}

assert_https_success() {
  check_curl > "$case_dir/curl.out"
  grep -Fxq 'ref: refs/heads/main' "$case_dir/curl.out" || fail "Unexpected HTTPS response"
  check_git > "$case_dir/git.out"
  printf '%s\trefs/heads/main\n' "$fixture_commit" > "$case_dir/expected-git.out"
  cmp "$case_dir/expected-git.out" "$case_dir/git.out" || fail "Unexpected Git HTTPS refs"
}

assert_tls_failure() {
  local curl_status=0
  check_curl > "$case_dir/curl-error.out" 2>&1 || curl_status=$?
  [ "$curl_status" -eq 60 ] || fail "Expected curl certificate error 60, got $curl_status"
  if check_git > "$case_dir/git-error.out" 2>&1; then
    fail "Git unexpectedly trusted the removed CA"
  fi
  grep -Eiq 'certificate.*(verif|issuer|trust)|SSL peer certificate' "$case_dir/git-error.out" ||
    fail "Git failed for a reason other than certificate verification: $(cat "$case_dir/git-error.out")"
}

new_case bundle-only
cat "$work_dir/distribution.crt" "$work_dir/extra.crt" > "$bundle"
cp "$bundle" "$case_dir/original.crt"
assert_https_success
rebuild_bundle
assert_tls_failure
echo 'PASS: Real bundle regeneration drops a bundle-only CA and breaks curl/Git TLS'

cp "$case_dir/original.crt" "$bundle"
preserve_extra_ca '' "$bundle" "$system_dir" "$local_dir"
[ -f "$local_dir/$extra_filename" ] || fail "The extra CA was not registered by SHA-256 fingerprint"
cmp "$bundle" "$case_dir/original.crt" || fail "Preservation modified the original bundle"
rebuild_bundle
assert_https_success
echo 'PASS: Preservation keeps real curl/Git HTTPS working after bundle regeneration'

new_case managed-symlink-directory
mkdir "$case_dir/managed"
cp "$work_dir/extra.crt" "$case_dir/managed/company-root.crt"
ln -s "$case_dir/managed" "$local_dir/company"
rebuild_bundle
assert_https_success
preserve_extra_ca '' "$bundle" "$system_dir" "$local_dir"
[ ! -e "$local_dir/$extra_filename" ] || fail "A symlink-managed CA was frozen as an extra source"
rm "$local_dir/company"
rebuild_bundle
assert_tls_failure
echo 'PASS: Removing a managed symlink directory removes its CA trust after preservation'

[ "$(sha256sum "$system_bundle")" = "$system_bundle_before" ] || fail "The system CA bundle changed"
echo 'PASS: The real system CA bundle checksum is unchanged'
