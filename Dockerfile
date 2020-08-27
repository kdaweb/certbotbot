FROM certbot/dns-route53

RUN pip install awscli aws-mfa -U 

COPY entrypoint.sh /entrypoint.sh
USER root
ENTRYPOINT ["/bin/sh", "/entrypoint.sh" ]
