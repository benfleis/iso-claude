FROM node:22

ARG TZ
ENV TZ="$TZ"

ARG CLAUDE_CODE_VERSION=latest

# Install basic development tools and iptables/ipset
RUN apt-get update && apt-get install -y --no-install-recommends \
  less \
  git \
  procps \
  sudo \
  fzf \
  zsh \
  man-db \
  unzip \
  zip \
  gnupg2 \
  gh \
  iptables \
  ipset \
  iproute2 \
  dnsutils \
  aggregate \
  jq \
  nano \
  vim \
  fd-find \
  ripgrep \
  cmake \
  ninja-build \
  g++ \
  clang \
  lldb \
  mold \
  sccache \
  clangd \
  jq \
  curl \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

# The node:22 base ships a uid/gid 1000 "node" user; rename it to iso-claude
# (uid/gid stay 1000, matching the host user that sessions exec as). Everything
# below refers to /home/iso-claude accordingly.
RUN usermod -l iso-claude -d /home/iso-claude -m node \
  && groupmod -n iso-claude node

# Ensure the iso-claude user has access to /usr/local/share
RUN mkdir -p /usr/local/share/npm-global && \
  chown -R iso-claude:iso-claude /usr/local/share

ARG USERNAME=iso-claude

# Persist bash history.
RUN SNIPPET="export PROMPT_COMMAND='history -a' && export HISTFILE=/commandhistory/.bash_history" \
  && mkdir /commandhistory \
  && touch /commandhistory/.bash_history \
  && chown -R $USERNAME /commandhistory

# Set `DEVCONTAINER` environment variable to help with orientation
ENV DEVCONTAINER=true

# Create the workspace mountpoint and the Claude state-dir mountpoint
# (CLAUDE_CONFIG_DIR — see docker-compose.yaml), then set ownership.
RUN mkdir -p /workspace /home/iso-claude/.claude-state && \
  chown -R iso-claude:iso-claude /workspace /home/iso-claude

WORKDIR /workspace

ARG GIT_DELTA_VERSION=0.18.2
RUN ARCH=$(dpkg --print-architecture) && \
  wget "https://github.com/dandavison/delta/releases/download/${GIT_DELTA_VERSION}/git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb" && \
  sudo dpkg -i "git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb" && \
  rm "git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb"

# Set up non-root user
USER iso-claude

# Install global packages
ENV NPM_CONFIG_PREFIX=/usr/local/share/npm-global
ENV PATH=$PATH:/usr/local/share/npm-global/bin

# Set the default shell to zsh rather than sh
ENV SHELL=/bin/zsh

# Set the default editor and visual
ENV EDITOR=vim
ENV VISUAL=vim

# Default powerline10k theme
ARG ZSH_IN_DOCKER_VERSION=1.2.0
RUN sh -c "$(wget -O- https://github.com/deluan/zsh-in-docker/releases/download/v${ZSH_IN_DOCKER_VERSION}/zsh-in-docker.sh)" -- \
  -p git \
  -p fzf \
  -a "source /usr/share/doc/fzf/examples/key-bindings.zsh" \
  -a "source /usr/share/doc/fzf/examples/completion.zsh" \
  -a "export PROMPT_COMMAND='history -a' && export HISTFILE=/commandhistory/.bash_history" \
  -x

# astral uv On macOS and Linux.
# Pinned to a specific version URL (astral's documented pinning mechanism —
# same pattern as GIT_DELTA_VERSION/ZSH_IN_DOCKER_VERSION above) instead of the
# mutable /uv/install.sh "latest" endpoint, so the fetched script content is
# tied to a released version rather than whatever astral.sh serves today.
ARG UV_VERSION=0.11.28
RUN curl --proto '=https' --tlsv1.2 -LsSf "https://astral.sh/uv/${UV_VERSION}/install.sh" | sh

# rustup — the sh.rustup.rs bootstrapper isn't independently version-pinnable,
# so fetch the platform rustup-init binary directly from the versioned archive
# and verify it against its published sha256 instead of piping the bootstrap
# script.
ARG RUSTUP_VERSION=1.29.0
RUN ARCH=$(dpkg --print-architecture) && \
  case "$ARCH" in \
    amd64) RUST_TARGET=x86_64-unknown-linux-gnu ;; \
    arm64) RUST_TARGET=aarch64-unknown-linux-gnu ;; \
    *) echo "no pinned rustup-init target mapped for dpkg arch '$ARCH'" >&2; exit 1 ;; \
  esac && \
  curl --proto '=https' --tlsv1.2 -sSfO "https://static.rust-lang.org/rustup/archive/${RUSTUP_VERSION}/${RUST_TARGET}/rustup-init" && \
  curl --proto '=https' --tlsv1.2 -sSfO "https://static.rust-lang.org/rustup/archive/${RUSTUP_VERSION}/${RUST_TARGET}/rustup-init.sha256" && \
  sha256sum -c rustup-init.sha256 && \
  chmod +x rustup-init && \
  ./rustup-init -y --verbose --default-toolchain stable && \
  rm rustup-init rustup-init.sha256

# Put the user-local toolchains (cargo, uv) on PATH for NON-login sessions too —
# Claude's own shell runs `claude` directly and never sources ~/.zshenv.
ENV PATH=$PATH:/home/iso-claude/.cargo/bin:/home/iso-claude/.local/bin

# Source personal/project shell config from the bind-mounted workspace, so it
# persists and stays host-editable instead of being baked in; and keep zsh
# history in the workspace too (HOME is /home/iso-claude, which is not mounted).
RUN printf '\n[ -f /workspace/.zshenv-local ] && source /workspace/.zshenv-local\n' >> /home/iso-claude/.zshenv \
  && printf '\n[ -f /workspace/.zshrc-local ] && source /workspace/.zshrc-local\nexport HISTFILE=/workspace/.zsh_history\n' >> /home/iso-claude/.zshrc

# Install Claude
RUN npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}

# Copy and set up firewall script
USER root

COPY init-firewall.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/init-firewall.sh

COPY entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/entrypoint.sh

USER iso-claude
