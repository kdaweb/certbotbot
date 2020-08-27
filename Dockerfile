FROM certbot/dns-route53:v1.7.0

RUN pip install awscli==1.18.126 aws-mfa==0.0.12

COPY entrypoint.sh /entrypoint.sh

# hadolint ignore=DL3002
USER root

ENTRYPOINT ["/bin/sh", "/entrypoint.sh" ]
