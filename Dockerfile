FROM mcr.microsoft.com/dotnet/sdk:10.0

ARG USERNAME=dev
ARG NODE_MAJOR=22

# --- base tooling: git, ssh server, node/npm ---
RUN apt-get update && apt-get install -y --no-install-recommends \
        openssh-server \
        git \
        curl \
        ca-certificates \
        sudo \
        gnupg \
    && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL https://deb.nodesource.com/setup_${NODE_MAJOR}.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# --- non-root user with passwordless sudo ---
RUN useradd -m -s /bin/bash ${USERNAME} \
    && echo "${USERNAME} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/${USERNAME} \
    && chmod 0440 /etc/sudoers.d/${USERNAME}

# --- ssh server setup, key-only auth ---
RUN mkdir -p /var/run/sshd \
    && mkdir -p /home/${USERNAME}/.ssh \
    && chmod 700 /home/${USERNAME}/.ssh

COPY authorized_keys /home/${USERNAME}/.ssh/authorized_keys
RUN sed -i 's/\r$//' /home/${USERNAME}/.ssh/authorized_keys \
    && chown -R ${USERNAME}:${USERNAME} /home/${USERNAME}/.ssh \
    && chmod 600 /home/${USERNAME}/.ssh/authorized_keys \
    && sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config \
    && sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config

COPY entrypoint.sh /entrypoint.sh
# Belt and braces: a CRLF checkout on Windows would otherwise leave the shebang
# pointing at "/bin/bash\r" and the container would crash-loop on start.
RUN sed -i 's/\r$//' /entrypoint.sh \
    && chmod +x /entrypoint.sh

EXPOSE 22
ENTRYPOINT ["/entrypoint.sh"]
