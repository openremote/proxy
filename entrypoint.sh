#!/bin/sh

# Regex for IP address or string without a '.'
IP_REGEX='(^([0-9a-fA-F]{0,4}:){1,7}[0-9a-fA-F]{0,4}$)|(^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$)|(^[^\.]+$)'

# Configure letsencrypt
LE_EXTRA_ARGS=""
if [ -n "${LE_EMAIL}" ]; then
  LE_EXTRA_ARGS="${LE_EXTRA_ARGS} --email ${LE_EMAIL}"
else
  LE_EXTRA_ARGS="${LE_EXTRA_ARGS} --register-unsafely-without-email"
fi
if [ -n "${LE_RSA_KEY_SIZE}" ]; then
  LE_EXTRA_ARGS="${LE_EXTRA_ARGS} --rsa-key-size ${LE_RSA_KEY_SIZE}"
fi

LE_CMD="certbot certonly -w ${CHROOT_DIR} ${LE_EXTRA_ARGS}"

# Configure haproxy
HAPROXY_CMD="haproxy -f ${HAPROXY_CONFIG} ${HAPROXY_USER_PARAMS} -D -p ${HAPROXY_PID_FILE}"
HAPROXY_START_OPTIONS="-st \$(cat \$HAPROXY_PID_FILE)"
HAPROXY_RESTART_OPTIONS="-sf \$(cat \$HAPROXY_PID_FILE) -x /var/run/haproxy.sock"
HAPROXY_CHECK_CONFIG_CMD="haproxy -f ${HAPROXY_CONFIG} -c"

INITIALISED=false

# Make dirs and files
mkdir -p /deployment/letsencrypt/live
mkdir -p /deployment/certs
touch /var/run/haproxy.pid

if [ "$DOMAINNAME" == 'localhost' ]; then
  # To maintain support for existing setups
  unset DOMAINNAME
fi

if [ -n "$DOMAINNAME" ]; then
  if [ -n "$DOMAINNAMES" ]; then
    DOMAINNAMES="$DOMAINNAMES,$DOMAINNAME"
  else
    DOMAINNAMES="$DOMAINNAME"
  fi
fi

print_help() {
  echo "Available commands:"
  echo ""
  echo "help                    - Show this help"
  echo "run                     - Run proxy in foreground and monitor config changes, executes check and cron-auto-renewal-init"
  echo "check                   - Check proxy configuration only"
  echo "list                    - List configured domains and their certificate's status"
  echo "add                     - Add a new domain and create a certificate for it"
  echo "renew                   - Renew the certificate for an existing domain. Allows to add additional domain names."
  echo "remove                  - Remove and existing domain and its certificate"
  echo "cron-auto-renewal       - Run the cron job automatically renewing all certificates"
  echo "cron-auto-renewal-init  - Obtain missing certificates, purge obsolete and automatically calls renew"
  echo "auto-renew              - Try to automatically renew all installed certificates"
  echo "print-pin               - Print the public key pin for a given domain for usage with HPKP"
  echo "sync-haproxy            - Deploy hook for certbot to synchronise haproxy cert chains"
}

check_proxy() {
    log_info "Checking HAProxy configuration: $HAPROXY_CONFIG"
    $HAPROXY_CHECK_CONFIG_CMD
    return $?
}

run_proxy() {
    if check_proxy; then
      log_info "HAProxy starting"
      eval "$HAPROXY_CMD $HAPROXY_START_OPTIONS"
      ret=$?

      if [ $ret -ne 0 ]; then
        log_info "HAProxy start failed"
      else
        log_info "HAProxy started with '$HAPROXY_CONFIG' config, pid = $(cat $HAPROXY_PID_FILE)."
        cron_auto_renewal_init
        INITIALISED=true
      fi
    else
      log_error "Cannot start proxy until config file errors are resolved in '$HAPROXY_CONFIG'"
    fi

    while true; do
      log_info "Monitoring config file '$HAPROXY_CONFIG' and certs in '$CERT_DIR' for changes..."

      # Wait if config or certificates were changed, block this execution
      inotifywait -q -r --exclude '\.git/' -e modify,create,delete,move,move_self "$HAPROXY_CONFIG" "$CERT_DIR" |
        while read events; do
            log_info "Change detected..."
            sleep 5
            restart
        done
    done
}

restart() {

  log_info "HAProxy restart requested..."

  if check_proxy; then
    PID=$(cat $HAPROXY_PID_FILE)
    if [ -z "$PID" ] || ! pgrep -P $PID > /dev/null; then
      log_info "HAProxy is not running so starting"
      eval "$HAPROXY_CMD $HAPROXY_START_OPTIONS"
    else
      log_info "HAProxy restarting"
      eval "$HAPROXY_CMD $HAPROXY_RESTART_OPTIONS"
    fi

    ret=$?

    if [ $ret -ne 0 ]; then
      log_info "HAProxy start/restart failed"
    fi
    log_info "HAProxy started/restarted with '$HAPROXY_CONFIG' config, pid = $(cat $HAPROXY_PID_FILE)."
  else
    log_info "HAProxy config invalid, not restarting..."
  fi
}

add() {
  if [ $# -lt 1 ]
  then
    echo 'Usage: add <domain name> <alternative domain name>...'
    return 1
  fi

  DOMAINNAME="${1}"
  RENEWED_LINEAGE="${LE_DIR}/live/${DOMAINNAME}"

  # Basic invalid DOMAINNAME check
  # Current ash shell on alpine needs regex to be quoted this isn't the case for newer bash shell versions hence the double check
  if [[ "$DOMAINNAME" =~ $IP_REGEX ]] || [[ "$DOMAINNAME" =~ "$IP_REGEX" ]]; then
    log_info "Domain is an IP address or simple hostname so ignoring cert request '$DOMAINNAME'"
    return 2
  fi

  if [ -e "${DOMAIN_FOLDER}" ]; then
    log_error "Domain '${DOMAINNAME}' already exists."
    return 3
  fi

  log_info "Adding domain \"${DOMAINNAME}\"..."

  DOMAIN_ARGS="-d ${DOMAINNAME}"
  for name in "${@}"; do
    if [ "${name}" != "${DOMAINNAME}" ]; then
      DOMAIN_ARGS="${DOMAIN_ARGS} -d ${name}"
    fi
  done

  eval "$LE_CMD $DOMAIN_ARGS"
  ret=$?

  if [ $ret -ne 0 ]; then
   >&2 log_error "Failed to generate certificate either haproxy configuration is incorrect or TLD not supported"
   return $ret
  fi

  sync_haproxy

  ret=$?

  if [ $ret -ne 0 ]; then
   >&2 log_error "Failed to create haproxy.pem file for '$DOMAINNAME'"
   return $ret
  fi

  log_info "Added domain \"${DOMAINNAME}\"..."
}

renew() {
  if [ $# -lt 1 ]
  then
    echo 'Usage: renew <domain name> <alternative domain name>...'
    return 1
  fi

  DOMAINNAME="${1}"
  DOMAIN_FOLDER="${LE_DIR}/live/${DOMAINNAME}"

  if [ ! -d "${DOMAIN_FOLDER}" ]; then
    log_error "Domain ${DOMAINNAME} does not exist! Cannot renew it."
    return 6
  fi

  log_info "Renewing domain \"${DOMAINNAME}\"..."

  DOMAIN_ARGS="-d ${DOMAINNAME}"
  for name in "${@}"; do
    if [ "${name}" != "${DOMAINNAME}" ]; then
      DOMAIN_ARGS="${DOMAIN_ARGS} -d ${name}"
    fi
  done

  eval "$LE_CMD --force-renewal --deploy-hook \"/entrypoint.sh sync-haproxy\" --expand $DOMAIN_ARGS"

  LE_RESULT=$?

  if [ ${LE_RESULT} -ne 0 ]; then
   >&2 log_error "letsencrypt returned error code ${LE_RESULT}"
   return ${LE_RESULT}
  fi

  log_info "Renewed domain \"${DOMAINNAME}\"..."
}

auto_renew() {
  log_info "Executing auto renew at $(date -R)"
  certbot renew --deploy-hook "/entrypoint.sh sync-haproxy"
}

list() {
  eval "$LE_CMD certificates"
}

print_pin() {
  if [ $# -lt 1 ]
  then
    echo 'Usage: print-pin <domain name>'
    return 1
  fi

  DOMAINNAME="${1}"
  DOMAIN_FOLDER="${LE_DIR}/live/${DOMAINNAME}"

  if [ ! -d "${DOMAIN_FOLDER}" ]; then
    log_error "Domain ${DOMAINNAME} does not exist!"
    return 6
  fi

  pin_sha256=$(openssl rsa -in "${DOMAIN_FOLDER}/privkey.pem" -outform der -pubout 2> /dev/null | openssl dgst -sha256 -binary | openssl enc -base64)

  echo
  echo "pin-sha256: ${pin_sha256}"
  echo
  echo "Example usage in HTTP header:"
  echo "Public-Key-Pins: pin-sha256=""${pin_sha256}""; max-age=5184000; includeSubdomains;"
  echo
  echo "CAUTION: Make sure to also add another pin for a backup key!"
}

remove() {
  if [ $# -lt 1 ]
  then
    echo 'Usage: remove <domain name>'
    return 1
  fi

  DOMAINNAME=$1
  DOMAIN_LIVE_FOLDER="${LE_DIR}/live/${DOMAINNAME}"
  DOMAIN_ARCHIVE_FOLDER="${LE_DIR}/archive/${DOMAINNAME}"
  DOMAIN_RENEWAL_CONFIG="${LE_DIR}/renewal/${DOMAINNAME}.conf"

  log_info "Removing domain \"${DOMAINNAME}\"..."

  if [ ! -d "${DOMAIN_LIVE_FOLDER}" ]; then
    log_error "Domain ${1} does not exist! Cannot remove it."
    return 5
  fi

  rm -rf "${DOMAIN_LIVE_FOLDER}" || die "Failed to remove domain live directory ${DOMAIN_FOLDER}"
  rm -rf "${DOMAIN_ARCHIVE_FOLDER}" || die "Failed to remove domain archive directory ${DOMAIN_ARCHIVE_FOLDER}"
  rm -f "${DOMAIN_RENEWAL_CONFIG}" || die "Failed to remove domain renewal config ${DOMAIN_RENEWAL_CONFIG}"
  rm -f "${CERT_DIR}/${DOMAINNAME}.pem" 2>/dev/null

  log_info "Removed domain \"${DOMAINNAME}\"..."
}

log_error() {
  if [ -n "${LOGFILE}" ]
  then
    if [ "$*" ]; then echo "[ERROR][$(date +'%Y-%m-%d %T')] $*" >> "${LOGFILE}";
    else echo; fi
    >&2 echo "[ERROR][$(date +'%Y-%m-%d %T')] $*"
  else
    echo "[ERROR][$(date +'%Y-%m-%d %T')] $*"
  fi
}

log_info() {
  if [ -n "${LOGFILE}" ]
  then
    if [ "$*" ]; then echo "[INFO][$(date +'%Y-%m-%d %T')] $*" >> "${LOGFILE}";
    else echo; fi
    >&2 echo "[INFO][$(date +'%Y-%m-%d %T')] $*"
  else
    echo "[INFO][$(date +'%Y-%m-%d %T')] $*"
  fi
}

die() {
    echo >&2 "$*"
    exit 1
}

cron_auto_renewal_init() {
  log_info "Executing cron_auto_renewal_init at $(date -R)"

  # Start crond if not already started
  if ! pgrep crond > /dev/null; then
    log_info "Starting crond"
    crond 1>/dev/null 2>/dev/null
  fi

  # Init cron job to renew certs
  cron_auto_renewal

  # Iterate through domain names and check/create certificates
  # certbot certificates doesn't seem to work so check directories exist manually
  IFS_OLD=$IFS
  IFS=$','
  for DOMAINNAME in $DOMAINNAMES; do
    if [ ! -d "${LE_DIR}/live/${DOMAINNAME}" ]; then
      log_info "Initialising certificate for '${DOMAINNAME}'..."
      rm -rf "${LE_DIR}/live/${DOMAINNAME}" 2>/dev/null
      add "${DOMAINNAME}"
    fi
  done
  IFS=$IFS_OLD

  # Remove any stale/obsolete certificates and check haproxy full chain file exists
  DIRS=$(ls -1d ${LE_DIR}/live/* 2>/dev/null)
  IFS_OLD=$IFS
  IFS=$'\n'
  for d in $DIRS; do
    # Need additional check as ash shell ls -d includes files
    if [ ! -d "$d" ]; then
      continue
    fi
    CERT=$(basename $d)
    if [[ "$DOMAINNAMES" != "$CERT"* ]] && [[ "$DOMAINNAMES" != *",$CERT"* ]]; then
      log_info "Removing obsolete certificate for '$CERT'"
      remove "$CERT"
    else
      RENEWED_LINEAGE="$LE_DIR/live/$CERT"
      sync_haproxy
    fi
  done
  IFS=$IFS_OLD

  # Remove any stale haproxy cert chains
  FILES=$(ls -1 ${CERT_DIR}/* 2>/dev/null)
  IFS_OLD=$IFS
  IFS=$'\n'
  for f in $FILES; do
    CERT=$(basename $f)
    if [ ! -d "${LE_DIR}/live/${CERT}" ]; then
      log_info "Removing obsolete haproxy certificate chain for '$CERT'"
      rm -f $f
    fi
  done
  IFS=$IFS_OLD

  # Run renew in case any existing certs need updating
  auto_renew
}

cron_auto_renewal() {
  # Add daily cron script to renew certs as required
  printf "#!/bin/sh\ncertbot renew --deploy-hook \"/entrypoint.sh sync-haproxy\"\n" > /etc/periodic/daily/certbot-renew
  chmod +x /etc/periodic/daily/certbot-renew
}

sync_haproxy() {
  if [ -z "$RENEWED_LINEAGE" ]; then
    log_error "sync-haproxy expect RENEWED_LINEAGE variable to be set"
    exit 1
  fi

  DOMAIN_FOLDER="$RENEWED_LINEAGE"
  DOMAINNAME=$(basename $RENEWED_LINEAGE)

  log_info "Updating haproxy cert chain for '$DOMAINNAME'"

  cat "${DOMAIN_FOLDER}/privkey.pem" \
   "${DOMAIN_FOLDER}/fullchain.pem" \
   > "/tmp/haproxy.pem"
   mv "/tmp/haproxy.pem" "${CERT_DIR}/${DOMAINNAME}"
}

log_info "DOMAINNAMES: ${DOMAINNAMES}"
log_info "HAPROXY_CONFIG: ${HAPROXY_CONFIG}"
log_info "HAPROXY_CMD: ${HAPROXY_CMD}"
log_info "HAPROXY_USER_PARAMS: ${HAPROXY_USER_PARAMS}"
log_info "PROXY_LOGLEVEL: ${PROXY_LOGLEVEL}"
log_info "LUA_PATH: ${LUA_PATH}"
log_info "CERT_DIR: ${CERT_DIR}"
log_info "LE_DIR: ${LE_DIR}"
log_info "CHROOT_DIR: ${CHROOT_DIR}"

if [ $# -eq 0 ]
then
  print_help
  exit 0
fi

CMD="${1}"
shift

if [ "${CMD}" = "run"  ]; then
  run_proxy "${@}"
elif [ "${CMD}" = "restart" ]; then
  restart
elif [ "${CMD}" = "check" ]; then
  check_proxy "${@}"
elif [ "${CMD}" = "add" ]; then
  add "${@}"
elif [ "${CMD}" = "list" ]; then
  list "${@}"
elif [ "${CMD}" = "remove" ]; then
  remove "${@}"
elif [ "${CMD}" = "renew" ]; then
  renew "${@}"
elif [ "${CMD}" = "auto-renew" ]; then
  auto_renew "${@}"
elif [ "${CMD}" = "help" ]; then
  print_help "${@}"
elif [ "${CMD}" = "cron-auto-renewal" ]; then
  cron_auto_renewal
elif [ "${CMD}" = "print-pin" ]; then
  print_pin "${@}"
elif [ "${CMD}" = "cron-auto-renewal-init" ]; then
  cron_auto_renewal_init
elif [ "${CMD}" = "sync-haproxy" ]; then
  sync_haproxy
else
  die "Unknown command: ${CMD}"
fi
