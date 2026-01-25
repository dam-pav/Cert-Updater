FROM alpine:3.20

# -------------------------
# Packages
# -------------------------
RUN apk add --no-cache \
      bash \
      curl \
      openssl \
      ca-certificates \
      openssh-client \
      rsync \
      yq-go && \
    # Install supercronic (cron for containers, runs as non-root)
    curl -fsSL https://github.com/aptible/supercronic/releases/download/v0.2.29/supercronic-linux-amd64 -o /usr/local/bin/supercronic && \
    chmod +x /usr/local/bin/supercronic

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
    /acme/home/.cache \
    /acme/home/.ssh-runtime \
    /var/log/cron && \
    chmod 666 /etc/passwd

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
