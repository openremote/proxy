# -----------------------------------------------------------------------------------------------
#
# HAProxy image with certbot for certificate generation and renewal
#
# -----------------------------------------------------------------------------------------------
FROM haproxy:2.6.6-alpine
MAINTAINER support@openremote.io

USER root

ARG ACME_PLUGIN_VERSION=0.1.1
ENV DOMAINNAME ${DOMAINNAME}
ENV DOMAINNAMES ${DOMAINNAMES}
ENV TERM xterm
ENV HAPROXY_PID_FILE /var/run/haproxy.pid
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


# Symlink logs to stdout
RUN set -exo pipefail \
    && touch /var/log/haproxy.log \
    && ln -sf /dev/stdout /var/log/haproxy.log \
	&& mkdir -p /var/log/letsencrypt \
	&& touch /var/log/letsencrypt/letsencrypt.log \
	&& touch $HAPROXY_PID_FILE

# Can't symlink letsencrypt log as python has issues using stream without readline
#	&& ln -sf /dev/stdout /var/log/letsencrypt/letsencrypt.log

# Install certbot
RUN apk update \
    && apk add --no-cache certbot inotify-tools tar curl openssl && \
    rm -f /var/cache/apk/*

# Add ACME LUA plugin
RUN mkdir -p /etc/haproxy/lua && mkdir -p ${CHROOT_DIR} && mkdir -p ${CERT_DIR} && mkdir -p ${LE_DIR} && cd /etc/haproxy/lua \
    && curl -sSL https://github.com/janeczku/haproxy-acme-validation-plugin/archive/refs/tags/${ACME_PLUGIN_VERSION}.tar.gz -o acme-plugin.tar.gz \
    && tar xvf acme-plugin.tar.gz --strip-components=1 --no-anchored acme-http01-webroot.lua \
    && rm *.tar.gz && cd
	
RUN apk del tar && \
    rm -f /var/cache/apk/*

ADD haproxy.cfg /etc/haproxy/haproxy.cfg
ADD certs /etc/haproxy/certs

ADD cli.ini /root/.config/letsencrypt/
ADD entrypoint.sh /
RUN chmod +x /entrypoint.sh

HEALTHCHECK --interval=3s --timeout=3s --start-period=2s --retries=30 CMD curl --fail --silent http://127.0.0.1:80 || exit 1

ENTRYPOINT ["/entrypoint.sh"]
CMD ["run"]
