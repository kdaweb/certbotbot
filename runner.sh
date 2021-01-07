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


pull_certs() {

  echo fetch archive

  cd "${WORKDIR}" || exit 1

  if aws s3 cp "s3://${BUCKET}/${FILEBASE}${FILEEXT}" .  ; then
    echo "File downloaded"
  else
    echo "File doesn't exist"
  fi

  echo decompress archive

  if [ -f "${FILEBASE}${FILEEXT}" ] ; then
    tar -xzf "${FILEBASE}${FILEEXT}"
  else
    echo "archive does not exist."
  fi
}


push_certs() {

  if [ "${UPDATECERTS}" -eq 0 ] ; then

    echo create archive
    find live/ -maxdepth 1 -mindepth 1 -type d | sed 's|^live/||' | sort
    tar -czf "${FILEBASE}${FILEEXT}" --exclude "${FILEBASE}${FILEEXT}" .

    echo push archive
    aws s3 cp "${FILEBASE}${FILEEXT}" "s3://${BUCKET}/${FILEBASE}${FILEEXT}"
    aws s3 cp "${FILEBASE}${FILEEXT}" "s3://${BUCKET}/${FILEBASE}${FILEVERSION}${FILEEXT}"
  fi
}


renew_certs() {

  if [ "${UPDATECERTS}" -eq 0 ] ; then

    echo update registration

    if find "accounts/acme-v02.api.letsencrypt.org/directory/" -name regr.json | grep -q regr.json ; then
      if [ "${SKIPUPDATEACCOUNT}" -eq 0 ] ; then
        echo "updating account"
        certbot update_account --email "$EMAIL" --agree-tos --no-eff-email
      fi
    else
      echo "registering account"
      certbot register --email "$EMAIL" --agree-tos --no-eff-email
    fi

    echo run certbot
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
  fi

  echo make combined certificates

  if [ -d "${WORKDIR}/live/" ] ; then
    find "${WORKDIR}/live/" -name fullchain.pem \
    | while read -r file ; do \
      generate_combined "$file" ;
    done
  else
    echo "no certificates to combine"
  fi
}

WORKDIR="${WORKDIR:-/etc/letsencrypt}"
BUCKET="${BUCKET:?Error: no bucket set}"
EMAIL="${EMAIL:?Error: no email address set}"

SUPERVISORDCONF="${SUPERVISORDCONF:-/etc/supervisord.conf}"

FILEBASE="${FILEBASE:-live}"
FILEEXT="${FILEEXT:-.tar.gz}"

FILEVERSION="${FILEVERSION:--$(date +%Y%m%d)}"

RUNONCE="${RUNONCE:-0}"
RUNDELAY="${RUNONCE:-86400}"
RETRYWAIT="${RETRYWAIT:-60}"

UPDATECERTS="${UPDATECERTS:-0}"
SKIPUPDATEACCOUNT="${SKIPUPDATEACCOUNT:-0}"

echo Certbotbot

echo prep
if [ ! -d "${WORKDIR}" ] ; then
  mkdir -p "${WORKDIR}"
fi

if ! aws s3 ls "${BUCKET}" > /dev/null  2>&1 ; then
  aws s3 mb "s3://${BUCKET}" > /dev/null
fi

cd "${WORKDIR}" || exit 1

if pull_certs \
&& renew_certs "$@" \
&& push_certs ; then

  echo "Success."
  if [ "$RUNONCE" -ne 0 ] && [ "$RUNDELAY" -ge 0 ] ; then
    echo "Waiting for $RUNDELAY seconds"
    sleep "${RUNDELAY}"
  fi

  echo Done.
  exit 0

else

  echo "Something failed."
  if [ "$RUNONCE" -ne 0 ] && [ "$RETRYWAIT" -ge 0 ] ; then
    echo "Waiting for $RETRYWAIT seconds"
    sleep "${RETRYWAIT}"
  fi

  echo Done.
  exit 1
fi
