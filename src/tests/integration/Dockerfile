FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# Install minimal dependencies needed before setup.sh runs.
# Retry up to 3 times: Ubuntu mirrors occasionally return 404 during
# package updates when the index references a superseded version.
RUN for attempt in 1 2 3; do \
        apt-get update && apt-get install -y \
            openssh-server \
            sudo \
            curl \
            systemctl \
        && break \
        || { echo "apt attempt $attempt failed, retrying..."; sleep 5; }; \
    done \
    && rm -rf /var/lib/apt/lists/*

# Create a fake authorized_keys so module 02 doesn't prompt for input
RUN mkdir -p /root/.ssh && \
    echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestKeyForDockerIntegrationTest test@integration" > /root/.ssh/authorized_keys && \
    chmod 700 /root/.ssh && \
    chmod 600 /root/.ssh/authorized_keys

# Create a minimal sshd_config for testing
RUN mkdir -p /etc/ssh && \
    echo "Port 22" > /etc/ssh/sshd_config && \
    echo "#PasswordAuthentication yes" >> /etc/ssh/sshd_config && \
    echo "#PubkeyAuthentication yes" >> /etc/ssh/sshd_config && \
    ssh-keygen -A

COPY . /opt/ridgeguard
WORKDIR /opt/ridgeguard

# Integration test script runs individual modules with mocked services
COPY tests/integration/run.sh /opt/run-tests.sh
RUN chmod +x /opt/run-tests.sh

CMD ["/opt/run-tests.sh"]
