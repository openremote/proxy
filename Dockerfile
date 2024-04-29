# -----------------------------------------------------------------------------------------------
#
# HAProxy image with certbot for certificate generation and renewal
#
# -----------------------------------------------------------------------------------------------
FROM haproxy:2.9-alpine
MAINTAINER support@openremote.io

USER root

ENV DOMAINNAME ${DOMAINNAME}
ENV DOMAINNAMES ${DOMAINNAMES}
ENV TERM xterm
ENV HAPROXY_USER_PARAMS ${HAPROXY_USER_PARAMS}
ENV HAPROXY_CONFIG ${HAPROXY_CONFIG:-/etc/haproxy/haproxy.cfg}
ENV PROXY_LOGLEVEL ${PROXY_LOGLEVEL:-notice}
ENV MANAGER_HOST ${MANAGER_HOST:-manager}
ENV MANAGER_WEB_PORT ${MANAGER_WEB_PORT:-8080}
ENV MANAGER_MQTT_PORT ${MANAGER_MQTT_PORT:-1883}
ENV KEYCLOAK_HOST ${KEYCLOAK_HOST:-keycloak}
ENV KEYCLOAK_PORT ${KEYCLOAK_PORT:-8080}
ENV LOGFILE ${LOGFILE}
ENV CERT_DIR /deployment/certs
ENV LE_DIR /deployment/letsencrypt
ENV CHROOT_DIR /etc/haproxy/webroot

# Install certbot and Route53 DNS plugin
RUN apk update \
    && apk add --no-cache certbot py-pip inotify-tools tar curl openssl \
    && rm -f /var/cache/apk/* \
    && pip install certbot-dns-route53 --break-system-packages

# Add ACME LUA plugin
ADD acme-plugin.tar.gz /etc/haproxy/lua/

RUN mkdir -p ${CHROOT_DIR} \
    && mkdir -p ${CERT_DIR} \
    && mkdir -p /var/log/letsencrypt \
    && mkdir -p ${LE_DIR} && chown haproxy:haproxy ${LE_DIR} \
    && mkdir -p /etc/letsencrypt \
    && mkdir -p /var/lib/letsencrypt \
    && touch /etc/periodic/daily/cert-renew \
    && printf "#!/bin/sh\n/entrypoint.sh auto-renew\n" > /etc/periodic/daily/cert-renew \
    && chmod +x /etc/periodic/daily/cert-renew \
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

HEALTHCHECK --interval=5s --timeout=3s --start-period=5s --retries=10 CMD curl --fail --silent http://127.0.0.1/docker-health || exit 1

RUN chown -R haproxy:haproxy /etc/haproxy

ENTRYPOINT ["/entrypoint.sh"]
CMD ["run"]
