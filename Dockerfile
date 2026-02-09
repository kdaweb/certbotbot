FROM certbot/dns-route53:v5.3.0@sha256:0efaa29eed0e49dec850bcca1d4a68a19572f076cb2f910a5eb8210b2f4d8d89
COPY entrypoint.sh /entrypoint.sh
COPY requirements.txt /requirements.txt
ENV RUNNER="runner"

SHELL ["/bin/ash", "-o", "pipefail", "-c"]

RUN ( getent passwd "${RUNNER}" || adduser -D "${RUNNER}" ) ; pip install --no-cache-dir -r /requirements.txt

USER "${RUNNER}"
ENTRYPOINT ["/bin/sh", "/entrypoint.sh" ]
HEALTHCHECK NONE
