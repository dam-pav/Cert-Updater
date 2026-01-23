FROM alpine:3.20

# -------------------------
# Packages
# -------------------------
RUN echo "https://dl-cdn.alpinelinux.org/alpine/v3.20/community" >> /etc/apk/repositories && \
    apk add --no-cache \
      bash \
      curl \
      openssl \
      ca-certificates \
      cronie \
      openssh \
      rsync \
      yq-go

# -------------------------
# Install acme.sh
# -------------------------
RUN curl -s https://get.acme.sh | sh && \
    chmod -R a+rX /root/.acme.sh && \
    ln -s /root/.acme.sh/acme.sh /usr/local/bin/acme.sh && \
    chmod a+x /root

ENV LE_CONFIG_HOME="/acme/state"

# -------------------------
# Filesystem layout
# -------------------------
ENV HOME=/acme/home

RUN mkdir -p \
    /acme/bin \
    /acme/config \
    /acme/export \
    /acme/home \
    /var/log/cron

# -------------------------
# Copy scripts
# -------------------------
COPY bin/sync-certs.sh /acme/bin/sync-certs.sh
COPY bin/deploy.sh     /acme/bin/deploy.sh
COPY entrypoint.sh    /entrypoint.sh

RUN chmod +x /acme/bin/*.sh /entrypoint.sh

# -------------------------
# Entrypoint
# -------------------------
ENTRYPOINT ["/entrypoint.sh"]
