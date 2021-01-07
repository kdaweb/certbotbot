ARG IMAGE_BASE=certbot/dns-route53
ARG IMAGE_TAG=v1.7.0

FROM certbot/dns-route53:v1.7.0

ARG IMAGE_BASE
ARG IMAGE_TAG
ARG BOTOCORE_VERSION=1.14.7
ARG AWSCLI_VERSION=1.18.133
ARG AWSMFA_VERSION=0.0.12
ARG SUPERVISOR_VERSION=4.2.0-r0
ARG WORKDIR=/

RUN apk add --no-cache supervisor==$SUPERVISOR_VERSION && rm -rf /var/cache/apk/*
RUN pip3 install --no-cache-dir botocore==$BOTOCORE_VERSION awscli==$AWSCLI_VERSION aws-mfa==$AWSMFA_VERSION

WORKDIR $WORKDIR

# certbot (the real program) needs to run as root
# hadolint ignore=DL3002
USER root

ENTRYPOINT ["/bin/sh", "/entrypoint.sh" ]

COPY entrypoint.sh runner.sh supervisord.conf /
