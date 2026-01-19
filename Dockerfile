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
      cron \
      openssh \
      rsync \
      yq-go

# -------------------------
# Install acme.sh
# -------------------------
RUN curl -s https://get.acme.sh | sh

ENV PATH="/root/.acme.sh:${PATH}"

# -------------------------
# Filesystem layout
# -------------------------
RUN mkdir -p \
    /acme/bin \
    /acme/config \
    /acme/export \
    /var/log/cron

# -------------------------
# Copy scripts
# -------------------------
COPY bin/sync-certs.sh /acme/bin/sync-certs.sh
COPY bin/deploy.sh     /acme/bin/deploy.sh
COPY entrypoint.sh    /entrypoint.sh

RUN chmod +x /acme/bin/*.sh /entrypoint.sh

# -------------------------
# Cron (monthly)
# -------------------------
RUN echo '0 3 1 * * /root/.acme.sh/acme.sh --cron --home /root/.acme.sh >> /var/log/cron/acme.log 2>&1' \
    > /etc/crontabs/root

# -------------------------
# Entrypoint
# -------------------------
ENTRYPOINT ["/entrypoint.sh"]
