# HAProxy docker image
[![Docker Image](https://github.com/openremote/proxy/actions/workflows/proxy.yml/badge.svg)](https://github.com/openremote/proxy/actions/workflows/proxy.yml)

HAProxy docker image with Letsencrypt SSL auto renewal or custom certificate.

## Custom certificate usage

To use a custom certificate change your docker compose file to alter the command of the proxy container and also map your custom cert into the container and use the `LOCAL_CERT_FILE` environment variable to specify where to find this custom certificate:

```
command: start-with-certificate
environment:
  LOCAL_CERT_FILE: /my/cert/file
```

The custom cert file should be in pem format and contain the full chain and the private key.

```
 cat privkey.pem cert.pem chain.pem > ssl-certs.pem
```

See `haproxy` SSL cert [documentation](https://www.haproxy.com/blog/haproxy-ssl-termination/#enabling-ssl-with-haproxy)).
