#!/usr/bin/env bash

set -euo pipefail

envfile="${envfile:-.env}"

set -a
# shellcheck disable=SC1090
[[ -f "$envfile" ]] && source "$envfile"
set +a

tag="${tag:-kdaweb/certbotbot}"
bucket="${bucket:-thisismybucket}"
email="${email?Missing email address}"
flags="${flags:-}"

docker run \
  --rm \
  -it \
  -e "BUCKET=${bucket}" \
	-e "EMAIL=${email}" \
	-e "DEBUGFLAGS=${flags}" \
  -v "${HOME}/.aws/credentials:/root/.aws/credentials" \
	"${tag}" \
  "$@"
