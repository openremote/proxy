#!/usr/bin/env bash
#

set -euf -o pipefail

# ************** USAGE **************
#
# This is an example hook that can be used with Certbot.
#
# Example usage (with certbot-auto and this hook file saved in /root/):
#
#   sudo ./certbot-auto -d example.org -d www.example.org -a manual -i nginx --preferred-challenges dns \
#   --manual-auth-hook "/root/certbot.default.sh auth" --manual-cleanup-hook "/root/certbot.default.sh cleanup"
#
# This hook requires configuration, continue reading.
#
# ************** CONFIGURATION **************
#
# PROXY_DNS_PROVIDER and PROXY_DNS_PROVIDER_CREDENTIALS must be supplied as environment variables.
#
# PROXY_DNS_PROVIDER:
#   Set this to whatever DNS host your domain is using:
#
#       route53 cloudflare cloudns cloudxns digitalocean
#       dnsimple dnsmadeeasy dnspark dnspod easydns gandi
#       glesys godaddy linode luadns memset namecheap namesilo
#       nsone ovh pointhq powerdns rackspace rage4 softlayer
#       transip vultr yandex zonomi
#
#   The full list is in Lexicon's README.
#
# PROXY_DNS_PROVIDER_CREDENTIALS:
#   Lexicon needs to know how to authenticate to your DNS Host.
#   This will vary from DNS host to host.
#   To figure out which flags to use, you can look at the Lexicon help.
#   For example, for help with Cloudflare:
#
#       lexicon cloudflare -h
#
# Example cloudflare credentials: "--auth-username=MY_USERNAME" "--auth-token=MY_API_KEY"

if [ -z $PROXY_DNS_PROVIDER ]; then
  echo "PROXY_DNS_PROVIDER is not set"
  exit 1
fi
if [ -z $PROXY_DNS_PROVIDER_CREDENTIALS ]; then
  echo "PROXY_DNS_PROVIDER_CREDENTIALS is not set"
  exit 1
fi

#
# PROVIDER_UPDATE_DELAY:
#   How many seconds to wait after updating your DNS records. This may be required,
#   depending on how slow your DNS host is to begin serving new DNS records after updating
#   them via the API. 30 seconds is a safe default, but some providers can be very slow
#   (e.g. Linode).
#
#   Defaults to 30 seconds.
#
if [ -z $PROXY_DNS_PROVIDER_UPDATE_DELAY ]; then
  PROXY_DNS_PROVIDER_UPDATE_DELAY=30
fi

# To be invoked via Certbot's --manual-auth-hook
function auth {
    lexicon --resolve-zone-name "${PROXY_DNS_PROVIDER}" "${PROXY_DNS_PROVIDER_CREDENTIALS[@]}" \
    create "${CERTBOT_DOMAIN}" TXT --name "_acme-challenge.${CERTBOT_DOMAIN}" --content "${CERTBOT_VALIDATION}"

    sleep "${PROXY_DNS_PROVIDER_UPDATE_DELAY}"
}

# To be invoked via Certbot's --manual-cleanup-hook
function cleanup {
    lexicon --resolve-zone-name "${PROXY_DNS_PROVIDER}" "${PROXY_DNS_PROVIDER_CREDENTIALS[@]}" \
    delete "${CERTBOT_DOMAIN}" TXT --name "_acme-challenge.${CERTBOT_DOMAIN}" --content "${CERTBOT_VALIDATION}"
}

HANDLER=$1; shift;
if [ -n "$(type -t $HANDLER)" ] && [ "$(type -t $HANDLER)" = function ]; then
  $HANDLER "$@"
fi