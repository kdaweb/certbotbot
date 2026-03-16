FROM certbot/dns-route53:v5.4.0@sha256:bf4ae7177ca8e3cd72569d450e90cbcf04ffafe4f762d05806b5ad79ea387fd1
COPY entrypoint.sh /entrypoint.sh
COPY requirements.txt /requirements.txt
ENV RUNNER="runner"

SHELL ["/bin/ash", "-o", "pipefail", "-c"]

RUN ( getent passwd "${RUNNER}" || adduser -D "${RUNNER}" ) ; pip install --no-cache-dir -r /requirements.txt

USER "${RUNNER}"
ENTRYPOINT ["/bin/sh", "/entrypoint.sh" ]
HEALTHCHECK NONE
