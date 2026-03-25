#!/bin/sh

set -eu

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

log() {
  printf '%s\n' "$*"
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
    echo "Error: AUTO_CREATE_KMS_KEY_IF_MISSING=true but KMS_KEY_ID is not set" >&2
    exit 1
  fi

  case "${KMS_KEY_ID}" in
    alias/*) : ;;
    *)
      echo "Error: KMS_KEY_ID must be an alias (for example, alias/certbotbot) when AUTO_CREATE_KMS_KEY_IF_MISSING=true" >&2
      exit 1
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

  echo "Error: KMS key alias ${KMS_KEY_ID} was not usable after creation attempt" >&2
  exit 1
}

WORKDIR="${WORKDIR:-/etc/letsencrypt}"
BUCKET="${BUCKET:?Error: no bucket set}"
EMAIL="${EMAIL:?Error: no email address set}"
FILEBASE="${FILEBASE:-live}"
FILEEXT="${FILEEXT:-.tar.gz}"
FILEVERSION="${FILEVERSION:--$(date +%Y%m%d)}"

log Certbotbot
log "1. prep"
if [ ! -d "${WORKDIR}" ] ; then
  mkdir -p "${WORKDIR}"
fi
if ! aws s3 ls "${BUCKET}" >/dev/null 2>&1 ; then
  aws s3 mb "s3://${BUCKET}" >/dev/null
fi
ensure_kms_key_exists
cd "${WORKDIR}" || exit 1

log "2. pull archive"
cd "${WORKDIR}" || exit 1
if aws s3 cp "s3://${BUCKET}/${FILEBASE}${FILEEXT}" . ; then
  log "File downloaded"
else
  log "File doesn't exist"
fi

log "3. decompress archive"
if [ -f "${FILEBASE}${FILEEXT}" ] ; then
  tar -xzf "${FILEBASE}${FILEEXT}"
else
  log "archive does not exist."
fi

log "4. update registration"
if find "accounts/acme-v02.api.letsencrypt.org/directory/" -name regr.json 2>/dev/null | grep -q regr.json ; then
  # @TODO this is problematic if there are multiple accounts involved
  log "updating account"
  # certbot update_account --email "$EMAIL" --agree-tos --no-eff-email
else
  log "registering account"
  certbot register --email "$EMAIL" --agree-tos --no-eff-email
fi

log "5. run certbot"
date > timestamp.txt
if [ "$#" -eq 0 ] || [ "${1:-}" = "" ] ; then
  log "No domains passed -- only renewing existing domains"
  certbot renew
else
  for domain in "$@" ; do
    log "Renewing '${domain}' and '*.${domain}'"
    # shellcheck disable=SC2086
    certbot certonly --dns-route53 -d "$domain" -d "*.${domain}" $DEBUGFLAGS
  done
fi

log "6. make combined certificates"
if [ -d "${WORKDIR}/live/" ] ; then
  find "${WORKDIR}/live/" -name fullchain.pem \
    | while read -r file ; do
        generate_combined "$file"
      done
else
  log "no certificates to combine"
fi

log "7. create archive"
find live/ -maxdepth 1 -mindepth 1 -type d | sed 's|^live/||' | sort || true
tar -czf "${FILEBASE}${FILEEXT}" --exclude "${FILEBASE}${FILEEXT}" .

log "8. push archive"
aws s3 cp "${FILEBASE}${FILEEXT}" "s3://${BUCKET}/${FILEBASE}${FILEEXT}"
aws s3 cp "${FILEBASE}${FILEEXT}" "s3://${BUCKET}/${FILEBASE}${FILEVERSION}${FILEEXT}"

log Done.
