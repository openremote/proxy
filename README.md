# HAProxy docker image

[![Docker Image](https://github.com/openremote/proxy/actions/workflows/proxy.yml/badge.svg)](https://github.com/openremote/proxy/actions/workflows/proxy.yml)

HAProxy docker image with Lets Encrypt SSL auto renewal using certbot with built in support for wildcard certificates using AWS Route53.

## Environment variables

* `CERT_DIR` - Automatically generated full chain PEM certificates directory (live reload of HA Proxy on changes) \[default: `/deployment/certs`\]
* `CUSTOM_CERT_DIR` - Additional custom full chain PEM certificates directory loaded by HAProxy but not managed by certbot \[default: `/data/proxy/certs`\]
* `LE_DIR` - Certbot config directory where generated certificates are stored \[default: `/deployment/letsencrypt`\]
* \[DEPRECATED\] `DOMAINNAME` - IANA TLD subdomain for which a Lets Encrypt certificate should be requested
* `DOMAINNAMES` - Comma separated list of IANA TLD subdomain names for which Lets Encrypt certificates should be 
requested; wildcard domains should be specified with an '*' (e.g. `*.example.com)
* `HAPROXY_USER_PARAMS` - Additional arguments that should be passed to the haproxy process during startup
* `HAPROXY_CONFIG` - Location of HAProxy config file (live reload of HA Proxy on changes) \[default: `/etc/haproxy/haproxy.cfg`\]
* `PROXY_LOGLEVEL` - Log level for HAProxy \[default: `notice`\]
* `HTTP_PORT` - The container binds to this port for handling HTTP requests \[default: `80`\]
* `HTTPS_PORT` - The container binds to this port for handling HTTPS requests \[default: `443`\]
* `HTTPS_FORWARDED_PORT` - The port set in the `X-Forwarded-Port` header of requests sent to the Manager/Keycloak \[default: `%[dst_port]` this is the HAProxy port\]
* `NAMESERVER` - The nameserver hostname and port used for resolving the Manager/Keycloak hosts \[default: `127.0.0.11:53`\]
* `MANAGER_HOST` - Hostname of OpenRemote Manager \[default: `manager`\]
* `MANAGER_WEB_PORT` - Web server port of OpenRemote Manager \[default: `8080`\]
* `MANAGER_MQTT_PORT` - MQTT broker port of OpenRemote Manager \[default: `1883`\]
* `MANAGER_PATH_PREFIX` - The path prefix used for OpenRemote Manager HTTP requests (e.g. `/openremote`) \[default: not set\]
* `KEYCLOAK_HOST` - Hostname of the Keycloak server \[default: `keycloak`\]
* `KEYCLOAK_PORT` - Web server port of Keycloak server \[default: `8080`\]
* `KEYCLOAK_PATH_PREFIX` - The path prefix used for Keycloak HTTP requests (e.g. `/keycloak`) \[default: not set\]
* `LOGFILE` - Location of log file for entrypoint script to write to in addition to stdout \[default: `none`\]
* `AWS_ROUTE53_ROLE` - AWS Route53 Role ARN to be assumed when trying to generate wildcard certificates using Route53 DNS zone, specifically for cross account updates \[default: not set\]
* `LE_EXTRA_ARGS` - Can be used to add additional arguments to the certbot command \[default: not set\]
* `DISABLE_ACME` - Disable certbot/ACME initialization and renewal logic in the entrypoint; useful when TLS is terminated externally such as with ACM on an AWS load balancer (accepted true values: `1`, `true`, `yes`, `on`)
* `SISH_HOST` - Defines the destination hostname for forwarding requests that begin with `gw-` used in combination with `SISH_PORT`
* `SISH_PORT` - Defined the destination port for forwarding requests tha begin with `gw-` used in combination with `SISH_HOST`
* `MQTT_RATE_LIMIT` - Enable rate limiting for MQTT connections (connections/s)

## Custom certificate format

Any custom certificate volume mapped into `/etc/haproxy/certs` should be in PEM format and must include the full certificate chain and the private key, i.e.:
```shell
cat privkey.pem cert.pem chain.pem > ssl-certs.pem
```

See `haproxy` SSL cert [documentation](https://www.haproxy.com/blog/haproxy-ssl-termination/#enabling-ssl-with-haproxy).

## Edge gateway tunnelling using SISH

The built in `haproxy.cfg` has support for forwarding requsts beginning with `gw-` to `https://SISH_HOST:SISH_PORT` just define these environment variables to enable this.

## Kubernetes

When running the proxy in Kubernetes make sure to set the `HTTP_PORT` and `HTTPS_PORT` environment variables to a non-privileged port (> 1024).
If you use an Ingress, reconfigure the `HTTPS_FORWARDED_PORT` to the HTTPS port of your Ingress (443).

You will also need to set the `NAMESERVER` environment variable to the cluster DNS (usually 10.96.0.10:53).
The cluster DNS typically only resolves fully qualified hostnames, so make sure to set these using the `MANAGER_HOST` and `KEYCLOAK_HOST` environment variables (e.g. `manager.default.svc.cluster.local`).

## Edge-Terminated TLS

If TLS is terminated upstream before traffic reaches this pod, for example by an AWS NLB with ACM, an ALB, an ingress controller, or another reverse proxy, then:

* Set `DISABLE_ACME=true` to disable certbot initialization and renewal in the container
* Use `HAPROXY_CONFIG=/etc/haproxy/haproxy-edge-terminated-tls.cfg`
* Set `HTTP_PORT` to a non-privileged container port such as `8080`
* Set `HTTPS_FORWARDED_PORT=443` so upstream services see the original external HTTPS port
* Configure the upstream load balancer or proxy to forward decrypted HTTP traffic to the pod `HTTP_PORT`

For MQTT in the same setup, if MQTT TLS is also terminated upstream:

* Terminate TLS on the upstream listener (for example external port `8883`)
* Forward plaintext TCP traffic from that listener to the pod's MQTT port
* The provided `haproxy-edge-terminated-tls.cfg` listens for MQTT on `MANAGER_MQTT_PORT` and forwards it to the configured manager MQTT backend

The `haproxy-edge-terminated-tls.cfg` file removes local TLS certificate usage from the pod and preserves the usual `X-Forwarded-*` HTTP headers for upstream applications. Do not use this config if HTTPS or MQTT TLS is still passed through to the pod.

## Logs

* `/var/log/*` - Location of log files (all are symlinked to stdout)