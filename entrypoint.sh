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

LE_CMD="certbot certonly --logs-dir - -w ${CHROOT_DIR} ${LE_EXTRA_ARGS}"

# Configure haproxy
HAPROXY_CMD="haproxy -W -db -f ${HAPROXY_CONFIG} ${HAPROXY_USER_PARAMS}"
HAPROXY_RESTART_CMD="kill -s HUP 1"
HAPROXY_CHECK_CONFIG_CMD="haproxy -f ${HAPROXY_CONFIG} -c"

# Make dirs and files
mkdir -p /deployment/letsencrypt/live
mkdir -p /deployment/certs

if [ "$DOMAINNAME" == 'localhost' ]; then
  # To maintain support for existing setups
  unset DOMAINNAME
fi

if [ -n "$DOMAINNAME" ]; then
  if [ -n "$DOMAINNAMES" ]; then
    DOMAINNAMES="$DOMAINNAME,$DOMAINNAMES"
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
  echo "monitor                 - Monitor the config file and certificates for changes and reload proxy"
  echo "remove                  - Remove and existing domain and its certificate"
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

    log_info "DOMAINNAMES: ${DOMAINNAMES}"
    log_info "HAPROXY_CONFIG: ${HAPROXY_CONFIG}"
    log_info "HAPROXY_CMD: ${HAPROXY_CMD}"
    log_info "HAPROXY_USER_PARAMS: ${HAPROXY_USER_PARAMS}"
    log_info "PROXY_LOGLEVEL: ${PROXY_LOGLEVEL}"
    log_info "LUA_PATH: ${LUA_PATH}"
    log_info "CERT_DIR: ${CERT_DIR}"
    log_info "LE_DIR: ${LE_DIR}"

    if check_proxy; then
    
      log_info "Starting crond"
      crond

      cert_init&
      
      log_info "Starting monitoring process"
      monitor&
      
      log_info "HAProxy starting"
      exec su haproxy -s /bin/sh -c "$HAPROXY_CMD $HAPROXY_START_OPTIONS"
      ret=$?

      if [ $ret -ne 0 ]; then
        log_info "HAProxy start failed"
      else
        log_info "HAProxy started with '$HAPROXY_CONFIG' config, pid = $(cat $HAPROXY_PID_FILE)."

      fi
    else
      log_error "Cannot start proxy until config file errors are resolved in '$HAPROXY_CONFIG'"
      exit 1
    fi
}

monitor() {
  while true; do
    log_info "Monitoring config file '$HAPROXY_CONFIG' and certs in '$CERT_DIR' for changes..."

    # Wait if config or certificates were changed, block this execution
    inotifywait -q -r --exclude '\.git/' -e modify,create,delete,move,move_self "$HAPROXY_CONFIG" "$CERT_DIR"
    log_info "Change detected..." &&
    sleep 5 &&
    restart
  done
}

restart() {

  log_info "HAProxy restart required..."

  if check_proxy; then
    log_info "Config is valid so requesting restart..."
    $HAPROXY_RESTART_CMD
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

  DOMAIN="${1}"
  RENEWED_LINEAGE="${LE_DIR}/live/${DOMAIN}"
  DOMAIN_FOLDER=$RENEWED_LINEAGE

  # Basic invalid DOMAIN check
  # Current ash shell on alpine needs regex to be quoted this isn't the case for newer bash shell versions hence the double check
  if [[ "$DOMAIN" =~ $IP_REGEX ]] || [[ "$DOMAIN" =~ "$IP_REGEX" ]]; then
    log_info "Domain is an IP address or simple hostname so ignoring cert request '$DOMAIN'"
    return 2
  fi

  if [ -e "${DOMAIN_FOLDER}" ]; then
    log_error "Domain '${DOMAIN}' already exists."
    return 3
  fi

  log_info "Adding domain \"${DOMAIN}\"..."

  DOMAIN_ARGS="-d ${DOMAIN}"
  for name in "${@}"; do
    if [ "${name}" != "${DOMAIN}" ]; then
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
   >&2 log_error "Failed to create haproxy.pem file for '$DOMAIN'"
   return $ret
  fi

  log_info "Added domain \"${DOMAIN}\"..."
}

renew() {
  if [ $# -lt 1 ]
  then
    echo 'Usage: renew <domain name> <alternative domain name>...'
    return 1
  fi

  DOMAIN="${1}"
  DOMAIN_FOLDER="${LE_DIR}/live/${DOMAIN}"

  if [ ! -d "${DOMAIN_FOLDER}" ]; then
    log_error "Domain ${DOMAIN} does not exist! Cannot renew it."
    return 6
  fi

  log_info "Renewing domain \"${DOMAIN}\"..."

  DOMAIN_ARGS="-d ${DOMAIN}"
  for name in "${@}"; do
    if [ "${name}" != "${DOMAIN}" ]; then
      DOMAIN_ARGS="${DOMAIN_ARGS} -d ${name}"
    fi
  done

  eval "$LE_CMD --force-renewal --deploy-hook \"/entrypoint.sh sync-haproxy\" --expand $DOMAIN_ARGS"

  LE_RESULT=$?

  if [ ${LE_RESULT} -ne 0 ]; then
   >&2 log_error "letsencrypt returned error code ${LE_RESULT}"
   return ${LE_RESULT}
  fi

  log_info "Renewed domain \"${DOMAIN}\"..."
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

  DOMAIN="${1}"
  DOMAIN_FOLDER="${LE_DIR}/live/${DOMAIN}"

  if [ ! -d "${DOMAIN_FOLDER}" ]; then
    log_error "Domain ${DOMAIN} does not exist!"
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

  DOMAIN=$1
  DOMAIN_LIVE_FOLDER="${LE_DIR}/live/${DOMAIN}"
  DOMAIN_ARCHIVE_FOLDER="${LE_DIR}/archive/${DOMAIN}"
  DOMAIN_RENEWAL_CONFIG="${LE_DIR}/renewal/${DOMAIN}.conf"

  log_info "Removing domain \"${DOMAIN}\"..."

  if [ ! -d "${DOMAIN_LIVE_FOLDER}" ]; then
    log_error "Domain ${1} does not exist! Cannot remove it."
    return 5
  fi

  rm -rf "${DOMAIN_LIVE_FOLDER}" || die "Failed to remove domain live directory ${DOMAIN_FOLDER}"
    rm -rf "${DOMAIN_ARCHIVE_FOLDER}" || die "Failed to remove domain archive directory ${DOMAIN_ARCHIVE_FOLDER}"
  rm -f "${DOMAIN_RENEWAL_CONFIG}" || die "Failed to remove domain renewal config ${DOMAIN_RENEWAL_CONFIG}"
  rm -f "${CERT_DIR}/${DOMAIN}" 2>/dev/null

  log_info "Removed domain \"${DOMAIN}\"..."
}

log_error() {
  >&2 echo "[ERROR][$(date +'%Y-%m-%d %T')] $*"
}

log_info() {
  echo "[INFO][$(date +'%Y-%m-%d %T')] $*"
}

die() {
    echo >&2 "$*"
    exit 1
}

cert_init() {
  log_info "cert_init...waiting 10s for haproxy to be ready"
  sleep 20
  log_info "Executing cert_init at $(date -R)"

  # Take checksum of haproxy certs so we can tell if we need to restart as inotify is not running yet
  CERT_SHA1=$(find ${CERT_DIR} -type f -print0 | xargs -0 sha1sum)

  # Iterate through domain names and check/create certificates
  # certbot certificates doesn't seem to work so check directories exist manually
  IFS_OLD=$IFS
  IFS=$','
  i=0
  for DOMAIN in $DOMAINNAMES; do
    i=$((i+1))
    if [ ! -d "${LE_DIR}/live/${DOMAIN}" ]; then
      log_info "Initialising certificate for '${DOMAIN}'..."
      rm -rf "${LE_DIR}/live/${DOMAIN}" 2>/dev/null
      add "${DOMAIN}"
    fi
    if [ $i -eq 1 ]; then
        log_info "Symlinking first domain to built in cert directory to take precedence over self signed cert"
        ln -sfT ${CERT_DIR}/${DOMAIN} /etc/haproxy/certs/00-cert
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

  CERT_SHA2=$(find ${CERT_DIR} -type f -print0 | xargs -0 sha1sum)

  if [ "$CERT_SHA1" != "$CERT_SHA2" ]; then
    log_info "HAProxy certs have been modified so restarting"
    restart
  fi
}

sync_haproxy() {
  if [ -z "$RENEWED_LINEAGE" ]; then
    log_error "sync-haproxy expect RENEWED_LINEAGE variable to be set"
    exit 1
  fi

  DOMAIN_FOLDER="$RENEWED_LINEAGE"
  DOMAIN=$(basename $RENEWED_LINEAGE)

  log_info "Updating haproxy cert chain for '$DOMAIN'"

  cat "${DOMAIN_FOLDER}/privkey.pem" \
   "${DOMAIN_FOLDER}/fullchain.pem" \
   > "/tmp/haproxy.pem"
   mv "/tmp/haproxy.pem" "${CERT_DIR}/${DOMAIN}"
}

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
elif [ "${CMD}" = "monitor" ]; then
  monitor
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
elif [ "${CMD}" = "print-pin" ]; then
  print_pin "${@}"
elif [ "${CMD}" = "sync-haproxy" ]; then
  sync_haproxy
else
  die "Unknown command: ${CMD}"
fi
