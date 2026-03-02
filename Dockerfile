FROM certbot/dns-route53:v5.3.1@sha256:41860a3d1190890d3fcd8edca34addad3736ce67368fe44f57f05a45842f02f6
COPY entrypoint.sh /entrypoint.sh
COPY requirements.txt /requirements.txt
ENV RUNNER="runner"

SHELL ["/bin/ash", "-o", "pipefail", "-c"]

RUN ( getent passwd "${RUNNER}" || adduser -D "${RUNNER}" ) ; pip install --no-cache-dir -r /requirements.txt

USER "${RUNNER}"
ENTRYPOINT ["/bin/sh", "/entrypoint.sh" ]
HEALTHCHECK NONE
