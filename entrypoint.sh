#!/bin/sh

set -eu

log() {
  printf '%s\n' "$*"
}

fail() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

generate_combined() {
  while [ -n "${1:-}" ] ; do
    filename="$1"
    shift

    directory="${filename%/*}/"
    fullchain="${directory}fullchain.pem"
    privkey="${directory}privkey.pem"
    combined="${directory}combined.pem"

    cat "${fullchain}" "${privkey}" > "${combined}"
    cat "${fullchain}" "${privkey}" > "/etc/letsencrypt/combined/$(basename "$directory").pem"
  done
}

kms_cmd() {
  if [ -n "${AWS_REGION:-}" ] ; then
    aws kms "$@" --region "${AWS_REGION}"
  else
    aws kms "$@"
  fi
}

ensure_kms_key_exists() {
  if [ "${AUTO_CREATE_KMS_KEY_IF_MISSING:-false}" != "true" ] ; then
    return 0
  fi

  if [ -z "${KMS_KEY_ID:-}" ] ; then
    fail "AUTO_CREATE_KMS_KEY_IF_MISSING=true but KMS_KEY_ID is not set"
  fi

  case "${KMS_KEY_ID}" in
    alias/*) : ;;
    *)
      fail "KMS_KEY_ID must be an alias (for example, alias/certbotbot) when AUTO_CREATE_KMS_KEY_IF_MISSING=true"
      ;;
  esac

  if kms_cmd describe-key --key-id "${KMS_KEY_ID}" >/dev/null 2>&1 ; then
    log "KMS key already exists for ${KMS_KEY_ID}"
    return 0
  fi

  log "KMS key ${KMS_KEY_ID} not found; creating it"

  key_id="$(kms_cmd create-key \
    --description "${KMS_KEY_DESCRIPTION:-certbotbot managed key}" \
    --key-spec SYMMETRIC_DEFAULT \
    --key-usage ENCRYPT_DECRYPT \
    --query 'KeyMetadata.KeyId' \
    --output text)"

  if kms_cmd create-alias --alias-name "${KMS_KEY_ID}" --target-key-id "${key_id}" >/dev/null 2>&1 ; then
    log "Created alias ${KMS_KEY_ID} for KMS key ${key_id}"
  else
    log "Alias creation did not succeed immediately; checking whether ${KMS_KEY_ID} now exists"
  fi

  attempts=0
  while [ "${attempts}" -lt 10 ] ; do
    if kms_cmd describe-key --key-id "${KMS_KEY_ID}" >/dev/null 2>&1 ; then
      log "KMS key is ready for ${KMS_KEY_ID}"
      return 0
    fi

    attempts=$((attempts + 1))
    sleep 2
  done

  fail "KMS key alias ${KMS_KEY_ID} was not usable after creation attempt"
}

init_defaults() {
  WORKDIR="${WORKDIR:-/etc/letsencrypt}"
  FILEBASE="${FILEBASE:-live}"
  FILEEXT="${FILEEXT:-.tar.gz}"
  FILEVERSION="${FILEVERSION:--$(date +%Y%m%d)}"
  DELETE_MODE=false
  DELETE_DOMAINS=""
  REQUESTED_DOMAINS=""
}

validate_environment() {
  BUCKET="${BUCKET:?Error: no bucket set}"
  EMAIL="${EMAIL:?Error: no email address set}"
}

parse_args() {
  while [ "$#" -gt 0 ] ; do
    case "$1" in
      --delete-domain)
        shift
        if [ -z "${1:-}" ] ; then
          fail "--delete-domain requires a domain name"
        fi
        DELETE_MODE=true
        if [ -n "${DELETE_DOMAINS}" ] ; then
          DELETE_DOMAINS="${DELETE_DOMAINS}
$1"
        else
          DELETE_DOMAINS="$1"
        fi
        ;;
      --help|-h)
        cat <<'EOF'
Usage:
  entrypoint.sh [domain ...]
  entrypoint.sh --delete-domain domain [--delete-domain domain ...]

Modes:
  No arguments:
    renew existing certificates

  Positional domains:
    issue or renew certificates for the given base domains

  --delete-domain:
    delete the certificate lineage for one or more base domains from the artifact,
    including both domain and *.domain when managed together
EOF
        exit 0
        ;;
      --*)
        fail "unknown option: $1"
        ;;
      *)
        if [ -n "${REQUESTED_DOMAINS}" ] ; then
          REQUESTED_DOMAINS="${REQUESTED_DOMAINS}
$1"
        else
          REQUESTED_DOMAINS="$1"
        fi
        ;;
    esac
    shift
  done

  if [ "${DELETE_MODE}" = "true" ] && [ -n "${REQUESTED_DOMAINS}" ] ; then
    fail "--delete-domain cannot be combined with positional domains"
  fi
}

prepare_workdir() {
  if [ ! -d "${WORKDIR}" ] ; then
    mkdir -p "${WORKDIR}"
  fi

  if [ ! -d "${WORKDIR}/combined" ] ; then
    mkdir -p "${WORKDIR}/combined"
  fi

  cd "${WORKDIR}" || exit 1
}

ensure_bucket_exists() {
  if ! aws s3 ls "${BUCKET}" >/dev/null 2>&1 ; then
    aws s3 mb "s3://${BUCKET}" >/dev/null
  fi
}

download_current_archive() {
  aws s3 cp "s3://${BUCKET}/${FILEBASE}${FILEEXT}" .
}

extract_archive() {
  if [ -f "${FILEBASE}${FILEEXT}" ] ; then
    tar -xzf "${FILEBASE}${FILEEXT}"
  else
    log "archive does not exist."
  fi
}

restore_archive_if_present() {
  log "2. pull archive"

  if download_current_archive ; then
    log "File downloaded"
  else
    log "File doesn't exist"
  fi

  log "3. decompress archive"
  extract_archive
}

certbot_account_exists() {
  find "accounts/acme-v02.api.letsencrypt.org/directory/" -name regr.json 2>/dev/null | grep -q regr.json
}

ensure_certbot_account() {
  log "4. update registration"

  if certbot_account_exists ; then
    # @TODO this is problematic if there are multiple accounts involved
    log "updating account"
    # certbot update_account --email "$EMAIL" --agree-tos --no-eff-email
  else
    log "registering account"
    certbot register --email "$EMAIL" --agree-tos --no-eff-email
  fi
}

delete_certbot_domain() {
  domain="$1"
  log "Deleting certificate lineage for '${domain}' including '${domain}' and '*.${domain}' when managed together"
  certbot delete --cert-name "${domain}" --non-interactive
}

delete_requested_domains() {
  printf '%s\n' "${DELETE_DOMAINS}" | while IFS= read -r domain ; do
    [ -n "${domain}" ] || continue
    delete_certbot_domain "${domain}"
  done
}

run_certbot_renew() {
  log "No domains passed -- only renewing existing domains"
  certbot renew
}

run_certbot_issue_for_domain() {
  domain="$1"
  log "Renewing '${domain}' and '*.${domain}'"
  # shellcheck disable=SC2086
  certbot certonly --dns-route53 --cert-name "$domain" -d "$domain" -d "*.${domain}" $DEBUGFLAGS
}

run_certbot_issue_for_requested_domains() {
  printf '%s\n' "${REQUESTED_DOMAINS}" | while IFS= read -r domain ; do
    [ -n "${domain}" ] || continue
    run_certbot_issue_for_domain "${domain}"
  done
}

run_certbot_work() {
  log "5. run certbot"
  date > timestamp.txt

  if [ "${DELETE_MODE}" = "true" ] ; then
    delete_requested_domains
  elif [ -z "${REQUESTED_DOMAINS}" ] ; then
    run_certbot_renew
  else
    run_certbot_issue_for_requested_domains
  fi
}

generate_combined_certificates() {
  log "6. make combined certificates"

  find "${WORKDIR}/combined" -type f -name '*.pem' -delete 2>/dev/null || true
  find "${WORKDIR}/live" -type f -name 'combined.pem' -delete 2>/dev/null || true

  if [ -d "${WORKDIR}/live/" ] ; then
    find "${WORKDIR}/live/" -name fullchain.pem \
      | while read -r file ; do
          generate_combined "$file"
        done
  else
    log "no certificates to combine"
  fi
}

create_archive() {
  log "7. create archive"
  find live/ -maxdepth 1 -mindepth 1 -type d | sed 's|^live/||' | sort || true
  tar -czf "${FILEBASE}${FILEEXT}" --exclude "${FILEBASE}${FILEEXT}" .
}

upload_archive() {
  log "8. push archive"
  aws s3 cp "${FILEBASE}${FILEEXT}" "s3://${BUCKET}/${FILEBASE}${FILEEXT}"
  aws s3 cp "${FILEBASE}${FILEEXT}" "s3://${BUCKET}/${FILEBASE}${FILEVERSION}${FILEEXT}"
}

main() {
  init_defaults
  validate_environment
  parse_args "$@"

  log Certbotbot
  log "1. prep"

  prepare_workdir
  ensure_bucket_exists
  ensure_kms_key_exists
  restore_archive_if_present
  ensure_certbot_account
  run_certbot_work
  generate_combined_certificates
  create_archive
  upload_archive

  log Done.
}

main "$@"
