# certbotbot

There's a project made by the Electronic Frontier Foundation (EFF) which functions as an ACME (Automated Certificate Management Environment) client called "Certbot." Certbot is an excellent tool for automating the registration and renewal of TLS / SSL certificates in conjunction with the LetsEncrypt project. However, what Certbot lacks is the infrastructure and functionality needed to distribute the keys and certificates that are generated and signed by LetsEncrypt.

This is not a failing of the Certbot project -- it's outside of its core purpose. This project -- originally a quick hack to solve a temporary problem -- was built to pick up where the Certbot project ended. That is, certbotbot creates, manages, and distributes archives of certificates and keys.

## Overview

The certbotbot is designed to be a thin, fast wrapper around Certbot. Here's how it works:

1. Pull down an archive -- a gzipped tarball -- from an AWS S3 bucket.
2. Decompress the archive.
3. Use Certbot to generate or renew certificates.
4. Create an archive containing all of the certificates, both new and old.
5. Push the archive back to the AWS S3 bucket.

Note: there is currently no locking involved between when an archive is pulled, processed, and pushed back. It's entirely possible for two processes to run at the same time with one overwriting the output of the other. That's bad.

## Requirements

This project is highly AWS-centric. AWS Route53 is used to satisfy ownership challenges and AWS S3 is used to store archives of certificates. Therefore, the requirements are:

- Docker
- AWS credentials

## Under the Hood

The certbotbot is a Docker image that, when instantiated as a container, runs a shell script.

The certbotbot takes two required parameters:

- `BUCKET`: the bucket from which to pull and push archives
- `EMAIL`: the email address associated with the account (for notification purposes)

By sending a different value for `EMAIL`, one may update the account associated with the certificates to use the new address. Therefore, `EMAIL` is always required, even when not creating a new account.

## Configuring certbotbot

The certbotbot script (which runs the certbotbot container) accepts configuration from two sources:

1. Environment variables (e.g., `bucket=foobar ./certbotbot.sh`)
2. An `.env` file that contains the variables to set

There is a sample `.env` file.

The name of the `.env` file to use may be set with the `envfile` environment variable (e.g., `envfile=env.prod ./certbotbot.sh`).

## Authenticating to AWS

For authentication purposes, one may:

- **Option 1**: run certbotbot on an AWS EC2 instance that has access via an IAM Instance Role
- **Option 2**: mount a credentials file by running `docker` with `-v /home/user/.aws/credentials:/root/.aws/credentials`
- **Option 3**: pass environment variables with the appropriate AWS IAM access keys (i.e., `-e AWS_ACCESS_KEY_ID=... -e AWS_SECRET_ACCESS_KEY=...`)

## Updating Local Certificates

One may update the certificates on the local system (i.e., the system running certbotbot) by bind-mounting the desired local directory to the container (i.e., `-v /etc/letsencrypt:/etc/letsencrypt`).

## Generating New Certificates

### DNS Challenges (via AWS Route53)

If one passes a domain name (e.g., `example.com`) to certbotbot, the container will attempt to generate a new private key for the domain and have that certificate signed by LetsEncrypt. Specifically, certbotbot uses AWS Route53 (currently) to prove ownership of the domain (i.e., a DNS-01 challenge).

### Wildcards and Subdomains

Moreover, the certificate will be signed for both the value passed to certbotbot, and also a wildcard for the subdomains of the passed domain. So, if one passes `example.com` then the certificate will be signed for both `example.com` and `*.example.com`.

### Generating Combined Files

When certbotbot runs, in addition to the `fullchain.pem` and `privkey.pem` files, an additional file named `combined.pem` is generated which includes both the private key as well as the fully-chained certificate. This helps with tools such as HAProxy which look for single files containing both components.

## Deleting Certificate

If you pass `--delete-domain` as the first argument, the next argument can be the domain to delete.  This will delete both the domain name and the wildcard subdomains.  So, if you use `--delete-domain domain.tld` then it will delete certificates for `domain.tld` and `*.domain.tld` together.

### Archival Storage (S3)

The archives of certificates are stored on AWS S3 at the bucket provided by the `BUCKET` environment variable.

If that bucket does not exist, it will be created (i.e., `aws s3 mb`). The archive stored in the bucket, by default, is `live.tar.gz`. Additionally, when an archive is pushed to the S3 bucket, a backup of the archive will be stored at `live-%Y%m%d.tar.gz`, where `%Y%m%d` is the four digits of the year, two digits for the month, and two digits for the day (i.e., the output of `date +%Y%m%d`).

## Optional KMS Key Bootstrap

certbotbot can optionally create an AWS KMS key alias for future encryption support. This iteration does **not** change how archives are stored or processed. The archive workflow remains plaintext and behaves exactly as before unless you later enable a separate encryption feature.

### Purpose

The KMS bootstrap support exists to prepare the environment ahead of a later encryption rollout. It allows the script to ensure that a customer-managed symmetric KMS key exists, without yet using that key to encrypt or decrypt the certificate archive.

### Default Behavior

By default, this feature is disabled:

- `AUTO_CREATE_KMS_KEY_IF_MISSING=false`

That default is intentional. Existing installations should continue to run exactly as they do today when a new image is deployed via `:latest`, even if the runtime environment has not been granted any KMS permissions.

### Environment Variables

The following variables are used by the optional KMS bootstrap logic:

- `AUTO_CREATE_KMS_KEY_IF_MISSING`
  - Default: `false`
  - When set to `true`, certbotbot will check whether `KMS_KEY_ID` exists and, if not, will attempt to create it.
- `KMS_KEY_ID`
  - No default value is required when auto-creation is disabled.
  - When auto-creation is enabled, this should be an alias such as `alias/certbotbot`.
- `AWS_REGION`
  - Optional, but strongly recommended when using KMS.
  - The key and alias are created in this Region.
- `KMS_KEY_DESCRIPTION`
  - Optional
  - Default: `certbotbot managed key`

### How It Works

When `AUTO_CREATE_KMS_KEY_IF_MISSING=true`, certbotbot will:

1. Check whether the alias identified by `KMS_KEY_ID` already exists.
2. If it exists, continue normally.
3. If it does not exist, create a new customer-managed **symmetric** KMS key.
4. Create the requested alias and point it at that new key.
5. Continue with the normal certbotbot workflow.

This bootstrap step is intended to be additive and preparatory only. It does not alter the certificate archive format or S3 object names.

### IAM Permissions

If you enable automatic KMS key creation, the AWS identity used by the container will need KMS permissions in addition to the S3 and Route53 permissions already required by certbotbot.

At a minimum, the runtime identity must be allowed to perform actions such as:

- `kms:DescribeKey`
- `kms:CreateKey`
- `kms:CreateAlias`

Depending on how your environment is configured, additional permissions may be required.

If the runtime identity does not have KMS permissions and `AUTO_CREATE_KMS_KEY_IF_MISSING=true`, the bootstrap step will fail.

### Compatibility Notes

With the default configuration:

- no KMS calls are made
- `KMS_KEY_ID` is not required
- existing deployments behave exactly as before

This means a drop-in update via `:latest` will not start creating AWS KMS resources unless you explicitly opt in.

### Example

```shell
AUTO_CREATE_KMS_KEY_IF_MISSING=true \
KMS_KEY_ID=alias/certbotbot \
AWS_REGION=us-east-1 \
BUCKET=mycertbucket \
EMAIL=user@domain.tld \
./certbotbot.sh example.com
```

In that example, certbotbot will first ensure that `alias/certbotbot` exists in AWS KMS, and will then proceed with its normal certificate management workflow.

## Renewing Certificates

If no domains are passed to certbotbot, then the certificates in the pulled archive are scanned for renewal; any certificate that is sufficiently close to expiration will be renewed, subject to the same DNS-01 challenge required for generating the certificate.

## Sample Runs

### Renew Local Certificates

The following is one way to run certbotbot to renew certificates and update the archive:

```shell
docker run \
  --rm \
  --interactive \
  --tty \
  --env BUCKET=mycertbucket \
  --env EMAIL=user@domain.tld \
  --volume "${HOME}/.aws/credentials:/root/.aws/credentials" \
  kdaweb/certbotbot
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
  kdaweb/certbotbot domain.tld
```

### Delete a Certificate

This will delete `domain.tld` and `*.domain.tld`

```shell
docker run \
  --rm \
  --interactive \
  --tty \
  --env BUCKET=mycertbucket \
  --env EMAIL=user@domain.tld \
  kdaweb/certbotbot --delete-domain domain.tld
```
