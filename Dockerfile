FROM debian:bookworm-slim

ARG CLOUDFLARED_VERSION=2024.12.2

RUN apt-get update && apt-get install -y --no-install-recommends \
    openssh-server \
    python3 \
    python3-pip \
    python3-venv \
    curl \
    cron \
    ca-certificates \
    openssl \
    jq \
    wget \
    iproute2 \
    && rm -rf /var/lib/apt/lists/*

RUN arch=$(dpkg --print-architecture) && \
    curl -fsSL "https://github.com/cloudflare/cloudflared/releases/download/${CLOUDFLARED_VERSION}/cloudflared-linux-${arch}.deb" \
    -o /tmp/cloudflared.deb \
    && dpkg -i /tmp/cloudflared.deb \
    && rm /tmp/cloudflared.deb

RUN mkdir -p /var/run/sshd /keys /root/.ssh /app /scripts \
    && chmod 700 /root/.ssh /keys

COPY api/requirements.txt /app/requirements.txt
RUN python3 -m venv /app/venv \
    && /app/venv/bin/pip install --no-cache-dir -r /app/requirements.txt

COPY api/ /app/
COPY scripts/ /scripts/
COPY config/sshd_config /etc/ssh/sshd_config

RUN chmod +x /scripts/*.sh \
    && chmod 600 /etc/ssh/sshd_config

# Key rotation every 24h at midnight UTC
RUN printf '0 0 * * * root /scripts/rotate-keys.sh >> /var/log/key-rotation.log 2>&1\n' \
    > /etc/cron.d/ssh-rotation \
    && chmod 0644 /etc/cron.d/ssh-rotation

# Sync peer authorized_keys every 5 minutes
RUN printf '*/5 * * * * root /scripts/update-authorized-keys.sh >> /var/log/auth-update.log 2>&1\n' \
    >> /etc/cron.d/ssh-rotation

VOLUME ["/keys", "/etc/cloudflared"]

ENTRYPOINT ["/scripts/entrypoint.sh"]
