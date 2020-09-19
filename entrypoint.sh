#!/bin/sh


generate_combined() {

  while [ -n "$1" ] ; do
    filename="$1"
    shift

    directory="${filename%/*}/"
    fullchain="${directory}fullchain.pem"
    privkey="${directory}privkey.pem"
    combined="${directory}combined.pem"

    cat "${fullchain}" "${privkey}" > "${combined}"

  done

}


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
if find /etc/letsencrypt/accounts/acme-v02.api.letsencrypt.org/directory/ -name regr.json | grep -q regr.json ; then
  certbot update_account --email "$EMAIL" --agree-tos --no-eff-email
else
  certbot register --email "$EMAIL" --agree-tos --no-eff-email
fi

echo 5. run certbot
date > timestamp.txt

if [ $# -eq 0 ] || [ "$1" = "" ] ; then
  echo "No domains passed -- only renewing existing domains"
  certbot renew
else
  for domain in "$@" ; do
    echo "Renewing '${domain}' and '*.${domain}'"
    # shellcheck disable=SC2086
    certbot certonly --dns-route53 -d "$domain" -d "*.${domain}" $DEBUGFLAGS
  done
fi

echo 6. make combined certificates

if [ -d "${WORKDIR}/live/" ] ; then
  find "${WORKDIR}/live/" -name fullchain.pem \
  | while read -r file ; do \
    generate_combined "$file" ;
  done
else
  echo "no certificates to combine"
fi

echo 7. create archive
tar -czvf "${FILEBASE}${FILEEXT}" .

echo 8. push archive
aws s3 cp "${FILEBASE}${FILEEXT}" "s3://${BUCKET}/${FILEBASE}${FILEEXT}"
aws s3 cp "${FILEBASE}${FILEEXT}" "s3://${BUCKET}/${FILEBASE}${FILEVERSION}${FILEEXT}"

echo Done.
