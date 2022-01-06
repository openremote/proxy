# -----------------------------------------------------------------------------------------------
# HAProxy image with certbot for certificate generation and renewal
#
# -----------------------------------------------------------------------------------------------
FROM haproxy:2.5.0-alpine3.15
MAINTAINER support@openremote.io

USER root

# Configure rsyslog to log to stdout
RUN set -exo pipefail \
    && apk add --no-cache \
        rsyslog \
    && mkdir -p /etc/rsyslog.d \
    && touch /var/log/haproxy.log \
    && ln -sf /dev/stdout /var/log/haproxy.log

# Install certbot
RUN apk add --no-cache certbot inotify-tools tar curl openssl && \
    rm -f /var/cache/apk/*

ARG ACME_PLUGIN_VERSION=0.1.1
ARG DOMAINNAME
ARG LOCAL_CERT_FILE
ENV DOMAINNAME ${DOMAINNAME:-localhost}
ENV LOCAL_CERT_FILE ${LOCAL_CERT_FILE}
ENV TERM xterm
ENV HAPROXY_CONFIG ${HAPROXY_CONFIG:-}
ENV PROXY_LOGLEVEL ${PROXY_LOGLEVEL:-notice}
ENV MANAGER_HOST ${MANAGER_HOST:-manager}
ENV MANAGER_WEB_PORT ${MANAGER_WEB_PORT:-8080}
ENV MANAGER_MQTT_PORT ${MANAGER_MQTT_PORT:-1883}
ENV KEYCLOAK_HOST ${KEYCLOAK_HOST:-keycloak}
ENV KEYCLOAK_PORT ${KEYCLOAK_PORT:-8080}
ENV LOGFILE ${PROXY_LOGFILE:-/var/log/proxy.log}


RUN mkdir /etc/haproxy && cd /etc/haproxy \
    && curl -sSL https://github.com/janeczku/haproxy-acme-validation-plugin/archive/refs/tags/${ACME_PLUGIN_VERSION}.tar.gz -o acme-plugin.tar.gz \
    && tar xvf acme-plugin.tar.gz --strip-components=1 --no-anchored acme-http01-webroot.lua \
    && rm *.tar.gz && cd
	
RUN apk del tar curl && \
    rm -f /var/cache/apk/*

RUN mkdir /opt/selfsigned

ADD rsyslog.conf /etc/rsyslog.conf
ADD haproxy-init.cfg /etc/haproxy/haproxy-init.cfg
ADD haproxy.cfg /etc/haproxy/haproxy.cfg
ADD selfsigned /opt/selfsigned

ADD cli.ini /root/.config/letsencrypt/
ADD entrypoint.sh /
ADD cron.sh /
RUN chmod +x /entrypoint.sh
RUN chmod +x /cron.sh

EXPOSE 80 443 8883

HEALTHCHECK --interval=3s --timeout=3s --start-period=2s --retries=30 CMD curl --fail --silent http://localhost:80 || exit 1

ENTRYPOINT ["/entrypoint.sh"]
CMD ["run"]
