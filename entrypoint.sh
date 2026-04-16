#!/usr/bin/env bash

## @file entrypoint-refactored-functions.sh
## @brief Restore, manage, package, and publish Certbot state from S3-backed storage.
## @details
## This entrypoint script orchestrates a containerized Certbot workflow that
## restores persisted certificate state from an S3 bucket, performs account and
## certificate operations, regenerates combined PEM artifacts, repackages the
## working state, and uploads the resulting archive back to object storage.
##
## The script is intentionally stateful.  It treats the archive in S3 as the
## durable backing store for `/etc/letsencrypt` and rebuilds local state from
## that archive at startup before making any certificate changes.
##
## KMS key bootstrap is optional and remains separate from certificate storage.
## When enabled, the script can create a named KMS alias and backing symmetric
## key so later iterations can rely on that AWS-side prerequisite being present.
##
## Certificate issuance is currently implemented for AWS Route53 only.  When a
## base domain such as `example.com` is requested, the script obtains a single
## certificate lineage for both `example.com` and `*.example.com`.
##
## Delete mode operates on that same base-domain lineage assumption.  Deleting
## `example.com` is intended to delete the lineage that covers both the base
## domain and its wildcard subdomain pattern when they are managed together.
##
## @note
## The source of truth for behavior is the executable code.  This documentation
## explains intent and flow, but it does not alter the shell logic.
## @warning
## The script mutates persistent certificate state stored in S3.  Incorrect
## configuration, invalid AWS credentials, or an unintended delete request can
## affect the archive that subsequent runs rely upon.
## @see https://github.com/kdaweb/certbotbot
## @par Examples
## @code
## ./entrypoint-refactored-functions.sh
## ./entrypoint-refactored-functions.sh example.com
## ./entrypoint-refactored-functions.sh --delete-domain example.com
## AUTO_CREATE_KMS_KEY_IF_MISSING=true KMS_KEY_ID=alias/certbotbot ./entrypoint-refactored-functions.sh
## @endcode
#!/bin/sh

set -eu

## @fn log()
## @brief Write an informational log message to standard output.
## @details
## This helper provides a single, consistent logging format for the script's
## narrative progress messages.  It accepts all supplied positional words as a
## single message and prints them with a trailing newline.
## @param message the message text to print
## @retval 0 message printed successfully
## @par Examples
## @code
## log "Certbotbot"
## log "1. prep"
## @endcode
log() {
  printf '%s\n' "$*"
}


## @fn fail()
## @brief Write an error message and terminate the script.
## @details
## This helper centralizes fatal error handling for validations and unsupported
## argument combinations.  It writes a prefixed message to standard error and
## exits with a non-zero status so callers stop immediately.
## @param message the fatal error message to print
## @retval 1 always exits with failure
## @par Examples
## @code
## fail "unknown option: --bad-flag"
## fail "AUTO_CREATE_KMS_KEY_IF_MISSING=true but KMS_KEY_ID is not set"
## @endcode
fail() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}


## @fn generate_combined()
## @brief Build combined PEM files from Certbot fullchain and private key files.
## @details
## This function consumes one or more paths that point to `fullchain.pem` files.
## For each supplied path, it derives the enclosing lineage directory, reads the
## matching `fullchain.pem` and `privkey.pem`, and writes:
##
## - `combined.pem` inside that lineage directory, and
## - a copy into `/etc/letsencrypt/combined/` named after the lineage directory.
##
## The function loops over all supplied positional arguments until none remain.
## This helper assumes the expected Certbot directory layout already exists.
## @param filenames[] one or more paths to fullchain.pem files
## @retval 0 combined files created for all supplied paths
## @par Examples
## @code
## generate_combined "/etc/letsencrypt/live/example.com/fullchain.pem"
## generate_combined "/etc/letsencrypt/live/example.com/fullchain.pem" "/etc/letsencrypt/live/example.org/fullchain.pem"
## @endcode
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


## @fn kms_cmd()
## @brief Invoke the AWS KMS CLI with optional region scoping.
## @details
## This helper wraps `aws kms` so the rest of the script can call KMS commands
## without repeating region handling logic.  When `AWS_REGION` is set, the
## helper appends `--region "${AWS_REGION}"`; otherwise it relies on the AWS
## CLI's default region resolution behavior.
## @param kms_args[] arguments to pass through to `aws kms`
## @returns command output from the delegated `aws kms` invocation
## @retval 0 delegated KMS command succeeded
## @retval non-zero delegated KMS command failed
## @par Examples
## @code
## kms_cmd describe-key --key-id "alias/certbotbot"
## kms_cmd create-alias --alias-name "alias/certbotbot" --target-key-id "1234abcd-12ab-34cd-56ef-1234567890ab"
## @endcode
kms_cmd() {
  if [ -n "${AWS_REGION:-}" ] ; then
    aws kms "$@" --region "${AWS_REGION}"
  else
    aws kms "$@"
  fi
}


## @fn ensure_kms_key_exists()
## @brief Optionally create a configured KMS key alias if it does not exist yet.
## @details
## This function is gated by `AUTO_CREATE_KMS_KEY_IF_MISSING`.  When that flag
## is not exactly `true`, the function returns immediately and does nothing.
##
## When bootstrap is enabled, the function validates that `KMS_KEY_ID` is set
## and uses an alias form such as `alias/certbotbot`.  It then checks whether
## the alias already resolves.  If it does not, the function creates a new
## symmetric encryption key, attempts to create the alias, and waits briefly for
## the alias to become usable through AWS KMS eventual consistency.
##
## This helper exists only to provision the AWS-side prerequisite.  It does not
## encrypt or decrypt certificate artifacts.
## @param AUTO_CREATE_KMS_KEY_IF_MISSING= whether KMS bootstrap should run
## @param KMS_KEY_ID= alias name to require or create
## @param KMS_KEY_DESCRIPTION= description for a newly created KMS key
## @param AWS_REGION= AWS region override for CLI KMS calls
## @retval 0 bootstrap disabled or alias exists or was created successfully
## @retval 1 validation failed or alias was not usable after creation
## @warning
## Enabling this function requires IAM permission to describe keys, create keys,
## and create aliases.
## @par Examples
## @code
## AUTO_CREATE_KMS_KEY_IF_MISSING=true KMS_KEY_ID=alias/certbotbot ensure_kms_key_exists
## AUTO_CREATE_KMS_KEY_IF_MISSING=false ensure_kms_key_exists
## @endcode
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


## @fn init_defaults()
## @brief Initialize default configuration values and runtime mode variables.
## @details
## This function establishes the script's default working directory, archive
## naming conventions, version suffix, and argument-mode accumulators.  It does
## not validate required environment variables; that responsibility remains in
## `validate_environment()`.
##
## Delete-mode and requested-domain collections are initialized as empty strings
## so later helpers can populate them using newline-separated values.
## @retval 0 defaults initialized successfully
## @par Examples
## @code
## init_defaults
## WORKDIR="/custom/path" init_defaults
## @endcode
init_defaults() {
  WORKDIR="${WORKDIR:-/etc/letsencrypt}"
  FILEBASE="${FILEBASE:-live}"
  FILEEXT="${FILEEXT:-.tar.gz}"
  FILEVERSION="${FILEVERSION:--$(date +%Y%m%d)}"
  DELETE_MODE=false
  DELETE_DOMAINS=""
  REQUESTED_DOMAINS=""
}


## @fn validate_environment()
## @brief Require core environment variables needed for normal operation.
## @details
## This function validates the minimum runtime configuration by requiring
## `BUCKET` and `EMAIL`.  The checks deliberately use shell parameter expansion
## so failures produce immediate, descriptive errors before any work is done.
## @param BUCKET= S3 bucket name that stores the archive
## @param EMAIL= contact email used for Certbot account registration
## @retval 0 required environment variables are present
## @retval 1 one or more required environment variables are missing
## @par Examples
## @code
## BUCKET="my-cert-bucket" EMAIL="ops@example.com" validate_environment
## @endcode
validate_environment() {
  BUCKET="${BUCKET:?Error: no bucket set}"
  EMAIL="${EMAIL:?Error: no email address set}"
}


## @fn parse_args()
## @brief Parse positional domains and delete-mode command-line flags.
## @details
## This function supports three operating modes:
##
## - no arguments, which later implies `certbot renew`
## - positional base domains, which later imply Route53-backed issuance for
##   both the base domain and wildcard subdomain pattern
## - one or more `--delete-domain` flags, which later imply deletion of the
##   corresponding base-domain certificate lineages
##
## Delete mode is mutually exclusive with positional domains.  Unknown options
## are treated as fatal errors.  The helper also provides a lightweight usage
## summary for `--help` and `-h`.
## @param args[] command-line arguments passed to the script
## @retval 0 arguments parsed successfully
## @retval 1 invalid or conflicting arguments were supplied
## @par Examples
## @code
## parse_args
## parse_args example.com example.org
## parse_args --delete-domain example.com --delete-domain example.org
## @endcode
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


## @fn prepare_workdir()
## @brief Create required local directories and enter the working directory.
## @details
## This helper ensures the main Certbot working directory exists and that the
## `combined/` subdirectory is present before any restore or certificate work is
## attempted.  It then changes the current shell directory to `WORKDIR`.
## @param WORKDIR= local Certbot state directory to create and enter
## @retval 0 working directories exist and current directory changed successfully
## @retval 1 changing to the working directory failed
## @par Examples
## @code
## WORKDIR="/etc/letsencrypt" prepare_workdir
## WORKDIR="/tmp/certbotbot" prepare_workdir
## @endcode
prepare_workdir() {
  if [ ! -d "${WORKDIR}" ] ; then
    mkdir -p "${WORKDIR}"
  fi

  if [ ! -d "${WORKDIR}/combined" ] ; then
    mkdir -p "${WORKDIR}/combined"
  fi

  cd "${WORKDIR}" || exit 1
}


## @fn ensure_bucket_exists()
## @brief Ensure that the configured S3 bucket exists before archive operations.
## @details
## This helper checks for the bucket with `aws s3 ls` and creates it with
## `aws s3 mb` when it is absent.  The function assumes the configured AWS
## credentials and region, if any, are already suitable for bucket operations.
## @param BUCKET= S3 bucket name to verify or create
## @retval 0 bucket exists or was created successfully
## @retval non-zero AWS CLI bucket operation failed
## @par Examples
## @code
## BUCKET="my-cert-bucket" ensure_bucket_exists
## @endcode
ensure_bucket_exists() {
  if ! aws s3 ls "${BUCKET}" >/dev/null 2>&1 ; then
    aws s3 mb "s3://${BUCKET}" >/dev/null
  fi
}


## @fn download_current_archive()
## @brief Download the current archive from S3 into the working directory.
## @details
## This helper copies the current archive object identified by `FILEBASE` and
## `FILEEXT` from the configured bucket into the current directory.  It does not
## inspect or extract the archive; it only performs the transfer.
## @param BUCKET= S3 bucket name containing the archive
## @param FILEBASE= archive basename
## @param FILEEXT= archive extension suffix
## @retval 0 archive downloaded successfully
## @retval non-zero archive download failed
## @par Examples
## @code
## download_current_archive
## @endcode
download_current_archive() {
  aws s3 cp "s3://${BUCKET}/${FILEBASE}${FILEEXT}" .
}


## @fn extract_archive()
## @brief Extract the downloaded archive into the working directory when present.
## @details
## This helper checks whether the expected archive file exists locally.  If it
## does, the helper extracts it with `tar -xzf`.  If it does not, the function
## logs that local archive state is absent and returns without error.
## @param FILEBASE= archive basename
## @param FILEEXT= archive extension suffix
## @retval 0 archive extracted successfully or no local archive was present
## @retval non-zero tar extraction failed
## @par Examples
## @code
## extract_archive
## @endcode
extract_archive() {
  if [ -f "${FILEBASE}${FILEEXT}" ] ; then
    tar -xzf "${FILEBASE}${FILEEXT}"
  else
    log "archive does not exist."
  fi
}


## @fn restore_archive_if_present()
## @brief Download and extract the persisted Certbot state archive when available.
## @details
## This helper narrates the restore phase, attempts to download the current
## archive from S3, logs whether that transfer succeeded, and then extracts the
## archive when a local copy is present.  Missing archive state is treated as a
## normal first-run condition rather than a fatal error.
## @retval 0 restore phase completed successfully
## @retval non-zero an unexpected extraction failure occurred
## @par Examples
## @code
## restore_archive_if_present
## @endcode
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


## @fn certbot_account_exists()
## @brief Check whether Certbot account registration metadata is present locally.
## @details
## The script currently treats the presence of a `regr.json` file under the
## standard Let's Encrypt account path as evidence that account registration has
## already occurred.  This is a pragmatic check rather than a full account
## inventory.
## @retval 0 registration metadata was found
## @retval 1 registration metadata was not found
## @note
## The surrounding code already notes that this approach may be problematic when
## multiple accounts are involved.
## @par Examples
## @code
## if certbot_account_exists ; then
##   log "updating account"
## fi
## @endcode
certbot_account_exists() {
  find "accounts/acme-v02.api.letsencrypt.org/directory/" -name regr.json 2>/dev/null | grep -q regr.json
}


## @fn ensure_certbot_account()
## @brief Register a Certbot account when one is not already present locally.
## @details
## This helper logs the registration phase, checks for existing account
## metadata, and registers the account with Certbot when no registration is
## present.  The update path remains intentionally commented out in the source,
## so an existing account currently results only in a log message.
## @param EMAIL= contact email for Certbot registration
## @retval 0 account exists already or registration succeeded
## @retval non-zero Certbot registration failed
## @par Examples
## @code
## ensure_certbot_account
## @endcode
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


## @fn delete_certbot_domain()
## @brief Delete a base-domain certificate lineage from local Certbot state.
## @details
## This helper expresses the tool's base-domain lineage contract: deleting
## `example.com` is intended to delete the lineage that manages both
## `example.com` and `*.example.com` when they were issued together.  The
## implementation delegates to `certbot delete --cert-name`.
## @param domain the base-domain certificate lineage name to delete
## @retval 0 Certbot deleted the named lineage successfully
## @retval non-zero Certbot deletion failed
## @warning
## The deletion target is the Certbot certificate name.  This helper assumes
## that the certificate lineage name matches the base domain used during issue
## mode.
## @par Examples
## @code
## delete_certbot_domain "example.com"
## @endcode
delete_certbot_domain() {
  domain="$1"
  log "Deleting certificate lineage for '${domain}' including '${domain}' and '*.${domain}' when managed together"
  certbot delete --cert-name "${domain}" --non-interactive
}


## @fn delete_requested_domains()
## @brief Delete all requested base-domain certificate lineages.
## @details
## This helper iterates over the newline-separated `DELETE_DOMAINS` collection
## created by `parse_args()` and invokes `delete_certbot_domain()` for each
## non-empty entry.
## @param DELETE_DOMAINS= newline-separated base-domain lineage names to delete
## @retval 0 all requested deletions succeeded
## @retval non-zero one or more deletions failed
## @par Examples
## @code
## DELETE_DOMAINS="example.com
## example.org"
## delete_requested_domains
## @endcode
delete_requested_domains() {
  printf '%s\n' "${DELETE_DOMAINS}" | while IFS= read -r domain ; do
    [ -n "${domain}" ] || continue
    delete_certbot_domain "${domain}"
  done
}


## @fn run_certbot_renew()
## @brief Renew all existing certificate lineages managed in the restored state.
## @details
## This helper logs the no-argument renewal path and delegates directly to
## `certbot renew`.
## @retval 0 Certbot renew completed successfully
## @retval non-zero Certbot renew failed
## @par Examples
## @code
## run_certbot_renew
## @endcode
run_certbot_renew() {
  log "No domains passed -- only renewing existing domains"
  certbot renew
}


## @fn run_certbot_issue_for_domain()
## @brief Issue or renew a Route53-backed certificate lineage for one base domain.
## @details
## This helper currently implements the script's only challenge-provider path.
## It requests a single certificate lineage that covers both the supplied base
## domain and the wildcard subdomain pattern `*.domain`.
##
## The Route53 plugin selection is hard-coded here.  This function is therefore
## the narrowest natural seam for future DNS-provider expansion.
## @param domain the base domain to issue or renew
## @param DEBUGFLAGS= optional additional Certbot flags supplied via the environment
## @retval 0 Certbot issuance for the domain succeeded
## @retval non-zero Certbot issuance failed
## @par Examples
## @code
## run_certbot_issue_for_domain "example.com"
## DEBUGFLAGS="--dry-run" run_certbot_issue_for_domain "example.com"
## @endcode
run_certbot_issue_for_domain() {
  domain="$1"
  log "Renewing '${domain}' and '*.${domain}'"
  # shellcheck disable=SC2086
  certbot certonly --dns-route53 -d "$domain" -d "*.${domain}" $DEBUGFLAGS
}


## @fn run_certbot_issue_for_requested_domains()
## @brief Issue or renew certificates for all requested base domains.
## @details
## This helper iterates over the newline-separated `REQUESTED_DOMAINS`
## collection created by `parse_args()` and invokes
## `run_certbot_issue_for_domain()` for each non-empty entry.
## @param REQUESTED_DOMAINS= newline-separated base domains to issue or renew
## @retval 0 all requested issuance operations succeeded
## @retval non-zero one or more issuance operations failed
## @par Examples
## @code
## REQUESTED_DOMAINS="example.com
## example.org"
## run_certbot_issue_for_requested_domains
## @endcode
run_certbot_issue_for_requested_domains() {
  printf '%s\n' "${REQUESTED_DOMAINS}" | while IFS= read -r domain ; do
    [ -n "${domain}" ] || continue
    run_certbot_issue_for_domain "${domain}"
  done
}


## @fn run_certbot_work()
## @brief Dispatch the Certbot phase according to delete mode or issue mode.
## @details
## This helper records a timestamp and then selects one of three mutually
## exclusive paths:
##
## - delete requested lineages when delete mode is active
## - renew all known lineages when no domains were requested
## - issue or renew the requested base domains otherwise
##
## The timestamp file is written for all modes, including delete mode.
## @retval 0 selected Certbot workflow completed successfully
## @retval non-zero selected Certbot workflow failed
## @par Examples
## @code
## run_certbot_work
## @endcode
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


## @fn generate_combined_certificates()
## @brief Rebuild the derived combined PEM files from live Certbot lineages.
## @details
## This helper clears any existing combined PEM outputs and then scans the live
## Certbot lineage directories for `fullchain.pem` files.  For each one found,
## it delegates to `generate_combined()` to create both in-lineage and shared
## combined PEM artifacts.
##
## Clearing the shared `combined/` directory first avoids stale combined files
## remaining after lineage deletion.
## @param WORKDIR= local Certbot state directory that contains `live/` and `combined/`
## @retval 0 combined certificate generation completed successfully
## @retval non-zero one or more file operations failed
## @par Examples
## @code
## generate_combined_certificates
## @endcode
generate_combined_certificates() {
  log "6. make combined certificates"

  find "${WORKDIR}/combined" -type f -name '*.pem' -delete 2>/dev/null || true

  if [ -d "${WORKDIR}/live/" ] ; then
    find "${WORKDIR}/live/" -name fullchain.pem \
      | while read -r file ; do
          generate_combined "$file"
        done
  else
    log "no certificates to combine"
  fi
}


## @fn create_archive()
## @brief Create the current tarball from the working Certbot state directory.
## @details
## This helper logs the archive phase, lists the immediate lineage directories
## under `live/` for operator visibility, and then writes a gzipped tar archive
## that contains the current working tree while excluding the archive file
## itself.
## @param FILEBASE= archive basename
## @param FILEEXT= archive extension suffix
## @retval 0 archive created successfully
## @retval non-zero archive creation failed
## @par Examples
## @code
## create_archive
## @endcode
create_archive() {
  log "7. create archive"
  find live/ -maxdepth 1 -mindepth 1 -type d | sed 's|^live/||' | sort || true
  tar -czf "${FILEBASE}${FILEEXT}" --exclude "${FILEBASE}${FILEEXT}" .
}


## @fn upload_archive()
## @brief Upload the current archive and a dated backup archive to S3.
## @details
## This helper publishes two objects:
##
## - the current archive key used for the next restore
## - a dated archive key used as a versioned backup snapshot
##
## This preserves the existing operational model where one object acts as the
## active state artifact and another records the run's dated backup.
## @param BUCKET= S3 bucket name that stores the archive
## @param FILEBASE= archive basename
## @param FILEEXT= archive extension suffix
## @param FILEVERSION= dated suffix appended to the backup object key
## @retval 0 both uploads succeeded
## @retval non-zero one or more uploads failed
## @par Examples
## @code
## upload_archive
## @endcode
upload_archive() {
  log "8. push archive"
  aws s3 cp "${FILEBASE}${FILEEXT}" "s3://${BUCKET}/${FILEBASE}${FILEEXT}"
  aws s3 cp "${FILEBASE}${FILEEXT}" "s3://${BUCKET}/${FILEBASE}${FILEVERSION}${FILEEXT}"
}


## @fn main()
## @brief Execute the full Certbotbot orchestration workflow.
## @details
## This function wires the script together in a deliberate sequence:
##
## - initialize defaults
## - validate required environment
## - parse command-line arguments
## - prepare local working directories
## - ensure the S3 bucket exists
## - optionally bootstrap the KMS key alias
## - restore persisted Certbot state from S3
## - ensure the Certbot account exists
## - run the selected Certbot operation
## - regenerate combined PEM outputs
## - create the updated archive
## - upload the current and dated archives back to S3
##
## This high-level flow is the architectural backbone of the script and is the
## part most likely to remain stable even as individual providers evolve.
## @param args[] command-line arguments passed through to parse_args
## @retval 0 workflow completed successfully
## @retval non-zero one or more workflow phases failed
## @par Examples
## @code
## main
## main example.com
## main --delete-domain example.com
## @endcode
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
