#!/usr/bin/env bash

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
