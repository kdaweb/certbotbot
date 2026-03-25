#!/bin/sh
set -eu

log() {
  printf '%s\n' "$*"
}

fail() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

init_defaults() {
  WORKDIR="${WORKDIR:-/etc/letsencrypt}"
  FILEBASE="${FILEBASE:-live}"
  FILEEXT="${FILEEXT:-.tar.gz}"
  FILEVERSION="${FILEVERSION:--$(date +%Y%m%d)}"
  DNS_PROVIDER="${DNS_PROVIDER:-route53}"
  AUTO_CREATE_KMS_KEY_IF_MISSING="${AUTO_CREATE_KMS_KEY_IF_MISSING:-false}"
  KMS_KEY_DESCRIPTION="${KMS_KEY_DESCRIPTION:-certbotbot managed key}"
}

validate_environment() {
  BUCKET="${BUCKET:?Error: no bucket set}"
  EMAIL="${EMAIL:?Error: no email address set}"

  if [ "${AUTO_CREATE_KMS_KEY_IF_MISSING}" = "true" ] ; then
    if [ -z "${KMS_KEY_ID:-}" ] ; then
      fail 'AUTO_CREATE_KMS_KEY_IF_MISSING=true but KMS_KEY_ID is not set'
    fi

    case "${KMS_KEY_ID}" in
      alias/*) : ;;
      *)
        fail 'KMS_KEY_ID must be an alias (for example, alias/certbotbot) when AUTO_CREATE_KMS_KEY_IF_MISSING=true'
        ;;
    esac
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

kms_cmd() {
  if [ -n "${AWS_REGION:-}" ] ; then
    aws kms "$@" --region "${AWS_REGION}"
  else
    aws kms "$@"
  fi
}

kms_bootstrap_enabled() {
  [ "${AUTO_CREATE_KMS_KEY_IF_MISSING}" = "true" ]
}

kms_key_exists() {
  kms_cmd describe-key --key-id "${KMS_KEY_ID}" >/dev/null 2>&1
}

create_kms_key() {
  kms_cmd create-key \
    --description "${KMS_KEY_DESCRIPTION}" \
    --key-spec SYMMETRIC_DEFAULT \
    --key-usage ENCRYPT_DECRYPT \
    --query 'KeyMetadata.KeyId' \
    --output text
}

create_kms_alias() {
  key_id="$1"
  kms_cmd create-alias --alias-name "${KMS_KEY_ID}" --target-key-id "${key_id}" >/dev/null 2>&1
}

wait_for_kms_alias() {
  attempts=0

  while [ "${attempts}" -lt 10 ] ; do
    if kms_key_exists ; then
      log "KMS key is ready for ${KMS_KEY_ID}"
      return 0
    fi

    attempts=$((attempts + 1))
    sleep 2
  done

  fail "KMS key alias ${KMS_KEY_ID} was not usable after creation attempt"
}

maybe_ensure_kms_key_exists() {
  if ! kms_bootstrap_enabled ; then
    return 0
  fi

  if kms_key_exists ; then
    log "KMS key already exists for ${KMS_KEY_ID}"
    return 0
  fi

  log "KMS key ${KMS_KEY_ID} not found; creating it"
  key_id="$(create_kms_key)"

  if create_kms_alias "${key_id}" ; then
    log "Created alias ${KMS_KEY_ID} for KMS key ${key_id}"
  else
    log "Alias creation did not succeed immediately; checking whether ${KMS_KEY_ID} now exists"
  fi

  wait_for_kms_alias
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
    log 'archive does not exist.'
  fi
}

restore_archive_if_present() {
  log '2. pull archive'

  if download_current_archive ; then
    log 'File downloaded'
  else
    log "File doesn't exist"
  fi

  log '3. decompress archive'
  extract_archive
}

certbot_account_exists() {
  find 'accounts/acme-v02.api.letsencrypt.org/directory/' -name regr.json 2>/dev/null | grep -q regr.json
}

register_certbot_account_if_needed() {
  if certbot_account_exists ; then
    # @TODO this is problematic if there are multiple accounts involved
    log 'updating account'
    # certbot update_account --email "$EMAIL" --agree-tos --no-eff-email
  else
    log 'registering account'
    certbot register --email "${EMAIL}" --agree-tos --no-eff-email
  fi
}

ensure_certbot_account() {
  log '4. update registration'
  register_certbot_account_if_needed
}

run_certbot_renew() {
  certbot renew
}

run_certbot_dns_route53() {
  domain="$1"
  # shellcheck disable=SC2086
  certbot certonly --dns-route53 -d "${domain}" -d "*.${domain}" $DEBUGFLAGS
}

run_certbot_dns_challenge() {
  domain="$1"

  case "${DNS_PROVIDER}" in
    route53)
      run_certbot_dns_route53 "${domain}"
      ;;
    *)
      fail "Unsupported DNS_PROVIDER: ${DNS_PROVIDER}"
      ;;
  esac
}

run_certbot_for_domain() {
  domain="$1"
  log "Renewing '${domain}' and '*.${domain}'"
  run_certbot_dns_challenge "${domain}"
}

run_certbot_for_requested_domains() {
  for domain in "$@" ; do
    run_certbot_for_domain "${domain}"
  done
}

run_certbot_work() {
  log '5. run certbot'
  date > timestamp.txt

  if [ "$#" -eq 0 ] || [ "${1:-}" = '' ] ; then
    log 'No domains passed -- only renewing existing domains'
    run_certbot_renew
  else
    run_certbot_for_requested_domains "$@"
  fi
}

generate_combined_for_directory() {
  directory="$1"
  fullchain="${directory}/fullchain.pem"
  privkey="${directory}/privkey.pem"
  combined="${directory}/combined.pem"

  cat "${fullchain}" "${privkey}" > "${combined}"
  cat "${fullchain}" "${privkey}" > "${WORKDIR}/combined/$(basename "${directory}").pem"
}

generate_combined_certificates() {
  log '6. make combined certificates'

  if [ -d "${WORKDIR}/live/" ] ; then
    find "${WORKDIR}/live/" -name fullchain.pem | while read -r file ; do
      generate_combined_for_directory "${file%/*}"
    done
  else
    log 'no certificates to combine'
  fi
}

create_archive() {
  log '7. create archive'
  find live/ -maxdepth 1 -mindepth 1 -type d | sed 's|^live/||' | sort || true
  tar -czf "${FILEBASE}${FILEEXT}" --exclude "${FILEBASE}${FILEEXT}" .
}

upload_current_archive() {
  aws s3 cp "${FILEBASE}${FILEEXT}" "s3://${BUCKET}/${FILEBASE}${FILEEXT}"
}

upload_versioned_archive() {
  aws s3 cp "${FILEBASE}${FILEEXT}" "s3://${BUCKET}/${FILEBASE}${FILEVERSION}${FILEEXT}"
}

upload_archive() {
  log '8. push archive'
  upload_current_archive
  upload_versioned_archive
}

main() {
  init_defaults
  validate_environment

  log 'Certbotbot'
  log '1. prep'

  prepare_workdir
  ensure_bucket_exists
  maybe_ensure_kms_key_exists
  restore_archive_if_present
  ensure_certbot_account
  run_certbot_work "$@"
  generate_combined_certificates
  create_archive
  upload_archive

  log 'Done.'
}

main "$@"
