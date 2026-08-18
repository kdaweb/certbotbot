FROM certbot/dns-route53:v5.7.0@sha256:b066c7c499bf028800562b0b5d963bf6ad23efdf4e395ab7415b53d44c0b1133
COPY entrypoint.sh /entrypoint.sh
COPY requirements.txt /requirements.txt
ENV RUNNER="runner"

SHELL ["/bin/ash", "-o", "pipefail", "-c"]

RUN ( getent passwd "${RUNNER}" || adduser -D "${RUNNER}" ) ; pip install --no-cache-dir -r /requirements.txt

USER "${RUNNER}"
ENTRYPOINT ["/bin/sh", "/entrypoint.sh" ]
HEALTHCHECK NONE
