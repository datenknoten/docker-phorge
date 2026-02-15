##### Start Phorge
FROM php:8.3-apache-bookworm AS base
##### End Phorge

LABEL org.opencontainers.image.source https://github.com/phorge-docker/phorge

# Required Components
# @see https://secure.phorge.com/book/phorge/article/installation_guide/#installing-required-comp
RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    git \
    mercurial \
    subversion \
    ca-certificates \
    # @see https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=944908
    python3-pkg-resources \
    python3-pygments \
    imagemagick \
    # @see https://secure.phorge.com/w/guides/dependencies/
    # provides ssh-keygen and ssh, these are needed to sync ssh repositories
    openssh-client \
    procps \
  && rm -rf /var/lib/apt/lists/*

# install the PHP extensions we need
RUN set -ex; \
    \
    if command -v a2enmod; then \
        # Phorge needs mod_rewrite for rewritting to index.php
        a2enmod rewrite; \
    fi; \
    \
    savedAptMark="$(apt-mark showmanual)"; \
    \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      libonig-dev \
      libcurl4-gnutls-dev \
      libjpeg62-turbo-dev \
      libpng-dev \
      libfreetype6-dev \
      libzip-dev \
    ; \
    \
  docker-php-ext-configure gd \
    --with-jpeg \
    --with-freetype \
  ; \
  \
    docker-php-ext-install -j "$(nproc)" \
    gd \
    opcache \
    mbstring \
    iconv \
    mysqli \
    curl \
    pcntl \
    zip \
    ; \
  \
  # reset apt-mark's "manual" list so that "purge --auto-remove" will remove all build dependencies
    apt-mark auto '.*' > /dev/null; \
    apt-mark manual $savedAptMark; \
    ldd "$(php -r 'echo ini_get("extension_dir");')"/*.so \
        | awk '/=>/ { print $3 }' \
        | sort -u \
        | xargs -r dpkg-query -S \
        | cut -d: -f1 \
        | sort -u \
        | xargs -rt apt-mark manual; \
    \
    apt-get purge -y --auto-remove -o APT::AutoRemove::RecommendsImportant=false; \
    rm -rf /var/lib/apt/lists/*

RUN pecl channel-update pecl.php.net \
  && pecl install apcu \
  && docker-php-ext-enable apcu

# set recommended PHP.ini settings
# see https://secure.php.net/manual/en/opcache.installation.php
RUN { \
        echo 'opcache.memory_consumption=128'; \
        echo 'opcache.interned_strings_buffer=8'; \
        echo 'opcache.max_accelerated_files=4000'; \
        echo 'opcache.revalidate_freq=60'; \
        echo 'opcache.fast_shutdown=1'; \
        # From Phorge
        echo 'opcache.validate_timestamps=0'; \
    } > /usr/local/etc/php/conf.d/opcache-recommended.ini

# Set the default timezone.
RUN { \
        echo 'date.timezone="UTC"'; \
    } > /usr/local/etc/php/conf.d/timezone.ini

# File Uploads
RUN { \
        echo 'post_max_size=32M'; \
        echo 'upload_max_filesize=32M'; \
    } > /usr/local/etc/php/conf.d/uploads.ini

# Repository Folder.
RUN mkdir /var/repo \
  && chown www-data:www-data /var/repo

COPY ./ /opt

WORKDIR /opt/phorge

RUN git submodule update --init --recursive

ENV PATH "$PATH:/opt/phorge/bin"

FROM base AS web

RUN rmdir /var/www/html; \
	  ln -sf /opt/phorge/webroot /var/www/html;

RUN { \
        echo '<VirtualHost *:80>'; \
        echo '  RewriteEngine on'; \
        echo '  RewriteRule ^(.*)$ /index.php?__path__=$1 [B,L,QSA]'; \
        echo '</VirtualHost>'; \
    } > /etc/apache2/sites-available/000-default.conf

FROM base AS daemon

CMD phd start \
  && tail -f /var/tmp/phd/log/daemons.log

FROM base AS aphlict

RUN mkdir -p /var/log \
  && touch /var/log/aphlict.log \
  && chown www-data:www-data /var/log/aphlict.log

EXPOSE 22280
EXPOSE 22281

COPY --from=node:lts-buster /usr/local/bin/node /usr/local/bin/node

COPY --from=node:lts-buster /usr/local/lib/node_modules /usr/local/lib/node_modules

RUN ln -s ../lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm; \
    ln -s ../lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx;

RUN npm clean-install --prefix /opt/phorge/support/aphlict/server ws

USER www-data

CMD aphlict debug

FROM base as sshd

ARG DEBIAN_FRONTEND=noninteractive
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN apt-get update && \
    apt-get install --yes --no-install-recommends \
      openssh-server \
      git \
      sudo && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* && \
    mkdir /run/sshd && \
    useradd -m vcs-user && \
    usermod -p NP vcs-user && \
    usermod -s /bin/sh vcs-user

COPY vcs-sudo /etc/sudoers.d/vcs-user

CMD [ "/usr/sbin/sshd", "-D" ]
