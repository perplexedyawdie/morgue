Optional extra CA certificates (`*.crt`, PEM) baked into the image at build time, for
builds behind a TLS-intercepting proxy. `*.crt` files here are gitignored; the spike
harness copies `$SSL_CERT_FILE` in automatically when it is set.
