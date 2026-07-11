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
      yq-go \
      py3-yaml

# -------------------------
# Install acme.sh
# -------------------------
RUN curl -s https://get.acme.sh | sh && \
    chmod -R a+rX /root/.acme.sh && \
    ln -s /root/.acme.sh/acme.sh /usr/local/bin/acme.sh && \
    chmod a+x /root

ENV LE_CONFIG_HOME="/cert-updater/state"

# -------------------------
# Filesystem layout
# -------------------------
ENV HOME=/cert-updater/home

RUN mkdir -p \
    /cert-updater/bin \
    /cert-updater/config \
    /cert-updater/export \
    /cert-updater/home/.cache \
    /cert-updater/home/.ssh-runtime && \
    chmod 666 /etc/passwd

# -------------------------
# Copy scripts
# -------------------------
COPY bin/sync-certs.sh /cert-updater/bin/sync-certs.sh
COPY bin/deploy.sh     /cert-updater/bin/deploy.sh
COPY bin/update-status.sh /cert-updater/bin/update-status.sh
COPY bin/settings-api.py /cert-updater/bin/settings-api.py
COPY bin/hash-password.py /cert-updater/bin/hash-password.py
COPY entrypoint.sh    /entrypoint.sh

RUN chmod +x /cert-updater/bin/*.sh /cert-updater/bin/hash-password.py /entrypoint.sh

# -------------------------
# Web dashboard
# -------------------------
COPY web/ /cert-updater/web/

# -------------------------
# Entrypoint
# -------------------------
ENTRYPOINT ["/entrypoint.sh"]
