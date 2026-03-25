#!/bin/sh
## @file entrypoint.sh
## @brief Restore, renew, combine, and archive Let's Encrypt certificates.
## @details
## Downloads the current certificate archive from S3, restores any existing state,
## ensures the Certbot account is present, optionally bootstraps an AWS KMS key
## alias, renews existing certificates or issues certificates for requested
## domains, generates combined certificate files, and uploads both current and
## versioned archives back to S3.
## @note The script expects AWS CLI and Certbot tooling to be available in the
## execution environment.
## @par Examples
## @code
## BUCKET=my-cert-archive EMAIL=admin@example.com ./entrypoint.sh
## BUCKET=my-cert-archive EMAIL=admin@example.com ./entrypoint.sh example.com
## AUTO_CREATE_KMS_KEY_IF_MISSING=true KMS_KEY_ID=alias/certbotbot BUCKET=my-cert-archive EMAIL=admin@example.com ./entrypoint.sh example.com
## @endcode
#!/bin/sh
set -eu

## @fn log()
## @brief Print a message to standard output.
## @details
## Joins all positional arguments using the shell's standard word separation and
## writes the resulting line to standard output.
## @param message_parts[] the words to print as a single log line
## @retval 0 the message was written
## @retval 1 printf reported a write failure
## @par Examples
## @code
## log "2. pull archive"
## @endcode
log() {
  printf '%s\n' "$*"
}

## @fn fail()
## @brief Print an error message to standard error and exit.
## @details
## Formats the provided message with an Error: prefix, writes it to standard
## error, and terminates the script with exit status 1.
## @param message_parts[] the words to print as the error message
## @retval 1 the script always exits with failure after printing the message
## @par Examples
## @code
## fail "missing required configuration"
## @endcode
fail() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

## @fn init_defaults()
## @brief Initialize configuration variables from the environment or defaults.
## @details
## Sets default values for the working directory, archive naming, DNS provider,
## optional KMS bootstrapping behavior, and KMS key description when those
## values are not already defined in the environment.
## @param WORKDIR= base directory for Certbot state and generated files
## @param FILEBASE= archive base name without the extension
## @param FILEEXT= archive extension to use for uploads and downloads
## @param FILEVERSION= version suffix appended to the versioned archive name
## @param DNS_PROVIDER= DNS challenge provider selector
## @param AUTO_CREATE_KMS_KEY_IF_MISSING= whether to create the KMS alias when absent
## @param KMS_KEY_DESCRIPTION= description to use when creating a new KMS key
## @retval 0 defaults were initialized
## @retval 1 shell expansion failed while assigning defaults
## @par Examples
## @code
## WORKDIR=/work FILEBASE=live init_defaults
## @endcode
init_defaults() {
  WORKDIR="${WORKDIR:-/etc/letsencrypt}"
  FILEBASE="${FILEBASE:-live}"
  FILEEXT="${FILEEXT:-.tar.gz}"
  FILEVERSION="${FILEVERSION:--$(date +%Y%m%d)}"
  DNS_PROVIDER="${DNS_PROVIDER:-route53}"
  AUTO_CREATE_KMS_KEY_IF_MISSING="${AUTO_CREATE_KMS_KEY_IF_MISSING:-false}"
  KMS_KEY_DESCRIPTION="${KMS_KEY_DESCRIPTION:-certbotbot managed key}"
}

## @fn validate_environment()
## @brief Validate required environment variables and KMS bootstrap settings.
## @details
## Requires BUCKET and EMAIL to be present. When automatic KMS creation is
## enabled, also requires KMS_KEY_ID and restricts it to alias names because
## the bootstrap flow creates an alias rather than referencing a raw key ID.
## @param BUCKET= S3 bucket name that stores certificate archives
## @param EMAIL= email address used for Certbot registration
## @param AUTO_CREATE_KMS_KEY_IF_MISSING= whether KMS alias creation is enabled
## @param KMS_KEY_ID= KMS alias name to validate when bootstrap is enabled
## @retval 0 required values are present and valid
## @retval 1 a required value is missing or invalid
## @par Examples
## @code
## BUCKET=my-cert-archive EMAIL=admin@example.com validate_environment
## @endcode
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

## @fn prepare_workdir()
## @brief Create the working directory structure and enter it.
## @details
## Ensures the base working directory and its combined subdirectory exist, then
## changes the current directory to the configured working directory.
## @param WORKDIR= base directory for Certbot state and generated files
## @retval 0 the working directory exists and is now current
## @retval 1 directory creation or cd failed
## @par Examples
## @code
## WORKDIR=/etc/letsencrypt prepare_workdir
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

## @fn kms_cmd()
## @brief Run an AWS KMS command with an optional explicit region.
## @details
## Invokes aws kms with the provided arguments. When AWS_REGION is set, the
## command appends --region so KMS operations run in the desired region.
## @param aws_kms_args[] arguments to pass through to aws kms
## @param AWS_REGION= optional AWS region override for KMS operations
## @returns command output from aws kms when the chosen subcommand writes to standard output
## @retval 0 the aws kms command succeeded
## @retval 1 the aws kms command failed
## @par Examples
## @code
## AWS_REGION=us-east-1 kms_cmd describe-key --key-id alias/certbotbot
## @endcode
kms_cmd() {
  if [ -n "${AWS_REGION:-}" ] ; then
    aws kms "$@" --region "${AWS_REGION}"
  else
    aws kms "$@"
  fi
}

## @fn kms_bootstrap_enabled()
## @brief Report whether automatic KMS alias creation is enabled.
## @details
## Uses the value of AUTO_CREATE_KMS_KEY_IF_MISSING as a predicate suitable for
## shell conditionals.
## @param AUTO_CREATE_KMS_KEY_IF_MISSING= whether KMS bootstrap is enabled
## @retval 0 KMS bootstrap is enabled
## @retval 1 KMS bootstrap is disabled
## @par Examples
## @code
## AUTO_CREATE_KMS_KEY_IF_MISSING=true kms_bootstrap_enabled && log "bootstrap enabled"
## @endcode
kms_bootstrap_enabled() {
  [ "${AUTO_CREATE_KMS_KEY_IF_MISSING}" = "true" ]
}

## @fn kms_key_exists()
## @brief Test whether the configured KMS key or alias can be described.
## @details
## Calls describe-key for KMS_KEY_ID and suppresses command output so the
## result can be used as a shell predicate.
## @param KMS_KEY_ID= KMS key identifier or alias to test
## @retval 0 the key or alias exists and can be described
## @retval 1 the key or alias does not exist or is not accessible
## @par Examples
## @code
## KMS_KEY_ID=alias/certbotbot kms_key_exists && log "key present"
## @endcode
kms_key_exists() {
  kms_cmd describe-key --key-id "${KMS_KEY_ID}" >/dev/null 2>&1
}

## @fn create_kms_key()
## @brief Create a new symmetric AWS KMS key.
## @details
## Creates an encrypt-decrypt key using the configured description and prints
## the new key ID to standard output for later alias creation.
## @param KMS_KEY_DESCRIPTION= description for the new KMS key
## @returns the newly created AWS KMS key ID
## @retval 0 the key was created and the key ID was printed
## @retval 1 KMS key creation failed
## @par Examples
## @code
## KMS_KEY_DESCRIPTION="certbotbot managed key" create_kms_key
## @endcode
create_kms_key() {
  kms_cmd create-key \
    --description "${KMS_KEY_DESCRIPTION}" \
    --key-spec SYMMETRIC_DEFAULT \
    --key-usage ENCRYPT_DECRYPT \
    --query 'KeyMetadata.KeyId' \
    --output text
}

## @fn create_kms_alias()
## @brief Create the configured KMS alias for an existing key.
## @details
## Associates KMS_KEY_ID with the provided key ID and suppresses command output
## so the function can be used in shell conditionals.
## @param key_id the AWS KMS key ID that should receive the alias
## @param KMS_KEY_ID= alias name to create
## @retval 0 the alias was created
## @retval 1 alias creation failed
## @par Examples
## @code
## KMS_KEY_ID=alias/certbotbot create_kms_alias 1234abcd-12ab-34cd-56ef-1234567890ab
## @endcode
create_kms_alias() {
  key_id="$1"
  kms_cmd create-alias --alias-name "${KMS_KEY_ID}" --target-key-id "${key_id}" >/dev/null 2>&1
}

## @fn wait_for_kms_alias()
## @brief Wait for the configured KMS alias to become usable.
## @details
## Polls describe-key up to ten times with a short delay between attempts and
## fails the script if the alias never becomes usable.
## @param KMS_KEY_ID= alias name to wait for
## @retval 0 the alias became usable within the retry window
## @retval 1 the alias was still unusable after all retries
## @par Examples
## @code
## KMS_KEY_ID=alias/certbotbot wait_for_kms_alias
## @endcode
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

## @fn maybe_ensure_kms_key_exists()
## @brief Create the configured KMS alias when bootstrap is enabled and needed.
## @details
## Returns immediately when bootstrap is disabled. When enabled, it checks for
## the configured alias, creates a new key if the alias is missing, attempts to
## create the alias, and waits for that alias to become usable.
## @param AUTO_CREATE_KMS_KEY_IF_MISSING= whether KMS bootstrap is enabled
## @param KMS_KEY_ID= alias name to verify or create
## @param KMS_KEY_DESCRIPTION= description for a newly created KMS key
## @retval 0 bootstrap was unnecessary or completed successfully
## @retval 1 key creation or alias readiness checks failed
## @par Examples
## @code
## AUTO_CREATE_KMS_KEY_IF_MISSING=true KMS_KEY_ID=alias/certbotbot maybe_ensure_kms_key_exists
## @endcode
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

## @fn ensure_bucket_exists()
## @brief Ensure the configured S3 bucket exists.
## @details
## Checks whether the configured bucket can be listed. When it cannot, creates
## the bucket using aws s3 mb.
## @param BUCKET= S3 bucket name that stores certificate archives
## @retval 0 the bucket already exists or was created successfully
## @retval 1 the existence check or bucket creation failed
## @par Examples
## @code
## BUCKET=my-cert-archive ensure_bucket_exists
## @endcode
ensure_bucket_exists() {
  if ! aws s3 ls "${BUCKET}" >/dev/null 2>&1 ; then
    aws s3 mb "s3://${BUCKET}" >/dev/null
  fi
}

## @fn download_current_archive()
## @brief Download the current certificate archive from S3.
## @details
## Copies the current archive object into the working directory using the
## configured bucket, archive base name, and extension.
## @param BUCKET= S3 bucket name that stores certificate archives
## @param FILEBASE= archive base name without the extension
## @param FILEEXT= archive extension to download
## @retval 0 the archive was downloaded
## @retval 1 the archive could not be downloaded
## @par Examples
## @code
## BUCKET=my-cert-archive FILEBASE=live FILEEXT=.tar.gz download_current_archive
## @endcode
download_current_archive() {
  aws s3 cp "s3://${BUCKET}/${FILEBASE}${FILEEXT}" .
}

## @fn extract_archive()
## @brief Extract the downloaded certificate archive when present.
## @details
## Unpacks the configured archive into the current working directory when the
## archive file exists locally. Logs a message instead when no archive file is
## present.
## @param FILEBASE= archive base name without the extension
## @param FILEEXT= archive extension to extract
## @retval 0 the archive was extracted or no archive file was present
## @retval 1 tar extraction failed
## @par Examples
## @code
## FILEBASE=live FILEEXT=.tar.gz extract_archive
## @endcode
extract_archive() {
  if [ -f "${FILEBASE}${FILEEXT}" ] ; then
    tar -xzf "${FILEBASE}${FILEEXT}"
  else
    log 'archive does not exist.'
  fi
}

## @fn restore_archive_if_present()
## @brief Download and extract the current certificate archive when available.
## @details
## Logs the restore steps, attempts to download the current archive from S3,
## reports whether the object was found, and extracts the archive when the file
## is present locally after the download step.
## @param BUCKET= S3 bucket name that stores certificate archives
## @param FILEBASE= archive base name without the extension
## @param FILEEXT= archive extension to restore
## @retval 0 restore processing completed
## @retval 1 archive extraction failed after a successful download
## @par Examples
## @code
## BUCKET=my-cert-archive FILEBASE=live FILEEXT=.tar.gz restore_archive_if_present
## @endcode
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

## @fn certbot_account_exists()
## @brief Test whether a Certbot account registration file exists.
## @details
## Searches the default Let's Encrypt account directory for regr.json and uses
## the result as a shell predicate.
## @retval 0 a registration file was found
## @retval 1 no registration file was found
## @par Examples
## @code
## certbot_account_exists && log "account found"
## @endcode
certbot_account_exists() {
  find 'accounts/acme-v02.api.letsencrypt.org/directory/' -name regr.json 2>/dev/null | grep -q regr.json
}

## @fn register_certbot_account_if_needed()
## @brief Register a Certbot account when no account is present.
## @details
## Detects whether an existing account registration file is available. When an
## account exists, logs that the account would be updated. When no account
## exists, registers a new account with the configured email address.
## @param EMAIL= email address used for Certbot registration
## @note The existing-account path assumes a single account layout.
## @par Examples
## @code
## EMAIL=admin@example.com register_certbot_account_if_needed
## @endcode
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

## @fn ensure_certbot_account()
## @brief Log and perform Certbot account setup work.
## @details
## Emits the registration step marker and then ensures an account is present by
## delegating to register_certbot_account_if_needed.
## @param EMAIL= email address used for Certbot registration
## @retval 0 account setup completed successfully
## @retval 1 account registration failed
## @par Examples
## @code
## EMAIL=admin@example.com ensure_certbot_account
## @endcode
ensure_certbot_account() {
  log '4. update registration'
  register_certbot_account_if_needed
}

## @fn run_certbot_renew()
## @brief Renew existing certificates.
## @details
## Runs certbot renew using the current Certbot configuration and state.
## @retval 0 certificate renewal completed successfully
## @retval 1 certificate renewal failed
## @par Examples
## @code
## run_certbot_renew
## @endcode
run_certbot_renew() {
  certbot renew
}

## @fn run_certbot_dns_route53()
## @brief Request or renew a certificate for a domain and its wildcard using Route53.
## @details
## Runs certbot certonly with the Route53 DNS plugin for the provided domain and
## for the matching wildcard name. Optional DEBUGFLAGS are expanded as written.
## @param domain the base domain to request
## @param DEBUGFLAGS= optional additional flags passed through to certbot
## @retval 0 certificate issuance or renewal completed successfully
## @retval 1 certbot returned a failure status
## @par Examples
## @code
## DEBUGFLAGS="--dry-run" run_certbot_dns_route53 example.com
## @endcode
run_certbot_dns_route53() {
  domain="$1"
  # shellcheck disable=SC2086
  certbot certonly --dns-route53 -d "${domain}" -d "*.${domain}" $DEBUGFLAGS
}

## @fn run_certbot_dns_challenge()
## @brief Run the configured DNS challenge implementation for a domain.
## @details
## Selects a provider-specific Certbot command based on DNS_PROVIDER. The
## current implementation supports route53 only.
## @param domain the base domain to request
## @param DNS_PROVIDER= DNS challenge provider selector
## @retval 0 the provider-specific challenge command succeeded
## @retval 1 the provider was unsupported or the provider command failed
## @par Examples
## @code
## DNS_PROVIDER=route53 run_certbot_dns_challenge example.com
## @endcode
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

## @fn run_certbot_for_domain()
## @brief Run Certbot work for one requested domain.
## @details
## Logs the requested domain and wildcard pair, then dispatches to the
## configured DNS challenge implementation.
## @param domain the base domain to request
## @retval 0 Certbot work for the domain completed successfully
## @retval 1 Certbot work for the domain failed
## @par Examples
## @code
## run_certbot_for_domain example.com
## @endcode
run_certbot_for_domain() {
  domain="$1"
  log "Renewing '${domain}' and '*.${domain}'"
  run_certbot_dns_challenge "${domain}"
}

## @fn run_certbot_for_requested_domains()
## @brief Run Certbot work for each requested domain.
## @details
## Iterates over every positional domain argument and processes each domain in
## sequence.
## @param domains[] one or more base domains to request or renew
## @retval 0 all requested domains were processed successfully
## @retval 1 processing failed for at least one requested domain
## @par Examples
## @code
## run_certbot_for_requested_domains example.com example.org
## @endcode
run_certbot_for_requested_domains() {
  for domain in "$@" ; do
    run_certbot_for_domain "${domain}"
  done
}

## @fn run_certbot_work()
## @brief Renew existing certificates or process requested domains.
## @details
## Writes a timestamp marker, then renews existing certificates when no domain
## arguments are provided. When domain arguments are present, processes each
## requested domain explicitly.
## @param domains[] optional base domains to request or renew explicitly
## @retval 0 Certbot work completed successfully
## @retval 1 renewal or requested-domain processing failed
## @par Examples
## @code
## run_certbot_work
## run_certbot_work example.com example.org
## @endcode
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

## @fn generate_combined_for_directory()
## @brief Create combined certificate files for one live certificate directory.
## @details
## Concatenates fullchain.pem and privkey.pem into combined.pem within the
## source directory and also writes a second combined file into the shared
## combined directory named after the certificate directory.
## @param directory path to one certificate directory under live/
## @retval 0 combined certificate files were written
## @retval 1 one of the source files was missing or a write failed
## @par Examples
## @code
## generate_combined_for_directory /etc/letsencrypt/live/example.com
## @endcode
generate_combined_for_directory() {
  directory="$1"
  fullchain="${directory}/fullchain.pem"
  privkey="${directory}/privkey.pem"
  combined="${directory}/combined.pem"

  cat "${fullchain}" "${privkey}" > "${combined}"
  cat "${fullchain}" "${privkey}" > "${WORKDIR}/combined/$(basename "${directory}").pem"
}

## @fn generate_combined_certificates()
## @brief Generate combined certificate files for every live certificate.
## @details
## Searches the live certificate tree for fullchain.pem files and generates a
## combined certificate for each matching directory. Logs a message when the
## live directory is absent.
## @param WORKDIR= base directory that contains the live/ and combined/ trees
## @retval 0 combined generation completed or there were no certificates to combine
## @retval 1 combined generation failed for at least one certificate directory
## @par Examples
## @code
## WORKDIR=/etc/letsencrypt generate_combined_certificates
## @endcode
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

## @fn create_archive()
## @brief Create a compressed archive of the working directory contents.
## @details
## Logs the archive step, prints the sorted names of immediate directories under
## live/, and creates a gzip-compressed tar archive of the current working
## directory while excluding any archive file that matches the current target
## archive name.
## @param FILEBASE= archive base name without the extension
## @param FILEEXT= archive extension to create
## @returns sorted certificate directory names from live/ before archive creation
## @retval 0 the archive was created successfully
## @retval 1 archive creation failed
## @par Examples
## @code
## FILEBASE=live FILEEXT=.tar.gz create_archive
## @endcode
create_archive() {
  log '7. create archive'
  find live/ -maxdepth 1 -mindepth 1 -type d | sed 's|^live/||' | sort || true
  tar -czf "${FILEBASE}${FILEEXT}" --exclude "${FILEBASE}${FILEEXT}" .
}

## @fn upload_current_archive()
## @brief Upload the current archive object to S3.
## @details
## Copies the generated archive to the current archive object path in the
## configured bucket.
## @param BUCKET= S3 bucket name that stores certificate archives
## @param FILEBASE= archive base name without the extension
## @param FILEEXT= archive extension to upload
## @retval 0 the current archive upload succeeded
## @retval 1 the current archive upload failed
## @par Examples
## @code
## BUCKET=my-cert-archive FILEBASE=live FILEEXT=.tar.gz upload_current_archive
## @endcode
upload_current_archive() {
  aws s3 cp "${FILEBASE}${FILEEXT}" "s3://${BUCKET}/${FILEBASE}${FILEEXT}"
}

## @fn upload_versioned_archive()
## @brief Upload the versioned archive object to S3.
## @details
## Copies the generated archive to a versioned S3 object path that includes the
## configured FILEVERSION suffix.
## @param BUCKET= S3 bucket name that stores certificate archives
## @param FILEBASE= archive base name without the extension
## @param FILEVERSION= version suffix appended to the archive name
## @param FILEEXT= archive extension to upload
## @retval 0 the versioned archive upload succeeded
## @retval 1 the versioned archive upload failed
## @par Examples
## @code
## BUCKET=my-cert-archive FILEBASE=live FILEVERSION=-20260325 FILEEXT=.tar.gz upload_versioned_archive
## @endcode
upload_versioned_archive() {
  aws s3 cp "${FILEBASE}${FILEEXT}" "s3://${BUCKET}/${FILEBASE}${FILEVERSION}${FILEEXT}"
}

## @fn upload_archive()
## @brief Upload both current and versioned archive objects to S3.
## @details
## Logs the upload step, uploads the current archive object, and then uploads
## the versioned archive object.
## @param BUCKET= S3 bucket name that stores certificate archives
## @param FILEBASE= archive base name without the extension
## @param FILEVERSION= version suffix appended to the archive name
## @param FILEEXT= archive extension to upload
## @retval 0 both uploads succeeded
## @retval 1 one of the uploads failed
## @par Examples
## @code
## BUCKET=my-cert-archive FILEBASE=live FILEVERSION=-20260325 FILEEXT=.tar.gz upload_archive
## @endcode
upload_archive() {
  log '8. push archive'
  upload_current_archive
  upload_versioned_archive
}

## @fn main()
## @brief Run the full certificate restore, renewal, and archive workflow.
## @details
## Initializes defaults, validates the environment, prepares the working
## directory, ensures required AWS resources exist, restores any saved state,
## ensures the Certbot account exists, runs Certbot work, generates combined
## certificate files, creates a new archive, and uploads the results.
## @param domains[] optional base domains to request or renew explicitly
## @retval 0 the full workflow completed successfully
## @retval 1 one of the workflow stages failed
## @par Examples
## @code
## BUCKET=my-cert-archive EMAIL=admin@example.com main
## BUCKET=my-cert-archive EMAIL=admin@example.com main example.com
## @endcode
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
