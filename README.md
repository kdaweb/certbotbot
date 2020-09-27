# certbotbot

There's a project made by the Electronic Frontier Foundation (EFF) which functions as an ACME (Automated Certificate Management Environment) client called "Certbot."  Certbot is an excellent tool for automating the registration and renewal of TLS / SSL certificates in conjunction with the LetsEncrypt project.

However, what Certbot lacks is the infrastructure and functionality needed to distribute the keys and certificates that are generated and signed by LetsEncrypt.  This is not a failing of the Certbot project -- it's outside of its core purpose.

This project -- originally a quick hack to solve a temporary problem -- was built to pick up where the Certbot project ended.  That is, the certbotbot creates, manages, and distributes archives of certificates and keys.

## Overview

The certbotbot is designed to be a thin, fast wrapper around Certbot.  Here's how it works

1. pull down an archive -- a gzipped tarball -- from an AWS S3 bucket
2. decompress the archive
3. use the Certbot to generate or renew certificates
4. create an archive containing all of the certificates, both new and old
5. push the archive back to the AWS S3 bucket

Note: there is (currently) no locking involved between when an archive is pulled, processed, and pushed back.  It's entirely possible for two processes to run at the same time with one overwriting the output of the other.  That's bad.

## Requirements

This project is highly AWS-centric.  AWS Route53 is used to satisfy ownership challenges and AWS S3 is used to store archives of certificates.  Therefore, the requirements are:

* Docker
* AWS credentials

## Under the Hood

The certbotbot is a Docker image that, when intantiated as a container, runs a shell script.

The certbotbot takes two required parameters:

* BUCKET: the bucket from which to pull and push archives
* EMAIL: the email address associated with the account (for notification purposes)

By sending a different value for EMAIL, one may update the account associated with the certificates to use the new address.  Therefore, EMAIL is always required, even when not creating a new account.

For authentication purposes, one may:

* **Option 1**: run the certbotbot on an AWS EC2 instance that has access via an IAM Instance Role
* **Option 2**: mount a credentials file by running `docker` with `-v /home/user/.aws/credentials:/root/.aws/credentials`
* **Option 3**: pass environment variables with the appropriate AWS IAM access keys (i.e., `-e AWS_ACCESS_KEY_ID=... -e AWS_SECRET_ACCESS_KEY=...`

### Updating Local Certificates

One may update the certificates on the local system (i.e., the system running certbotbot) by bind-mounting the desired local directory to the container (i.e., `-v /etc/letsencrypt:/etc/letsencrypt`).

### Generating New Certificates

#### DNS Challenges (via AWS Route53)

If one passes a domain name (e.g., `example.com`) to certbotbot, the container will attempt to generate a new private key for the domain and have that certificate signed by LetsEncrypt.  Specifically, certbotbot uses AWS Route53 (currently) to prove ownership of the domain (i.e., a DNS-01 challenge).

#### Wildcards and Subdomains

Moreover, the certificate will be signed for both the value passed to certbotbot, but also a wildcard for the subdomains of the passed domain.  So, if one passes `example.com` then the certificate will be signed for both `example.com` and `*.example.com`.

#### Generating Combined Files

When the certbotbot runs, in addition to the `fullchain.pem` and `privkey.pem` files, an additional file named `combined.pem` which includes both the private key as well as the fullly-chained certificate.  This helps with tools such as HAProxy which look for single files containing both components.

#### Archival Storage (S3)

The archives of certificates are stored on AWS S3 at the bucket provided by the `BUCKET` environment variable.  If that bucket does not exist, it will be created (i.e., `aws s3 mb`).

The archive stored in the bucket, by default, is `live.tar.gz`.

Additionally, when an archive is pushed to the S3 bucket, a backup of the archive will be stored at `live-%Y%m%d.tar.gz` will be created where `%Y%m%d` is the four digits of the year, two digits for the month, and two digits for the day (i.e., the output of `date +%Y%m%d`).

### Renewing Certificates

If no domains are passed to certbotbot, then the certificates in the pulled archive are scanned for renewal; any certificate that is sufficiently close to expiration will be renewed, subject to the same DNS-01 challenge required for generating the certificate.

## Sample Runs

### Renew Local Certificates

The following is one way to run the certbotbot to renew certificates and update the archive:

```shell
docker run \
  --rm \
  --interactive \
  --tty \
  --env BUCKET=mycertbucket \
  --env EMAIL=user@domain.tld \
  --volume "${HOME}/.aws/credentials:/root/.aws/credentials" \
  kdaweb/certbotbot

service apache2 reload
```

### Generate a New Certificate

This will generate a new certificate for `domain.tld` and `*.domain.tld`:

```shell
docker run \
  --rm \
  --interactive \
  --tty \
  --env BUCKET=mycertbucket \
  --env EMAIL=user@domain.tld \
  kdaweb/certbotbot
  domain.tld
```
