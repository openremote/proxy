# -----------------------------------------------------------------------------------------------
#
# HAProxy image with certbot for certificate generation and renewal
#
# -----------------------------------------------------------------------------------------------
FROM haproxy:2.7.8-alpine
MAINTAINER support@openremote.io

USER root

ARG ACME_PLUGIN_VERSION=0.1.1
ENV DOMAINNAME ${DOMAINNAME}
ENV DOMAINNAMES ${DOMAINNAMES}
ENV TERM xterm
ENV HAPROXY_USER_PARAMS ${HAPROXY_USER_PARAMS}
ENV HAPROXY_CONFIG ${HAPROXY_CONFIG:-/etc/haproxy/haproxy.cfg}
ENV PROXY_LOGLEVEL ${PROXY_LOGLEVEL:-info}
ENV MANAGER_HOST ${MANAGER_HOST:-manager}
ENV MANAGER_WEB_PORT ${MANAGER_WEB_PORT:-8080}
ENV MANAGER_MQTT_PORT ${MANAGER_MQTT_PORT:-1883}
ENV KEYCLOAK_HOST ${KEYCLOAK_HOST:-keycloak}
ENV KEYCLOAK_PORT ${KEYCLOAK_PORT:-8080}
ENV LOGFILE ${LOGFILE}
ENV CERT_DIR /deployment/certs
ENV LE_DIR /deployment/letsencrypt
ENV CHROOT_DIR /etc/haproxy/webroot

# Install certbot
RUN apk update \
    && apk add --no-cache certbot inotify-tools tar curl openssl \
    && rm -f /var/cache/apk/*

# Add ACME LUA plugin
ADD acme-plugin.tar.gz /etc/haproxy/lua/

RUN mkdir -p ${CHROOT_DIR} \
    && mkdir -p ${CERT_DIR} \
    && mkdir -p /var/log/letsencrypt \
    && mkdir -p ${LE_DIR} && chown haproxy:haproxy ${LE_DIR} \
    && mkdir -p /etc/letsencrypt \
    && mkdir -p /var/lib/letsencrypt \
    && touch /etc/periodic/daily/certbot-renew \
    && printf "#!/bin/sh\ncertbot renew --deploy-hook \"/entrypoint.sh sync-haproxy\"\n" > /etc/periodic/daily/certbot-renew \
    && chmod +x /etc/periodic/daily/certbot-renew \
    && chown -R haproxy:haproxy /etc/letsencrypt \
    && chown -R haproxy:haproxy /etc/haproxy \
    && chown -R haproxy:haproxy /var/lib/letsencrypt \
    && chown -R haproxy:haproxy /var/log/letsencrypt \
    && chown -R haproxy:haproxy ${CHROOT_DIR} \
    && chown -R haproxy:haproxy ${CERT_DIR}
	
RUN apk del tar && \
    rm -f /var/cache/apk/*

ADD haproxy.cfg /etc/haproxy/haproxy.cfg
ADD certs /etc/haproxy/certs

ADD cli.ini /root/.config/letsencrypt/
ADD entrypoint.sh /
RUN chmod +x /entrypoint.sh

HEALTHCHECK --interval=60s --timeout=3s --start-period=5s --retries=2 CMD curl --fail --silent http://127.0.0.1/docker-health || exit 1

RUN chown -R haproxy:haproxy /etc/haproxy

ENTRYPOINT ["/entrypoint.sh"]
CMD ["run"]
