# syntax=docker/dockerfile:1.7
FROM debian:bookworm

ARG GO_VERSION=1.26.3
ARG GO_SHA256_AMD64=2b2cfc7148493da5e73981bffbf3353af381d5f93e789c82c79aff64962eb556
ARG GO_SHA256_ARM64=9d89a3ea57d141c2b22d70083f2c8459ba3890f2d9e818e7e933b75614936565
ARG NODE_VERSION=24.15.0
ARG NODE_SHA256_AMD64=472655581fb851559730c48763e0c9d3bc25975c59d518003fc0849d3e4ba0f6
ARG NODE_SHA256_ARM64=f3d5a797b5d210ce8e2cb265544c8e482eaedcb8aa409a8b46da7e8595d0dda0
ARG PNPM_VERSION=11.2.2
ARG CODEX_VERSION=rust-v0.133.0
ARG CODEX_SHA256_AMD64=d06019ab9c35d281b78dc2ebb2ae55c2bb97ea11bf7f452bafe390eddb0034ef
ARG CODEX_SHA256_ARM64=268bfe8cf8154940fea256df75cd441c54a0c71e6c8ccd45ab3f76ff28ba1413
ARG DOCKER_CLI_VERSION=5:29.5.2-1~debian.12~bookworm
ARG CLAUDE_CODE_VERSION=2.1.146
ARG GEMINI_CLI_VERSION=0.42.0
ARG LUAU_VERSION=0.721
ARG LUAU_SHA256=b36924a114a76b4a48f02bcfbd14dfd0bb1c5b3a2f4bf246f254db50c031c061
ARG HOMEBREW_INSTALL_COMMIT=d2b324899b9210d534475560acecbc77bc47bc17
ARG HOMEBREW_INSTALL_SHA256=f3e91784ffeda32bc397de7acc1154724cc47522a459c9ac656cca176eeba457
ARG PG_MAJOR=15
ARG TARGETARCH

ENV GOPATH=/go \
    PG_MAJOR=${PG_MAJOR} \
    PGDATA=/workspace/.postgres-data \
    PNPM_HOME=/usr/local/share/pnpm \
    COREPACK_HOME=/usr/local/share/corepack \
    COREPACK_ENABLE_DOWNLOAD_PROMPT=0 \
    HOMEBREW_NO_ANALYTICS=1 \
    HOMEBREW_NO_AUTO_UPDATE=1 \
    PATH=/usr/local/go/bin:/go/bin:/usr/local/share/pnpm/bin:/usr/local/share/pnpm:/home/linuxbrew/.linuxbrew/bin:/home/linuxbrew/.linuxbrew/sbin:/usr/lib/postgresql/${PG_MAJOR}/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        bash \
        build-essential \
        ca-certificates \
        curl \
        file \
        git \
        git-lfs \
        gosu \
        jq \
        libatomic1 \
        libpq-dev \
        locales \
        lua5.4 \
        luarocks \
        passwd \
        postgresql-${PG_MAJOR} \
        postgresql-client-${PG_MAJOR} \
        procps \
        python-is-python3 \
        python3 \
        python3-pip \
        python3-venv \
        sudo \
        tzdata \
        xz-utils \
    && rm -rf /var/lib/apt/lists/*

RUN groupadd --system devtools \
    && git lfs install --system \
    && update-alternatives --set lua-interpreter /usr/bin/lua5.4 \
    && update-alternatives --set lua-compiler /usr/bin/luac5.4 \
    && printf '%s\n' \
        'export GOPATH=/go' \
        'export PNPM_HOME=/usr/local/share/pnpm' \
        'export COREPACK_HOME=/usr/local/share/corepack' \
        'export COREPACK_ENABLE_DOWNLOAD_PROMPT=0' \
        'export PATH="/usr/local/go/bin:/go/bin:/usr/local/share/pnpm/bin:/usr/local/share/pnpm:/home/linuxbrew/.linuxbrew/bin:/home/linuxbrew/.linuxbrew/sbin:/usr/lib/postgresql/${PG_MAJOR}/bin:/usr/local/sbin:/usr/sbin:/sbin:${PATH}"' \
        > /etc/profile.d/dev-tools.sh

RUN set -eux; \
    install -m 0755 -d /etc/apt/keyrings; \
    curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc; \
    chmod a+r /etc/apt/keyrings/docker.asc; \
    . /etc/os-release; \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian ${VERSION_CODENAME} stable" > /etc/apt/sources.list.d/docker.list; \
    apt-get update; \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "docker-ce-cli=${DOCKER_CLI_VERSION}"; \
    rm -rf /var/lib/apt/lists/*; \
    docker --version

RUN set -eux; \
    image_arch="${TARGETARCH:-$(dpkg --print-architecture)}"; \
    case "${image_arch}" in \
        amd64|x86_64) node_arch="x64"; node_sha256="${NODE_SHA256_AMD64}" ;; \
        arm64|aarch64) node_arch="arm64"; node_sha256="${NODE_SHA256_ARM64}" ;; \
        *) echo "Unsupported image architecture for Node: ${image_arch}" >&2; exit 1 ;; \
    esac; \
    node_file="node-v${NODE_VERSION}-linux-${node_arch}.tar.xz"; \
    curl -fsSLO "https://nodejs.org/dist/v${NODE_VERSION}/${node_file}"; \
    echo "${node_sha256}  ${node_file}" | sha256sum -c -; \
    tar -xJf "${node_file}" -C /usr/local --strip-components=1 --no-same-owner; \
    rm "${node_file}"; \
    node --version; \
    npm --version; \
    mkdir -p "${COREPACK_HOME}" "${PNPM_HOME}/bin"; \
    corepack enable; \
    corepack prepare "pnpm@${PNPM_VERSION}" --activate; \
    chgrp -R devtools "${COREPACK_HOME}" "${PNPM_HOME}"; \
    chmod -R g+rwX,a+rX "${COREPACK_HOME}" "${PNPM_HOME}"; \
    find "${COREPACK_HOME}" "${PNPM_HOME}" -type d -exec chmod g+s {} +; \
    pnpm --version

RUN set -eux; \
    image_arch="${TARGETARCH:-$(dpkg --print-architecture)}"; \
    case "${image_arch}" in \
        amd64|x86_64) go_arch="amd64"; go_sha256="${GO_SHA256_AMD64}" ;; \
        arm64|aarch64) go_arch="arm64"; go_sha256="${GO_SHA256_ARM64}" ;; \
        *) echo "Unsupported image architecture for Go: ${image_arch}" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-${go_arch}.tar.gz" -o /tmp/go.tgz; \
    echo "${go_sha256}  /tmp/go.tgz" | sha256sum -c -; \
    rm -rf /usr/local/go; \
    tar -C /usr/local -xzf /tmp/go.tgz; \
    rm /tmp/go.tgz; \
    mkdir -p "${GOPATH}/bin" "${GOPATH}/pkg"; \
    chmod -R a+rwX "${GOPATH}"

RUN set -eux; \
    curl -fsSL "https://github.com/luau-lang/luau/archive/refs/tags/${LUAU_VERSION}.tar.gz" -o /tmp/luau.tgz; \
    echo "${LUAU_SHA256}  /tmp/luau.tgz" | sha256sum -c -; \
    mkdir -p /tmp/luau-src; \
    tar -xzf /tmp/luau.tgz -C /tmp/luau-src --strip-components=1; \
    make -C /tmp/luau-src config=release luau luau-analyze; \
    install -m 0755 /tmp/luau-src/build/release/luau /usr/local/bin/luau; \
    install -m 0755 /tmp/luau-src/build/release/luau-analyze /usr/local/bin/luau-analyze; \
    printf 'print("luau-ok")\n' > /tmp/luau-smoke.luau; \
    luau /tmp/luau-smoke.luau; \
    luau-analyze /tmp/luau-smoke.luau; \
    rm -rf /tmp/luau-src /tmp/luau.tgz /tmp/luau-smoke.luau

RUN set -eux; \
    image_arch="${TARGETARCH:-$(dpkg --print-architecture)}"; \
    case "${image_arch}" in \
        amd64|x86_64) codex_target="x86_64-unknown-linux-musl"; codex_sha256="${CODEX_SHA256_AMD64}" ;; \
        arm64|aarch64) codex_target="aarch64-unknown-linux-musl"; codex_sha256="${CODEX_SHA256_ARM64}" ;; \
        *) echo "Unsupported image architecture for Codex: ${image_arch}" >&2; exit 1 ;; \
    esac; \
    codex_asset="codex-${codex_target}.tar.gz"; \
    codex_url="https://github.com/openai/codex/releases/download/${CODEX_VERSION}/${codex_asset}"; \
    curl -fsSL "${codex_url}" -o /tmp/codex.tar.gz; \
    echo "${codex_sha256}  /tmp/codex.tar.gz" | sha256sum -c -; \
    mkdir -p /tmp/codex; \
    tar -xzf /tmp/codex.tar.gz -C /tmp/codex; \
    install -m 0755 "/tmp/codex/codex-${codex_target}" /usr/local/bin/codex; \
    rm -rf /tmp/codex /tmp/codex.tar.gz; \
    codex --version

RUN set -eux; \
    pnpm add -g \
        "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" \
        "@google/gemini-cli@${GEMINI_CLI_VERSION}"; \
    claude_pkg="$(pnpm list -g --depth -1 --json @anthropic-ai/claude-code | jq -r '.[0].dependencies["@anthropic-ai/claude-code"].path')"; \
    node "${claude_pkg}/install.cjs"; \
    claude --version; \
    gemini --version; \
    pnpm store prune; \
    chgrp -R devtools "${COREPACK_HOME}" "${PNPM_HOME}"; \
    chmod -R g+rwX,a+rX "${COREPACK_HOME}" "${PNPM_HOME}"; \
    find "${COREPACK_HOME}" "${PNPM_HOME}" -type d -exec chmod g+s {} +

RUN groupadd --system linuxbrew \
    && useradd --system --gid linuxbrew --create-home --home-dir /home/linuxbrew --shell /bin/bash linuxbrew \
    && echo "linuxbrew ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/linuxbrew-install \
    && chmod 0440 /etc/sudoers.d/linuxbrew-install \
    && curl -fsSL "https://raw.githubusercontent.com/Homebrew/install/${HOMEBREW_INSTALL_COMMIT}/install.sh" -o /tmp/homebrew-install.sh \
    && echo "${HOMEBREW_INSTALL_SHA256}  /tmp/homebrew-install.sh" | sha256sum -c - \
    && runuser -u linuxbrew -- bash -lc 'umask 0002; NONINTERACTIVE=1 bash /tmp/homebrew-install.sh' \
    && rm /tmp/homebrew-install.sh \
    && rm /etc/sudoers.d/linuxbrew-install \
    && chgrp -R linuxbrew /home/linuxbrew/.linuxbrew \
    && chmod -R g+rwX /home/linuxbrew/.linuxbrew \
    && find /home/linuxbrew/.linuxbrew -type d -exec chmod g+s {} + \
    && runuser -u linuxbrew -- bash -lc 'umask 0002; /home/linuxbrew/.linuxbrew/bin/brew cleanup' \
    && chgrp -R linuxbrew /home/linuxbrew/.linuxbrew \
    && chmod -R g+rwX /home/linuxbrew/.linuxbrew \
    && find /home/linuxbrew/.linuxbrew -type d -exec chmod g+s {} +

RUN echo "%sudo ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/dev-users \
    && chmod 0440 /etc/sudoers.d/dev-users \
    && mkdir -p /workspace \
    && chmod 0777 /workspace \
    && printf '\nexport PS1="# "\n' >> /etc/skel/.bashrc

RUN <<'EOF'
cat > /usr/local/bin/dev-entrypoint <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

if [[ "$(id -u)" != "0" ]]; then
    exec "$@"
fi

workspace="${DEV_WORKSPACE:-/workspace}"
uid="${LOCAL_USER_ID:-}"
gid="${LOCAL_GROUP_ID:-}"

if [[ -z "${uid}" && -e "${workspace}" ]]; then
    uid="$(stat -c '%u' "${workspace}" 2>/dev/null || true)"
fi

if [[ -z "${gid}" && -e "${workspace}" ]]; then
    gid="$(stat -c '%g' "${workspace}" 2>/dev/null || true)"
fi

uid="${uid:-1000}"
gid="${gid:-1000}"
if [[ "${uid}" == "0" ]]; then uid="1000"; fi
if [[ "${gid}" == "0" ]]; then gid="1000"; fi

requested_name="${LOCAL_USER_NAME:-dev}"
group_name="$(getent group "${gid}" | cut -d: -f1 || true)"
if [[ -z "${group_name}" ]]; then
    group_name="${requested_name}"
    if getent group "${group_name}" >/dev/null; then
        group_name="${requested_name}-${gid}"
    fi
    groupadd --gid "${gid}" "${group_name}"
fi

user_name="$(getent passwd "${uid}" | cut -d: -f1 || true)"
if [[ -z "${user_name}" ]]; then
    user_name="${requested_name}"
    if id "${user_name}" >/dev/null 2>&1; then
        user_name="${requested_name}-${uid}"
    fi
    useradd_home_args=(--create-home)
    if [[ -e "/home/${user_name}" ]]; then
        useradd_home_args=(--no-create-home)
    fi
    useradd --uid "${uid}" --gid "${gid}" "${useradd_home_args[@]}" --shell /bin/bash "${user_name}"
elif [[ "${user_name}" != "${requested_name}" && "${LOCAL_ALLOW_EXISTING_USER:-0}" != "1" ]]; then
    echo "UID ${uid} already belongs to ${user_name}; set LOCAL_USER_NAME=${user_name} or LOCAL_ALLOW_EXISTING_USER=1 to use it." >&2
    exit 1
fi

home_dir="$(getent passwd "${user_name}" | cut -d: -f6)"
install -d -m 0755 -o "${uid}" -g "${gid}" "${home_dir}"
install -d -m 0700 -o "${uid}" -g "${gid}" "${home_dir}/.codex"
chown -R "${uid}:${gid}" "${home_dir}/.codex" 2>/dev/null || true
mkdir -p "${workspace}"
install -d -m 0775 -o "${uid}" -g "${gid}" /go /go/bin /go/pkg

if [[ ! -f "${home_dir}/.bashrc" && -f /etc/skel/.bashrc ]]; then
    cp /etc/skel/.bashrc "${home_dir}/.bashrc"
    chown "${uid}:${gid}" "${home_dir}/.bashrc"
fi

usermod -aG sudo,linuxbrew,devtools "${user_name}"
chown "${uid}:${gid}" /go /go/bin /go/pkg 2>/dev/null || true

docker_socket="${DOCKER_SOCKET:-/var/run/docker.sock}"
if [[ -S "${docker_socket}" ]]; then
    docker_gid="$(stat -c '%g' "${docker_socket}" 2>/dev/null || true)"
    if [[ -n "${docker_gid}" ]]; then
        docker_group="$(getent group "${docker_gid}" | cut -d: -f1 || true)"
        if [[ -z "${docker_group}" ]]; then
            docker_group="docker-host"
            if getent group "${docker_group}" >/dev/null; then
                docker_group="docker-host-${docker_gid}"
            fi
            groupadd --gid "${docker_gid}" "${docker_group}"
        fi
        usermod -aG "${docker_group}" "${user_name}"
    fi
fi

export HOME="${home_dir}"
export USER="${user_name}"
export LOGNAME="${user_name}"
export SHELL=/bin/bash

exec gosu "${user_name}" "$@"
SCRIPT
chmod 0755 /usr/local/bin/dev-entrypoint
EOF

WORKDIR /workspace
ENTRYPOINT ["dev-entrypoint"]
CMD ["bash"]
