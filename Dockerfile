# Ubuntu 26.04, not node:22 (Debian 12 bookworm): every apt-sourced toolchain in
# bookworm is frozen at 2022-2023, and this sandbox is a build box first. Losing
# the node base means Node is installed deliberately below — Claude Code is an
# npm global and must stay one (see tasks/claude-state-port.md).
FROM ubuntu:26.04

ARG TZ
ENV TZ="$TZ"

ARG CLAUDE_CODE_VERSION=latest

ENV DEBIAN_FRONTEND=noninteractive

# ca-certificates/curl/wget are base-image assumptions inherited from node:22
# that Ubuntu does not make; everything below fetching over https needs them.
# Same for the build kit from make onward: node:22 is FROM buildpack-deps, which
# silently provided make, autotools, pkg-config, patch and the common -dev
# headers (DuckDB's Makefile wrapper, vcpkg's autotools ports).
RUN apt-get update && apt-get install -y --no-install-recommends \
  ca-certificates \
  curl \
  wget \
  gnupg2 \
  less \
  git \
  procps \
  sudo \
  zsh \
  man-db \
  unzip \
  zip \
  zstd \
  xz-utils \
  iptables \
  ipset \
  iproute2 \
  dnsutils \
  nano \
  vim \
  cmake \
  ninja-build \
  g++ \
  lldb \
  clangd \
  poppler-utils \
  openjdk-17-jre-headless \
  make \
  autoconf \
  autoconf-archive \
  automake \
  libtool \
  pkg-config \
  patch \
  file \
  bzip2 \
  dpkg-dev \
  openssh-client \
  libssl-dev \
  zlib1g-dev \
  libcurl4-openssl-dev \
  liblzma-dev \
  libbz2-dev \
  libffi-dev \
  libreadline-dev \
  libsqlite3-dev \
  && rm -rf /var/lib/apt/lists/*

# Node via NodeSource rather than a pinned tarball: this reproduces exactly what
# the node:22 tag did — pin the major, float the patch.
ARG NODE_MAJOR=22
# The key is ASCII-armored: apt only accepts that under a .asc name (a .gpg name
# must be a binary keyring, else "unsupported filetype" and NO_PUBKEY).
RUN mkdir -p /etc/apt/keyrings \
  && curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
     -o /etc/apt/keyrings/nodesource.asc \
  && chmod a+r /etc/apt/keyrings/nodesource.asc \
  && echo "deb [signed-by=/etc/apt/keyrings/nodesource.asc] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main" \
     > /etc/apt/sources.list.d/nodesource.list \
  && printf 'Package: nodejs\nPin: origin deb.nodesource.com\nPin-Priority: 600\n' \
     > /etc/apt/preferences.d/nodesource \
  && apt-get update && apt-get install -y --no-install-recommends nodejs \
  && rm -rf /var/lib/apt/lists/* \
  && node --version | grep -q "^v${NODE_MAJOR}\." \
  && npm --version
# The pin above: without it apt takes whichever nodejs is newer, and Ubuntu's
# build is a different major AND ships without npm. The check fails the build
# rather than ship either.

# Rust, uv, go and sccache are NOT installed here: they come from /opt/tooling,
# one root-owned copy shared with the host and mounted read-only (tooling/README.md).

# iso-claude's uid/gid must match the HOST user: sessions exec as
# `--user $(id -u):$(id -g)` (bin/), and /opt/workspace is bind-mounted with the
# host's ownership — a mismatch leaves $HOME and npm-global unwritable.
# Set per host via ISO_UID/ISO_GID in the launcher .env (docker-compose.yaml).
# The label lets the launcher refuse an image built for the wrong user.
# Ubuntu ships a uid-1000 `ubuntu` user (node:22 shipped `node`): rename it, then
# renumber. usermod fails loudly if the target uid is already taken.
ARG USER_UID=1000
ARG USER_GID=1000
RUN if id -u ubuntu >/dev/null 2>&1; then \
      usermod -l iso-claude -d /home/iso-claude -m ubuntu && groupmod -n iso-claude ubuntu; \
    else \
      useradd -U -m -d /home/iso-claude -s /bin/bash iso-claude; \
    fi \
  && groupmod -g "$USER_GID" iso-claude \
  && usermod -u "$USER_UID" -g "$USER_GID" iso-claude
LABEL iso-claude.uid-gid="${USER_UID}:${USER_GID}"

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

# Mountpoints for the workspace and the shared toolchains (docker-compose.yaml).
RUN mkdir -p /opt/workspace /opt/tooling && \
  chown -R iso-claude:iso-claude /opt/workspace /home/iso-claude

WORKDIR /opt/workspace

ARG GIT_DELTA_VERSION=0.18.2
RUN ARCH=$(dpkg --print-architecture) && \
  wget "https://github.com/dandavison/delta/releases/download/${GIT_DELTA_VERSION}/git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb" && \
  dpkg -i "git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb" && \
  rm "git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb"

# Set up non-root user
USER iso-claude

# Install global packages
ENV NPM_CONFIG_PREFIX=/usr/local/share/npm-global

# The shared toolchains also go on PATH here, not only via /opt/tooling/env.sh
# so that non-rc-sourcing code gets the same.
ENV PATH=/opt/tooling/bin:$PATH:/usr/local/share/npm-global/bin

# Set the default shell to zsh rather than sh
ENV SHELL=/bin/zsh

# Default locale -- unset otherwise, which leaves every shell/tool in the
# POSIX/C locale (no UTF-8), so any non-ASCII byte (e.g. an em dash) gets
# displayed raw instead of decoded. C.UTF-8 is a minimal, always-available
# locale (no locale-gen needed) that just adds UTF-8 awareness on top of C.
ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8

# Set the default editor and visual
ENV EDITOR=vim
ENV VISUAL=vim

# Default powerline10k theme
ARG ZSH_IN_DOCKER_VERSION=1.2.0
# fzf key bindings/completion come from the omz fzf plugin (via `fzf --zsh`);
# fzf itself comes from /opt/tooling (on PATH at runtime, not at build time).
RUN sh -c "$(wget -O- https://github.com/deluan/zsh-in-docker/releases/download/v${ZSH_IN_DOCKER_VERSION}/zsh-in-docker.sh)" -- \
  -p git \
  -p fzf \
  -a "export PROMPT_COMMAND='history -a' && export HISTFILE=/commandhistory/.bash_history" \
  -x

# Shell environment, all from the bind mounts so it stays in step with the host:
# first the shared toolchains' env (/opt/tooling/env.sh, the same file the host
# sources), then personal config, which may override it. zsh history lives in the
# workspace too (HOME is not mounted). The workspace root is read-only by design
# (nothing lands there unplaced): config lives in config/, history (state) in state/.
RUN printf '\n[ -f /opt/tooling/env.sh ] && . /opt/tooling/env.sh\n[ -f /opt/workspace/config/zsh/env-local ] && source /opt/workspace/config/zsh/env-local\n' >> /home/iso-claude/.zshenv \
  && printf '\n[ -f /opt/workspace/config/zsh/rc-local ] && source /opt/workspace/config/zsh/rc-local\nexport HISTFILE=/opt/workspace/state/zsh_history\n' >> /home/iso-claude/.zshrc

# Git config matters, link to the workspace
RUN mkdir -p /home/iso-claude/.config && env -C /home/iso-claude/.config ln -sf /opt/workspace/config/git

# Install Claude
RUN npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}

# Runtime caches go to the shared cache (docs/data-zones.md). Set after the
# build-time npm install, whose cache stays in the image layer.
ENV XDG_CACHE_HOME=/opt/workspace/cache \
    npm_config_cache=/opt/workspace/cache/npm

# Copy and set up firewall script
USER root

COPY init-firewall.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/init-firewall.sh

COPY entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/entrypoint.sh

# Lock the $HOME defaults the env above replaces: empty, root-owned, read-only, so
# a tool that ignores the env fails loudly instead of writing to the container
# layer a recreate throws away. ~/.claude-state stays reachable as a link: Claude's
# own records store absolute paths under it.
RUN cd /home/iso-claude \
  && rm -rf .claude .claude-state .cache .npm .cargo .rustup \
  && ln -s /opt/workspace/state/iso-claude .claude-state \
  && mkdir -m 0555 .claude .cache .npm .cargo .rustup

USER iso-claude
