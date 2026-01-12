FROM certbot/dns-route53:v5.2.2@sha256:06377d4d9c2779539aab4247f83e2f4a9ef1133bc831390570e5747e057c4419
COPY entrypoint.sh /entrypoint.sh
COPY requirements.txt /requirements.txt
ENV RUNNER="runner"

SHELL ["/bin/ash", "-o", "pipefail", "-c"]

RUN ( getent passwd "${RUNNER}" || adduser -D "${RUNNER}" ) ; pip install --no-cache-dir -r /requirements.txt

USER "${RUNNER}"
ENTRYPOINT ["/bin/sh", "/entrypoint.sh" ]
HEALTHCHECK NONE
