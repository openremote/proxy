# HAProxy docker image
[![Docker Image](https://github.com/openremote/proxy/actions/workflows/proxy.yml/badge.svg)](https://github.com/openremote/proxy/actions/workflows/proxy.yml)

HAProxy docker image with Lets Encrypt SSL auto renewal using certbot with built in support for wildcard certificates using AWS Route53.

## Paths
* `/deployment/letsencrypt` - Certbot config directory where generated certificates are stored
* `/etc/haproxy/haproxy.cfg` - Default location of haproxy configuration file
* `/etc/haproxy/certs` - Static (non certbot) certificates includes self-signed and any other static certificates should be volume mapped into this folder
* `/var/log/*` - Location of log files (all are symlinked to stdout)

## Environment variables
* `DOMAINNAME` - IANA TLD subdomain for which a Lets Encrypt certificate should be requested 
* `DOMAINNAMES` - Comma separated list of IANA TLD subdomain names for which Lets Encrypt certificates should be 
requested (this is a multi-value alternative to DOMAINNAME)
* `HAPROXY_USER_PARAMS` - Additional arguments that should be passed to the haproxy process during startup
* `HAPROXY_CONFIG` - Location of HAProxy config file (default: `/etc/haproxy/haproxy.cfg`)
* `PROXY_LOGLEVEL` - Log level for HAProxy (default: `notice`)
* `MANAGER_HOST` - Hostname of OpenRemote Manager (default: `manager`)
* `MANAGER_WEB_PORT` - Web server port of OpenRemote Manager (default `8080`)
* `MANAGER_MQTT_PORT` - MQTT broker port of OpenRemote Manager (default `1883`)
* `MANAGER_PATH_PREFIX` - The path prefix used for OpenRemote Manager HTTP requests (default not set, example: `/openremote`)
* `KEYCLOAK_HOST` - Hostname of the Keycloak server (default: `keycloak`)
* `KEYCLOAK_PORT` - Web server port of Keycloak server (default `8080`)
* `KEYCLOAK_PATH_PREFIX` - The path prefix used for Keycloak HTTP requests (default not set, example: `/keycloak`)
* `LOGFILE` - Location of log file for entrypoint script to write to in addition to stdout (default `none`)
* `AWS_ROUTE53_ROLE` - AWS Route53 Role ARN to be assumed when trying to generate wildcard certificates using Route53 DNS zone, specifically for cross account updates (default `none`)
* `LE_EXTRA_ARGS` - Can be used to add additional arguments to the certbot command (default `none`)
* `SISH_HOST` - Defines the destination hostname for forwarding requests that begin with `gw-` used in combination with `SISH_PORT`
* `SISH_PORT` - Defined the destination port for forwarding requests tha begin with `gw-` used in combination with `SISH_HOST`
* `MQTT_RATE_LIMIT` - Enable rate limiting for MQTT connections (connections/s)

## Custom certificate format
Any custom certificate volume mapped into `/etc/haproxy/certs` should be in PEM format and must include the full certificate chain and the private key, i.e.:
```
 cat privkey.pem cert.pem chain.pem > ssl-certs.pem
```

See `haproxy` SSL cert [documentation](https://www.haproxy.com/blog/haproxy-ssl-termination/#enabling-ssl-with-haproxy).

## Edge gateway tunnelling using SISH
The built in `haproxy.cfg` has support for forwarding requsts beginning with `gw-` to `https://SISH_HOST:SISH_PORT` just define these environment variables to enable this.
