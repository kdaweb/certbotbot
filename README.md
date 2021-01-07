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

## Running certbotbot as a daemon

By default -- and original intent -- the certbotbot was designed to run once,
fetch certificates, register / renew, create "combined" files, and push a new
archive back up to the cloud, then exit.  However, there may be times when it
is desirable to have the certbotbot run repeatedly, such as every X hours.  The
certbotbot can do that, too.

The certbotbot now uses supervisord to call the script to do the work.  By
default, it will run once (actually, up to 3 times if the first 2 invocations
fail), and then terminate.  However, it one sets the `RUNONCE` environment
variable to 1 (for `false`), then it will run normally, wait for `RUNDELAY`
seconds, and then run again on a loop.  By default, `RUNDELAY` is `86400`
(one day).

If the certbotbot is set to run multiple times AND an invocation fails,
then it will wait `RETRYWAIT` seconds before retrying; be default,
`RETRYWAIT` is `60` (one minute).

## Miscellanous Flags

### SKIPUPDATEACCOUNT

If the `SKIPUPDATEACCOUNT` environment variable is 0 (True, the default),
then if the LetsEncrypt account in question already exists, it won't be
updated; if set to a non-zero integer (i.e., False), then if the account
exists, it will be updated.  This can be problematic in some cases, hence
the default not to update the account.

### UPDATECERTS

If the `UPDATECERTS` environment variable is 0 (True, the default), then
the certbotbot will attempt to renew the certificates from the archive
and push the updates back up to the cloud.  If set to a non-zero integer
(i.e., False), then the certbotbot will pull the archive and will make
sure the combined certificates are constructed properly, but it will
neither attempt to renew the certificates nor push anything back to
the cloud.
