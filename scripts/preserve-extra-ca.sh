#!/usr/bin/env bash
# Preserve operator-added certificates already trusted by the Debian/Ubuntu
# system bundle before apt can regenerate it. Source this file, then call:
#   preserve_extra_ca [privilege_command] [bundle] [system_sources] [local_sources]
# The privilege command is empty (run directly) or one executable, such as sudo.
# Extra CAs are registered in /usr/local/share/ca-certificates by default;
# this helper does not add trust for certificates absent from the current bundle.
# Adapted from Changjun Ji (CarlJi), goplus/llcppg PR #940,
# commit f192189cc910b6147f33803fdeda2fc90ea9f039.

split_ca_certificates() {
  local source_file="$1"
  local output_dir="$2"

  if ! awk -v output_dir="$output_dir" '
    /^-----BEGIN CERTIFICATE-----[[:space:]]*$/ {
      if (inside_certificate) exit 1
      inside_certificate = 1
      certificate_count++
      output_file = sprintf("%s/%06d.crt", output_dir, certificate_count)
    }
    inside_certificate { print > output_file }
    /^-----END CERTIFICATE-----[[:space:]]*$/ {
      if (!inside_certificate) exit 1
      close(output_file)
      inside_certificate = 0
    }
    END {
      if (inside_certificate || certificate_count == 0) exit 1
    }
  ' "$source_file"; then
    echo "Failed to parse CA certificates from $source_file" >&2
    return 1
  fi
}

ca_certificate_fingerprint() {
  local certificate_file="$1"
  local fingerprint

  if ! fingerprint="$(openssl x509 -in "$certificate_file" -noout -sha256 -fingerprint)"; then
    echo "Invalid CA certificate: $certificate_file" >&2
    return 1
  fi
  fingerprint="${fingerprint#*=}"
  printf '%s\n' "${fingerprint//:/}"
}

preserve_extra_ca() (
  set -euo pipefail
  shopt -s nullglob
  export LC_ALL=C

  local privilege_command="${1:-}"
  local bundle_file="${2:-/etc/ssl/certs/ca-certificates.crt}"
  local system_certificates_dir="${3:-/usr/share/ca-certificates}"
  local local_certificates_dir="${4:-/usr/local/share/ca-certificates}"
  local work_dir source_dir source_file certificate_file fingerprint
  local preserved_count=0

  if [ ! -s "$bundle_file" ]; then
    return 0
  fi
  if ! command -v openssl >/dev/null 2>&1; then
    echo "OpenSSL is required to preserve existing CA certificates before installing dependencies." >&2
    return 1
  fi

  # Explicit failure returns also protect callers using `if preserve_extra_ca`:
  # Bash disables errexit throughout functions called in a conditional.
  work_dir="$(mktemp -d "${TMPDIR:-/tmp}/setup-llgo-ca.XXXXXX")" || return 1
  trap 'rm -rf "$work_dir"' EXIT
  mkdir "$work_dir/bundle" "$work_dir/managed" "$work_dir/preserved" || return 1
  touch "$work_dir/managed-fingerprints" || return 1
  split_ca_certificates "$bundle_file" "$work_dir/bundle" || return 1

  for source_dir in "$system_certificates_dir" "$local_certificates_dir"; do
    if [ ! -d "$source_dir" ]; then
      continue
    fi
    # Match update-ca-certificates: follow linked directories and certificate
    # files, but ignore dangling links. Scan disabled distribution roots too,
    # so an old bundle cannot promote them into independently trusted sources.
    find -L "$source_dir" -type f -name '*.crt' -print0 > "$work_dir/source-files" || return 1
    while IFS= read -r -d '' source_file; do
      rm -f "$work_dir/managed/"*.crt || return 1
      split_ca_certificates "$source_file" "$work_dir/managed" || return 1
      for certificate_file in "$work_dir/managed/"*.crt; do
        ca_certificate_fingerprint "$certificate_file" >> "$work_dir/managed-fingerprints" || return 1
      done
    done < "$work_dir/source-files"
  done

  for certificate_file in "$work_dir/bundle/"*.crt; do
    fingerprint="$(ca_certificate_fingerprint "$certificate_file")" || return 1
    if grep -Fxq "$fingerprint" "$work_dir/managed-fingerprints"; then
      continue
    fi
    openssl x509 -in "$certificate_file" -noout -text > "$work_dir/certificate-details" || return 1
    if ! awk '
      /^[[:space:]]*X509v3 Basic Constraints:/ {
        if (getline > 0 && $0 ~ /^[[:space:]]*CA:TRUE([,[:space:]]|$)/) valid_ca = 1
      }
      END { exit !valid_ca }
    ' "$work_dir/certificate-details"; then
      echo "Cannot preserve a bundle-only certificate without CA basic constraints: $certificate_file" >&2
      return 1
    fi
    if [ ! -f "$work_dir/preserved/$fingerprint.crt" ]; then
      openssl x509 -in "$certificate_file" -out "$work_dir/preserved/$fingerprint.crt" || return 1
      preserved_count=$((preserved_count + 1))
    fi
  done

  if [ "$preserved_count" -eq 0 ]; then
    return 0
  fi
  if [ -n "$privilege_command" ]; then
    "$privilege_command" mkdir -p "$local_certificates_dir" || return 1
  else
    mkdir -p "$local_certificates_dir" || return 1
  fi
  for certificate_file in "$work_dir/preserved/"*.crt; do
    if [ -n "$privilege_command" ]; then
      "$privilege_command" install -m 0644 "$certificate_file" \
        "$local_certificates_dir/setup-llgo-extra-ca-${certificate_file##*/}" || return 1
    else
      install -m 0644 "$certificate_file" \
        "$local_certificates_dir/setup-llgo-extra-ca-${certificate_file##*/}" || return 1
    fi
  done
  printf '==> Preserved %s additional CA certificate(s) for system certificate updates\n' "$preserved_count"
)
