#!/bin/sh

patch_supervisord_conf() {

  if [ "$RUNONCE" -eq 0 ] ; then
    value="unexpected"
  else
    value="true"
  fi

  if ! grep -qE '^[[:space:]]*autorestart' "$SUPERVISORDCONF" ; then
    echo "autorestart=unexpected" >> "$SUPERVISORDCONF"
  fi

  if ! grep -qE '^[[:space:]]*startsecs' "$SUPERVISORDCONF" ; then
    echo "startsecs=1" >> "$SUPERVISORDCONF"
  fi

  sed -iEe "s/^([[:space:]]*autorestart[[:space:]]*=[[:space:]]*)(true|false|unexpected)(.*)\$/\\1${value}\\3/" "$SUPERVISORDCONF"

  sed -iEe "s/^([[:space:]]*startseds[[:space:]]*=[[:space:]]*)(true|false|unexpected)(.*)\$/\\1 0\\3/" "$SUPERVISORDCONF"


}

SUPERVISORDCONF="${SUPERVISORDCONF:-/etc/supervisord.conf}"
RUNONCE="${RUNONCE:-0}"

patch_supervisord_conf

supervisord -f "${SUPERVISORDCONF}"
