# Morgue runtime: PHP 8.4.27 (first 8.4 release with the PHP2Shell fix,
# CVE-2026-109618 / CVE-2026-109619). Pin the patch version exactly; do not float to 8.4.
FROM php:8.4.27-cli

# Optional corporate/sandbox CA (see docker/extra-ca/README.md). Docker's predefined
# HTTPS_PROXY build arg is honoured by apt and composer when passed with --build-arg.
COPY docker/extra-ca/ /usr/local/share/ca-certificates/extra/
RUN update-ca-certificates \
 && sed -i 's#http://deb.debian.org#https://deb.debian.org#g' /etc/apt/sources.list.d/debian.sources \
 && apt-get update \
 && apt-get install -y --no-install-recommends git unzip \
 && rm -rf /var/lib/apt/lists/* \
 && docker-php-ext-install -j"$(nproc)" pdo_mysql

COPY --from=composer:2.10.3 /usr/bin/composer /usr/local/bin/composer
ENV COMPOSER_ALLOW_SUPERUSER=1

WORKDIR /app
