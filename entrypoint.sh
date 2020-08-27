#!/bin/sh

WORKDIR="${WORKDIR:-/etc/letsencrypt}"
BUCKET="${BUCKET:?Error: no bucket set}"
EMAIL="${EMAIL:?Error: no email address set}"

FILEBASE="${FILEBASE:-live}"
FILEEXT="${FILEEXT:-.tar.gz}"

FILEVERSION="${FILEVERSION:--$(date +%Y%m%d)-}"

ls ~/.aws

echo Certbotbot

echo 1. prep
if [ ! -d "${WORKDIR}" ] ; then
  mkdir -p "${WORKDIR}"
fi

if ! aws s3 ls "${BUCKET}" > /dev/null  2>&1 ; then
  aws s3 mb "s3://${BUCKET}" > /dev/null
fi

cd "${WORKDIR}" || exit 1

echo 2. pull archive

cd "${WORKDIR}" || exit 1

if aws s3 cp "s3://${BUCKET}/${FILEBASE}${FILEEXT}" "${WORKDIR}" > /dev/null 2>&1 /dev/null ; then
  echo "File doesn't exist"
fi

echo 3. decompress archive
if [ -e "${FILEBASE}${FILEEXT}" ] ; then
  tar -xzvf "${FILEBASE}${FILEEXT}"
fi

echo 4. update registration
certbot register -m "$EMAIL" --agree-tos --no-eff-email --update-registration

echo 5. run certbot
date > timestamp.txt
for domain in "$@" ; do
  certbot -d "$domain" -d "*.${domain}"
done

echo 6. make combined certificates

echo 7. create archive
tar -czvf "${FILEBASE}${FILEEXT}" .

echo 8. push archive
aws s3 cp "${FILEBASE}${FILEEXT}" "s3://${BUCKET}/${FILEBASE}${FILEEXT}"
aws s3 cp "${FILEBASE}${FILEEXT}" "s3://${BUCKET}/${FILEBASE}${FILEVERSION}${FILEEXT}"

echo Done.
