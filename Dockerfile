# -----------------------------------------------------------------------------------------------
#
# HAProxy image with certbot for certificate generation and renewal
#
# -----------------------------------------------------------------------------------------------
FROM haproxy:2.9-alpine
LABEL maintainer="support@openremote.io"

USER root

ARG DOMAINNAME
ENV DOMAINNAME=${DOMAINNAME}

ARG DOMAINNAMES
ENV DOMAINNAMES=${DOMAINNAMES}

ENV TERM=xterm

ARG HAPROXY_USER_PARAMS
ENV HAPROXY_USER_PARAMS=${HAPROXY_USER_PARAMS}

ARG HAPROXY_CONFIG=/etc/haproxy/haproxy.cfg
ENV HAPROXY_CONFIG=${HAPROXY_CONFIG}

ARG HTTP_PORT=80
ENV HTTP_PORT=${HTTP_PORT}

ARG HTTPS_PORT=443
ENV HTTPS_PORT=${HTTPS_PORT}

ARG HTTPS_FORWARDED_PORT=%[dst_port]
ENV HTTPS_FORWARDED_PORT=${HTTPS_FORWARDED_PORT}

ARG NAMESERVER=127.0.0.11:53
ENV NAMESERVER=${NAMESERVER}

ARG PROXY_LOGLEVEL=notice
ENV PROXY_LOGLEVEL=${PROXY_LOGLEVEL}

ARG MANAGER_HOST=manager
ENV MANAGER_HOST=${MANAGER_HOST}

ARG MANAGER_WEB_PORT=8080
ENV MANAGER_WEB_PORT=${MANAGER_WEB_PORT}

ARG MANAGER_MQTT_PORT=1883
ENV MANAGER_MQTT_PORT=${MANAGER_MQTT_PORT}

ARG KEYCLOAK_HOST=keycloak
ENV KEYCLOAK_HOST=${KEYCLOAK_HOST}

ARG KEYCLOAK_PORT=8080
ENV KEYCLOAK_PORT=${KEYCLOAK_PORT}

ARG LOGFILE=none
ENV LOGFILE=${LOGFILE}

ENV CERT_DIR=/deployment/certs
ENV LE_DIR=/deployment/letsencrypt
ENV CHROOT_DIR=/etc/haproxy/webroot

# Install certbot and Route53 DNS plugin
RUN apk update \
    && apk add --no-cache certbot curl inotify-tools openssl py-pip tar \
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

COPY haproxy.cfg /etc/haproxy/haproxy.cfg
COPY haproxy-edge-terminated-tls.cfg /etc/haproxy/haproxy-edge-terminated-tls.cfg
COPY certs /etc/haproxy/certs

COPY cli.ini /root/.config/letsencrypt/
COPY entrypoint.sh /
RUN chmod +x /entrypoint.sh

HEALTHCHECK --interval=5s --timeout=3s --start-period=5s --retries=10 CMD curl --fail --silent "http://127.0.0.1:${HTTP_PORT}/docker-health" || exit 1

RUN chown -R haproxy:haproxy /etc/haproxy

ENTRYPOINT ["/entrypoint.sh"]
CMD ["run"]
