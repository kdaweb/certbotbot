#!/usr/bin/env bash

tag="${tag:-certbotbot}"
bucket="${bucket:-certbotbotbucket}"
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
