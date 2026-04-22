#!/usr/bin/env bats

## @file entrypoint.bats
## @brief Unit tests for the Certbotbot entrypoint workflow helpers.
## @details
## This Bats test file exercises high-value helper behavior in `entrypoint.sh`
## without invoking the full production workflow.  The tests intentionally focus
## on bounded helper behavior that can be validated in a temporary filesystem,
## such as argument parsing, derived artifact cleanup, and deletion flow.
##
## The entrypoint script is sourced with `ENTRYPOINT_RUN_MAIN=false` so the test
## process can call individual helpers directly.  Failure paths that terminate
## via `fail()` are executed in subprocesses to avoid aborting the Bats shell.
##
## These tests prefer explicit filesystem setup over broad mocking.  External
## commands such as `certbot` are stubbed only where the helper contract depends
## on them directly.

setup() {
  export TEST_DIR
  TEST_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"
  export PROJECT_ROOT
  PROJECT_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

  TEST_ROOT="${BATS_TEST_TMPDIR}/test-root"
  WORKDIR="${TEST_ROOT}/etc-letsencrypt"
  export TEST_ROOT WORKDIR

  mkdir -p "${WORKDIR}/live" "${WORKDIR}/archive" \
    "${WORKDIR}/renewal" "${WORKDIR}/combined"

  export ENTRYPOINT_RUN_MAIN=false
  # shellcheck source=/dev/null
  source "${PROJECT_ROOT}/entrypoint.sh"
  set +eu
}


teardown() {
  rm -rf "${TEST_ROOT}"
}


## @fn make_lineage_tree()
## @brief Create a minimal fake Certbot lineage tree for one test domain.
## @details
## This helper builds the standard directory and file layout used by the
## deletion helpers.  Callers may request exact, suffixed, or unrelated test
## artifacts by passing the desired lineage base name.
## @param lineage_name The lineage or suffixed lineage name to create.
## @retval 0 Test fixtures created successfully.
make_lineage_tree() {
  lineage_name="$1"

  mkdir -p "${WORKDIR}/live/${lineage_name}" \
    "${WORKDIR}/archive/${lineage_name}"
  : > "${WORKDIR}/live/${lineage_name}/combined.pem"
  : > "${WORKDIR}/renewal/${lineage_name}.conf"
  : > "${WORKDIR}/combined/${lineage_name}.pem"
}


## @fn load_entrypoint_in_subshell()
## @brief Run entrypoint helpers in an isolated shell for failure-path tests.
## @details
## Some helpers intentionally call `fail()`, which exits the shell.  This
## helper returns a compact shell snippet that sources the entrypoint with main
## disabled, initializes defaults, and then runs the caller-supplied command.
## @param shell_code Shell code to execute after sourcing the entrypoint.
## @returns Writes the composed shell snippet to standard output.
load_entrypoint_in_subshell() {
  shell_code="$1"
  cat <<EOF_SUBSHELL
ENTRYPOINT_RUN_MAIN=false . "${PROJECT_ROOT}/entrypoint.sh"
set +eu
init_defaults
${shell_code}
EOF_SUBSHELL
}


@test "parse_args records requested positional domains" {
  init_defaults

  parse_args example.com example.org

  [ "${DELETE_MODE}" = "false" ]
  [ "${REQUESTED_DOMAINS}" = "example.com
example.org" ]
}


@test "parse_args records delete-mode domains" {
  init_defaults

  parse_args --delete-domain example.com --delete-domain example.org

  [ "${DELETE_MODE}" = "true" ]
  [ "${DELETE_DOMAINS}" = "example.com
example.org" ]
}


@test "parse_args rejects mixing delete mode with positional domains" {
  run sh -c "$(load_entrypoint_in_subshell 'parse_args --delete-domain example.com example.org')"

  [ "${status}" -eq 1 ]
  [[ "${output}" == *"--delete-domain cannot be combined with positional domains"* ]]
}


@test "delete_generated_artifacts_for_domain removes only exact derived PEM artifacts" {
  mkdir -p "${WORKDIR}/live/example.com" "${WORKDIR}/live/example.com-0001"
  : > "${WORKDIR}/live/example.com/combined.pem"
  : > "${WORKDIR}/live/example.com-0001/combined.pem"
  : > "${WORKDIR}/combined/example.com.pem"
  : > "${WORKDIR}/combined/example.com-0001.pem"

  delete_generated_artifacts_for_domain "example.com"

  [ ! -e "${WORKDIR}/live/example.com/combined.pem" ]
  [ ! -e "${WORKDIR}/combined/example.com.pem" ]
  [ -e "${WORKDIR}/live/example.com-0001/combined.pem" ]
  [ -e "${WORKDIR}/combined/example.com-0001.pem" ]
}


@test "delete_certbot_leftovers_for_domain removes exact and suffixed artifacts" {
  make_lineage_tree "example.com"
  make_lineage_tree "example.com-0001"
  make_lineage_tree "example.com-0002"
  make_lineage_tree "example.com-backup"
  make_lineage_tree "other.example.com"

  delete_certbot_leftovers_for_domain "example.com"

  [ ! -e "${WORKDIR}/live/example.com" ]
  [ ! -e "${WORKDIR}/archive/example.com" ]
  [ ! -e "${WORKDIR}/renewal/example.com.conf" ]
  [ ! -e "${WORKDIR}/combined/example.com.pem" ]

  [ ! -e "${WORKDIR}/live/example.com-0001" ]
  [ ! -e "${WORKDIR}/archive/example.com-0001" ]
  [ ! -e "${WORKDIR}/renewal/example.com-0001.conf" ]
  [ ! -e "${WORKDIR}/combined/example.com-0001.pem" ]

  [ ! -e "${WORKDIR}/live/example.com-0002" ]
  [ ! -e "${WORKDIR}/archive/example.com-0002" ]
  [ ! -e "${WORKDIR}/renewal/example.com-0002.conf" ]
  [ ! -e "${WORKDIR}/combined/example.com-0002.pem" ]

  [ -e "${WORKDIR}/live/example.com-backup" ]
  [ -e "${WORKDIR}/archive/example.com-backup" ]
  [ -e "${WORKDIR}/renewal/example.com-backup.conf" ]
  [ -e "${WORKDIR}/combined/example.com-backup.pem" ]

  [ -e "${WORKDIR}/live/other.example.com" ]
  [ -e "${WORKDIR}/archive/other.example.com" ]
  [ -e "${WORKDIR}/renewal/other.example.com.conf" ]
  [ -e "${WORKDIR}/combined/other.example.com.pem" ]
}


@test "delete_certbot_domain invokes certbot delete and then removes leftovers" {
  STUB_BIN="${TEST_ROOT}/bin"
  CERTBOT_LOG="${TEST_ROOT}/certbot.log"
  mkdir -p "${STUB_BIN}"
  export PATH="${STUB_BIN}:${PATH}"
  export CERTBOT_LOG

  cat > "${STUB_BIN}/certbot" <<'EOF_CERTBOT'
#!/bin/sh
printf '%s\n' "$*" >> "${CERTBOT_LOG}"
exit 0
EOF_CERTBOT
  chmod +x "${STUB_BIN}/certbot"

  make_lineage_tree "example.com"
  make_lineage_tree "example.com-0001"

  delete_certbot_domain "example.com"

  run cat "${CERTBOT_LOG}"
  [ "${status}" -eq 0 ]
  [ "${output}" = "delete --cert-name example.com --non-interactive" ]

  [ ! -e "${WORKDIR}/live/example.com" ]
  [ ! -e "${WORKDIR}/archive/example.com" ]
  [ ! -e "${WORKDIR}/renewal/example.com.conf" ]
  [ ! -e "${WORKDIR}/combined/example.com.pem" ]

  [ ! -e "${WORKDIR}/live/example.com-0001" ]
  [ ! -e "${WORKDIR}/archive/example.com-0001" ]
  [ ! -e "${WORKDIR}/renewal/example.com-0001.conf" ]
  [ ! -e "${WORKDIR}/combined/example.com-0001.pem" ]
}
