# syntax=docker/dockerfile:1.7
FROM debian:bookworm@sha256:ed4fcc40bb1162b6d2d32e7bec15044d13963779abbe63f67f1cd62b06220519

ARG GO_VERSION=1.27.0
ARG GO_SHA256_AMD64=675c26c449cbb18fc24b74650de1eabbae6e16f64326fd85a283fb3b58280685
ARG GO_SHA256_ARM64=51798d2c42d0e1c6ed7fd9f48728b4193abac9e8aad6dbac2fe96a81f5909bda
ARG GIT_VERSION=2.55.0
ARG GIT_SHA256=457fdb04dc8728e007d4688695e6912e6f680727920f2a40bf11eacc17505357
ARG GIT_SIGNING_KEY=96E07AF25771955980DAD10020D04E5A713660A7
ARG GIT_SIGNING_KEY_TAG=dd20f6ea53bf6828baba3e2f279bf633eaae6815
ARG NODE_VERSION=24.19.0
ARG NODE_SHA256_AMD64=14b342e71204f811bde6153be8e04b62aef63c236fef92b55f9c83154b409647
ARG NODE_SHA256_ARM64=01443c1e1a29e531ccad5a46fefa6df490d2189c49f7955904aecdbb0fe86fdc
ARG PNPM_VERSION=11.22.0
ARG BAZELISK_VERSION=1.29.0
ARG BAZELISK_SHA256_AMD64=5a408715e932c0250d28bd84555f12edbf70117de42f9181691c736eacc4a992
ARG BAZELISK_SHA256_ARM64=e20e8b0f4f240091b7a55bf17b9398bd4f40ee70ae0208dff95dd4c445fb4010
ARG BAZEL_VERSION=9.2.0
ARG BAZEL_SHA256_AMD64=7668a95db1250f12c40407251e4e203b4ec8bf39bc495d2f485b2d8c99048694
ARG BAZEL_SHA256_ARM64=049dd21f40ad979db11c3ee68c96a42ce75f1185e69ac61ab20de1501427a410
ARG RUST_VERSION=1.98.0
ARG RUSTUP_VERSION=1.29.0
ARG RUSTUP_SHA256_AMD64=4acc9acc76d5079515b46346a485974457b5a79893cfb01112423c89aeb5aa10
ARG RUSTUP_SHA256_ARM64=9732d6c5e2a098d3521fca8145d826ae0aaa067ef2385ead08e6feac88fa5792
ARG SWIFT_VERSION=6.3.3
ARG SWIFT_RELEASE_SIGNING_KEY=52BB7E3DE28A71BE22EC05FFEF80A866B47A981F
ARG RIPGREP_VERSION=13.0.0-4+b2
ARG VIM_VERSION=2:9.0.1378-2+deb12u2
ARG DOCKER_CLI_VERSION=5:29.7.2-1~debian.12~bookworm
ARG DOCKER_COMPOSE_PLUGIN_VERSION=5.5.0-1~debian.12~bookworm
ARG LUAU_VERSION=0.734
ARG LUAU_SHA256=cb55a891226d8c70284e22eb9281cc2b4496c709a4050f52aaa18a355fe7b1a3
ARG HOMEBREW_INSTALL_COMMIT=d2b324899b9210d534475560acecbc77bc47bc17
ARG HOMEBREW_INSTALL_SHA256=f3e91784ffeda32bc397de7acc1154724cc47522a459c9ac656cca176eeba457
ARG PG_MAJOR=15
ARG TARGETARCH

ENV GOPATH=/go \
    CARGO_HOME=/usr/local/cargo \
    RUSTUP_HOME=/usr/local/rustup \
    SWIFT_HOME=/usr/local/swift \
    PG_MAJOR=${PG_MAJOR} \
    PNPM_HOME=/usr/local/share/pnpm \
    COREPACK_HOME=/usr/local/share/corepack \
    COREPACK_ENABLE_DOWNLOAD_PROMPT=0 \
    HOMEBREW_NO_ANALYTICS=1 \
    HOMEBREW_NO_AUTO_UPDATE=1 \
    GH_TELEMETRY=false \
    PATH=/usr/local/cargo/bin:/usr/local/go/bin:/go/bin:/usr/local/swift/usr/bin:/usr/local/share/pnpm/bin:/usr/local/share/pnpm:/home/linuxbrew/.linuxbrew/bin:/home/linuxbrew/.linuxbrew/sbin:/usr/lib/postgresql/${PG_MAJOR}/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        age \
        bash \
        build-essential \
        ca-certificates \
        curl \
        file \
        ffmpeg \
        git \
        git-lfs \
        gnupg \
        gosu \
        imagemagick \
        iputils-ping \
        jq \
        less \
        libatomic1 \
        libcurl4-openssl-dev \
        libedit-dev \
        libexpat1-dev \
        libglib2.0-dev \
        libgtk-4-dev \
        libicu-dev \
        libncurses-dev \
        libpcre2-dev \
        libpq-dev \
        libpython3-dev \
        libsqlite3-dev \
        libssl-dev \
        libwebkitgtk-6.0-dev \
        libxml2-dev \
        locales \
        lua5.4 \
        luarocks \
        ncurses-term \
        openssh-client \
        pandoc \
        passwd \
        pkg-config \
        postgresql-${PG_MAJOR} \
        postgresql-client-${PG_MAJOR} \
        procps \
        python-is-python3 \
        python3 \
        python3-pip \
        python3-venv \
        "ripgrep=${RIPGREP_VERSION}" \
        sudo \
        tree \
        tzdata \
        unzip \
        uuid-dev \
        weasyprint \
        "vim-common=${VIM_VERSION}" \
        "vim-tiny=${VIM_VERSION}" \
        xz-utils \
        zip \
        zlib1g-dev \
    && ffmpeg -version \
    && age --version \
    && identify -version \
    && pandoc --version \
    && ping -V \
    && pkg-config --exists \
        cairo \
        gdk-pixbuf-2.0 \
        gio-2.0 \
        glib-2.0 \
        gobject-2.0 \
        graphene-1.0 \
        gtk4 \
        pango \
        webkitgtk-6.0 \
    && rg --version \
    && ssh -V \
    && weasyprint --version \
    && vi --version \
    && rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    export GNUPGHOME="$(mktemp -d)"; \
    mkdir -p /tmp/git-key; \
    git init -q /tmp/git-key; \
    git -C /tmp/git-key fetch -q --depth=1 https://git.kernel.org/pub/scm/git/git.git refs/tags/junio-gpg-pub; \
    test "$(git -C /tmp/git-key rev-parse FETCH_HEAD)" = "${GIT_SIGNING_KEY_TAG}"; \
    git -C /tmp/git-key cat-file blob 'FETCH_HEAD^{}' > /tmp/git-signing-key.asc; \
    gpg --batch --import /tmp/git-signing-key.asc; \
    gpg --batch --list-keys --with-colons "${GIT_SIGNING_KEY}" | grep -q "^fpr:::::::::${GIT_SIGNING_KEY}:"; \
    curl -fsSL "https://www.kernel.org/pub/software/scm/git/git-${GIT_VERSION}.tar.xz" -o /tmp/git.tar.xz; \
    curl -fsSL "https://www.kernel.org/pub/software/scm/git/git-${GIT_VERSION}.tar.sign" -o /tmp/git.tar.sign; \
    echo "${GIT_SHA256}  /tmp/git.tar.xz" | sha256sum -c -; \
    xz -cd /tmp/git.tar.xz | gpg --batch --verify /tmp/git.tar.sign -; \
    mkdir -p /tmp/git-src; \
    tar -xJf /tmp/git.tar.xz -C /tmp/git-src --strip-components=1; \
    make -C /tmp/git-src -j"$(nproc)" prefix=/usr/local NO_TCLTK=YesPlease NO_GETTEXT=YesPlease NO_RUST=YesPlease USE_LIBPCRE2=YesPlease all; \
    make -C /tmp/git-src prefix=/usr/local NO_TCLTK=YesPlease NO_GETTEXT=YesPlease NO_RUST=YesPlease USE_LIBPCRE2=YesPlease install; \
    rm -rf "${GNUPGHOME}" /tmp/git-key /tmp/git-signing-key.asc /tmp/git-src /tmp/git.tar.sign /tmp/git.tar.xz; \
    hash -r; \
    test "$(command -v git)" = "/usr/local/bin/git"; \
    test "$(git --version)" = "git version ${GIT_VERSION}"; \
    git --version

RUN groupadd --system devtools \
    && git lfs install --system \
    && update-alternatives --set lua-interpreter /usr/bin/lua5.4 \
    && update-alternatives --set lua-compiler /usr/bin/luac5.4 \
    && install -d -m 0755 /etc/skel/.codex \
    && printf '%s\n' \
        'sandbox_mode = "danger-full-access"' \
        > /etc/skel/.codex/config.toml \
    && chmod 0600 /etc/skel/.codex/config.toml \
    && printf '%s\n' \
        'export GOPATH=/go' \
        'export CARGO_HOME=/usr/local/cargo' \
        'export RUSTUP_HOME=/usr/local/rustup' \
        'export SWIFT_HOME=/usr/local/swift' \
        'export PNPM_HOME=/usr/local/share/pnpm' \
        'export COREPACK_HOME=/usr/local/share/corepack' \
        'export COREPACK_ENABLE_DOWNLOAD_PROMPT=0' \
        'export GH_TELEMETRY=false' \
        'export PATH="/usr/local/cargo/bin:/usr/local/go/bin:/go/bin:/usr/local/swift/usr/bin:/usr/local/share/pnpm/bin:/usr/local/share/pnpm:/home/linuxbrew/.linuxbrew/bin:/home/linuxbrew/.linuxbrew/sbin:/usr/lib/postgresql/${PG_MAJOR}/bin:/usr/local/sbin:/usr/sbin:/sbin:${PATH}"' \
        > /etc/profile.d/dev-tools.sh

RUN set -eux; \
    mkdir -p "${RUSTUP_HOME}" "${CARGO_HOME}"; \
    image_arch="${TARGETARCH:-$(dpkg --print-architecture)}"; \
    case "${image_arch}" in \
        amd64|x86_64) rust_host="x86_64-unknown-linux-gnu"; rustup_sha256="${RUSTUP_SHA256_AMD64}" ;; \
        arm64|aarch64) rust_host="aarch64-unknown-linux-gnu"; rustup_sha256="${RUSTUP_SHA256_ARM64}" ;; \
        *) echo "Unsupported image architecture for Rust: ${image_arch}" >&2; exit 1 ;; \
    esac; \
    rustup_url="https://static.rust-lang.org/rustup/archive/${RUSTUP_VERSION}/${rust_host}/rustup-init"; \
    curl -fsSL "${rustup_url}" -o /tmp/rustup-init; \
    echo "${rustup_sha256}  /tmp/rustup-init" | sha256sum -c -; \
    chmod +x /tmp/rustup-init; \
    /tmp/rustup-init -y --no-modify-path --profile minimal --default-toolchain "${RUST_VERSION}" --default-host "${rust_host}"; \
    rm /tmp/rustup-init; \
    rustup component add clippy rustfmt; \
    rustup --version; \
    rustc --version; \
    cargo --version; \
    rustfmt --version; \
    cargo clippy --version; \
    chgrp -R devtools "${RUSTUP_HOME}" "${CARGO_HOME}"; \
    chmod -R g+rwX,a+rX "${RUSTUP_HOME}" "${CARGO_HOME}"; \
    find "${RUSTUP_HOME}" "${CARGO_HOME}" -type d -exec chmod g+s {} +

RUN set -eux; \
    export GNUPGHOME="$(mktemp -d)"; \
    image_arch="${TARGETARCH:-$(dpkg --print-architecture)}"; \
    case "${image_arch}" in \
        amd64|x86_64) swift_platform="debian12" ;; \
        arm64|aarch64) swift_platform="debian12-aarch64" ;; \
        *) echo "Unsupported image architecture for Swift: ${image_arch}" >&2; exit 1 ;; \
    esac; \
    swift_release="swift-${SWIFT_VERSION}-RELEASE"; \
    swift_file="${swift_release}-${swift_platform}.tar.gz"; \
    swift_url="https://download.swift.org/swift-${SWIFT_VERSION}-release/${swift_platform}/${swift_release}/${swift_file}"; \
    curl --compressed -fsSL https://swift.org/keys/all-keys.asc -o /tmp/swift-keys.asc; \
    gpg --batch --import /tmp/swift-keys.asc; \
    gpg --batch --list-keys --with-colons "${SWIFT_RELEASE_SIGNING_KEY}" | grep -q "^fpr:::::::::${SWIFT_RELEASE_SIGNING_KEY}:"; \
    curl -fsSL "${swift_url}" -o "/tmp/${swift_file}"; \
    curl -fsSL "${swift_url}.sig" -o "/tmp/${swift_file}.sig"; \
    verify_output="$(gpg --batch --status-fd=1 --verify "/tmp/${swift_file}.sig" "/tmp/${swift_file}" 2>&1)"; \
    printf '%s\n' "${verify_output}"; \
    printf '%s\n' "${verify_output}" | grep -q "^\\[GNUPG:\\] VALIDSIG ${SWIFT_RELEASE_SIGNING_KEY} "; \
    install -d -m 0755 "${SWIFT_HOME}"; \
    tar -xzf "/tmp/${swift_file}" -C "${SWIFT_HOME}" --strip-components=1 --no-same-owner; \
    swift --version; \
    swiftc --version; \
    printf 'print("swift-ok")\n' > /tmp/swift-smoke.swift; \
    swiftc /tmp/swift-smoke.swift -o /tmp/swift-smoke; \
    /tmp/swift-smoke; \
    rm -rf "${GNUPGHOME}" /tmp/swift-keys.asc "/tmp/${swift_file}" "/tmp/${swift_file}.sig" /tmp/swift-smoke /tmp/swift-smoke.swift

RUN set -eux; \
    install -m 0755 -d /etc/apt/keyrings; \
    curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc; \
    chmod a+r /etc/apt/keyrings/docker.asc; \
    . /etc/os-release; \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian ${VERSION_CODENAME} stable" > /etc/apt/sources.list.d/docker.list; \
    apt-get update; \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        "docker-ce-cli=${DOCKER_CLI_VERSION}" \
        "docker-compose-plugin=${DOCKER_COMPOSE_PLUGIN_VERSION}"; \
    rm -rf /var/lib/apt/lists/*; \
    docker --version; \
    docker compose version

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

ARG GITHUB_CLI_VERSION=2.98.0
ARG GITHUB_CLI_SHA256_AMD64=3b8ac6b30336802fc1a858d7c084e11cdf24ac1a761ca90b68022d7d729208de
ARG GITHUB_CLI_SHA256_ARM64=cf689084f3a3618f7eae4a2420d335d74626d65f5e594b9828d125d69f800d86
RUN set -eux; \
    image_arch="${TARGETARCH:-$(dpkg --print-architecture)}"; \
    case "${image_arch}" in \
        amd64|x86_64) gh_arch="amd64"; gh_sha256="${GITHUB_CLI_SHA256_AMD64}" ;; \
        arm64|aarch64) gh_arch="arm64"; gh_sha256="${GITHUB_CLI_SHA256_ARM64}" ;; \
        *) echo "Unsupported image architecture for GitHub CLI: ${image_arch}" >&2; exit 1 ;; \
    esac; \
    gh_file="gh_${GITHUB_CLI_VERSION}_linux_${gh_arch}.tar.gz"; \
    curl -fsSL "https://github.com/cli/cli/releases/download/v${GITHUB_CLI_VERSION}/${gh_file}" -o "/tmp/${gh_file}"; \
    echo "${gh_sha256}  /tmp/${gh_file}" | sha256sum -c -; \
    mkdir -p /tmp/gh; \
    tar -xzf "/tmp/${gh_file}" -C /tmp/gh --strip-components=1; \
    install -m 0755 /tmp/gh/bin/gh /usr/local/bin/gh; \
    rm -rf /tmp/gh "/tmp/${gh_file}"; \
    gh --version

ARG UV_VERSION=0.12.5
ARG UV_SHA256_AMD64=68a509da24b06b4223a1c0175fb5eb5bc79342b76cbeff0cfe51ac3f5b17b6b2
ARG UV_SHA256_ARM64=9bf43b4d1a07665bf64d4c4e710930b382321a785e0eb10aac07f46471f86a31
RUN set -eux; \
    image_arch="${TARGETARCH:-$(dpkg --print-architecture)}"; \
    case "${image_arch}" in \
        amd64|x86_64) uv_target="x86_64-unknown-linux-gnu"; uv_sha256="${UV_SHA256_AMD64}" ;; \
        arm64|aarch64) uv_target="aarch64-unknown-linux-gnu"; uv_sha256="${UV_SHA256_ARM64}" ;; \
        *) echo "Unsupported image architecture for uv: ${image_arch}" >&2; exit 1 ;; \
    esac; \
    uv_file="uv-${uv_target}.tar.gz"; \
    curl -fsSL "https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/${uv_file}" -o "/tmp/${uv_file}"; \
    echo "${uv_sha256}  /tmp/${uv_file}" | sha256sum -c -; \
    mkdir -p /tmp/uv; \
    tar -xzf "/tmp/${uv_file}" -C /tmp/uv --strip-components=1; \
    install -m 0755 /tmp/uv/uv /usr/local/bin/uv; \
    install -m 0755 /tmp/uv/uvx /usr/local/bin/uvx; \
    rm -rf /tmp/uv "/tmp/${uv_file}"; \
    uv --version; \
    uvx --version

ARG MODAL_CLI_VERSION=1.5.4
RUN set -eux; \
    UV_TOOL_DIR=/usr/local/share/uv/tools \
    UV_TOOL_BIN_DIR=/usr/local/bin \
    uv tool install \
        --python /usr/bin/python3 \
        --no-managed-python \
        --no-python-downloads \
        --no-cache \
        "modal==${MODAL_CLI_VERSION}"; \
    modal --version

ENV BAZELISK_HOME=/usr/local/share/bazelisk \
    USE_BAZEL_FALLBACK_VERSION=silent:${BAZEL_VERSION}

RUN set -eux; \
    image_arch="${TARGETARCH:-$(dpkg --print-architecture)}"; \
    case "${image_arch}" in \
        amd64|x86_64) bazelisk_arch="amd64"; bazelisk_sha256="${BAZELISK_SHA256_AMD64}"; bazel_sha256="${BAZEL_SHA256_AMD64}" ;; \
        arm64|aarch64) bazelisk_arch="arm64"; bazelisk_sha256="${BAZELISK_SHA256_ARM64}"; bazel_sha256="${BAZEL_SHA256_ARM64}" ;; \
        *) echo "Unsupported image architecture for Bazelisk: ${image_arch}" >&2; exit 1 ;; \
    esac; \
    bazelisk_file="bazelisk-linux-${bazelisk_arch}"; \
    curl -fsSL "https://github.com/bazelbuild/bazelisk/releases/download/v${BAZELISK_VERSION}/${bazelisk_file}" -o "/tmp/${bazelisk_file}"; \
    echo "${bazelisk_sha256}  /tmp/${bazelisk_file}" | sha256sum -c -; \
    install -m 0755 "/tmp/${bazelisk_file}" /usr/local/bin/bazelisk; \
    ln -s bazelisk /usr/local/bin/bazel; \
    rm "/tmp/${bazelisk_file}"; \
    test "$(bazelisk bazeliskVersion)" = "Bazelisk version: v${BAZELISK_VERSION}"; \
    mkdir -p "${BAZELISK_HOME}"; \
    test "$(BAZELISK_VERIFY_SHA256="${bazel_sha256}" USE_BAZEL_VERSION="${BAZEL_VERSION}" bazel --version)" = "bazel ${BAZEL_VERSION}"; \
    chgrp -R devtools "${BAZELISK_HOME}"; \
    chmod -R g+rwX,a+rX "${BAZELISK_HOME}"; \
    find "${BAZELISK_HOME}" -type d -exec chmod g+s {} +

# Fast-moving assistant CLIs stay after the expensive language runtimes and Homebrew
# layers. Version bumps here should only rebuild these layers and cheap final setup.
ARG GEMINI_CLI_VERSION=0.56.0
RUN set -eux; \
    pnpm add -g "@google/gemini-cli@${GEMINI_CLI_VERSION}"; \
    gemini --version

ARG CLAUDE_CODE_VERSION=2.1.238
RUN set -eux; \
    pnpm add -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}"; \
    claude_pkg="$(pnpm list -g --depth -1 --json @anthropic-ai/claude-code | jq -r '.[0].dependencies["@anthropic-ai/claude-code"].path')"; \
    node "${claude_pkg}/install.cjs"; \
    claude --version; \
    pnpm store prune; \
    chgrp -R devtools "${COREPACK_HOME}" "${PNPM_HOME}"; \
    chmod -R g+rwX,a+rX "${COREPACK_HOME}" "${PNPM_HOME}"; \
    find "${COREPACK_HOME}" "${PNPM_HOME}" -type d -exec chmod g+s {} +

ARG GROK_CLI_VERSION=1.0.21
ARG GROK_CLI_SHA256_AMD64=3a0bd1111628768b91c4ac550034565448309fe9ec2cb13b71dea90910dc9d98
ARG GROK_CLI_SHA256_ARM64=8a629e703cb08856fe7d837446bc225bcbb51c85f86fff0b0e0628cd89138582
RUN set -eux; \
    image_arch="${TARGETARCH:-$(dpkg --print-architecture)}"; \
    case "${image_arch}" in \
        amd64|x86_64) grok_arch="x86_64"; grok_sha256="${GROK_CLI_SHA256_AMD64}" ;; \
        arm64|aarch64) grok_arch="aarch64"; grok_sha256="${GROK_CLI_SHA256_ARM64}" ;; \
        *) echo "Unsupported image architecture for Grok CLI: ${image_arch}" >&2; exit 1 ;; \
    esac; \
    grok_url="https://x.ai/cli/grok-${GROK_CLI_VERSION}-linux-${grok_arch}"; \
    curl -fsSL "${grok_url}" -o /tmp/grok; \
    echo "${grok_sha256}  /tmp/grok" | sha256sum -c -; \
    install -m 0755 /tmp/grok /usr/local/bin/grok; \
    rm /tmp/grok; \
    grok --version

ARG CODEX_VERSION=rust-v0.149.0
ARG CODEX_SHA256_AMD64=7368b2055ed02157fea2695bb9f5af3ee7b0e40c5a3bebc81dfc596704244cfd
ARG CODEX_SHA256_ARM64=1cc3eb4c2fbab048c8afae0bebb1e54745f88d91e5249a448765d34a2a2ba9bb
ARG CODEX_CODE_MODE_HOST_SHA256_AMD64=3600a45ac2b09fe3c995f4f49860131fea388b46c409c82a0266fc4d0342a04c
ARG CODEX_CODE_MODE_HOST_SHA256_ARM64=abf4a9a308d2c42e6fbb04a77704ac509c82cea5aa079848365be3fb65474b22
RUN set -eux; \
    image_arch="${TARGETARCH:-$(dpkg --print-architecture)}"; \
    case "${image_arch}" in \
        amd64|x86_64) \
            codex_target="x86_64-unknown-linux-musl"; \
            codex_sha256="${CODEX_SHA256_AMD64}"; \
            codex_code_mode_host_sha256="${CODEX_CODE_MODE_HOST_SHA256_AMD64}" ;; \
        arm64|aarch64) \
            codex_target="aarch64-unknown-linux-musl"; \
            codex_sha256="${CODEX_SHA256_ARM64}"; \
            codex_code_mode_host_sha256="${CODEX_CODE_MODE_HOST_SHA256_ARM64}" ;; \
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
    host_asset="codex-code-mode-host-${codex_target}.tar.gz"; \
    host_url="https://github.com/openai/codex/releases/download/${CODEX_VERSION}/${host_asset}"; \
    curl -fsSL "${host_url}" -o /tmp/codex-code-mode-host.tar.gz; \
    echo "${codex_code_mode_host_sha256}  /tmp/codex-code-mode-host.tar.gz" | sha256sum -c -; \
    mkdir -p /tmp/codex-code-mode-host; \
    tar -xzf /tmp/codex-code-mode-host.tar.gz -C /tmp/codex-code-mode-host; \
    install -m 0755 "/tmp/codex-code-mode-host/codex-code-mode-host-${codex_target}" /usr/local/bin/codex-code-mode-host; \
    rm -rf /tmp/codex-code-mode-host /tmp/codex-code-mode-host.tar.gz; \
    codex --version; \
    test -x /usr/local/bin/codex-code-mode-host

ARG CURSOR_CLI_VERSION=2026.08.11-e8db854
ARG CURSOR_CLI_SHA256_AMD64=bfff4bf6f4e9dd30c1d0ef0a70b6077b074015dd2948e4c50685d53afdcfce5a
ARG CURSOR_CLI_SHA256_ARM64=ea13f92e295f523a99ce8d8f57d6894d21e5d1e2d030ffad718ccd5955ca2eed
RUN set -eux; \
    image_arch="${TARGETARCH:-$(dpkg --print-architecture)}"; \
    case "${image_arch}" in \
        amd64|x86_64) cursor_arch="x64"; cursor_sha256="${CURSOR_CLI_SHA256_AMD64}" ;; \
        arm64|aarch64) cursor_arch="arm64"; cursor_sha256="${CURSOR_CLI_SHA256_ARM64}" ;; \
        *) echo "Unsupported image architecture for Cursor CLI: ${image_arch}" >&2; exit 1 ;; \
    esac; \
    cursor_url="https://downloads.cursor.com/lab/${CURSOR_CLI_VERSION}/linux/${cursor_arch}/agent-cli-package.tar.gz"; \
    curl -fsSL "${cursor_url}" -o /tmp/cursor-agent.tar.gz; \
    echo "${cursor_sha256}  /tmp/cursor-agent.tar.gz" | sha256sum -c -; \
    cursor_dir="/usr/local/share/cursor-agent/versions/${CURSOR_CLI_VERSION}"; \
    mkdir -p "${cursor_dir}"; \
    tar --no-same-owner --strip-components=1 -xzf /tmp/cursor-agent.tar.gz -C "${cursor_dir}"; \
    ln -s "${cursor_dir}/cursor-agent" /usr/local/bin/agent; \
    ln -s "${cursor_dir}/cursor-agent" /usr/local/bin/cursor-agent; \
    rm /tmp/cursor-agent.tar.gz; \
    test "$(agent --version)" = "${CURSOR_CLI_VERSION}"; \
    test "$(cursor-agent --version)" = "${CURSOR_CLI_VERSION}"

# Google Cloud CLI is pinned to a concrete rapid-channel release. Keep this
# layer after language runtimes, Homebrew, and assistant CLIs so version bumps
# only rebuild this install and the cheap final setup.
ARG GCLOUD_CLI_VERSION=581.0.0
ARG GCLOUD_CLI_SHA256_AMD64=deffdbe82ca6e3d19ffb291d063a651488e04e1b33799b5a238e4b5c6784e3c6
ARG GCLOUD_CLI_SHA256_ARM64=22cfc09888525c6daadb8764388ce14e6c26baf80ab07938eacb08c2b4ae64c9
RUN set -eux; \
    image_arch="${TARGETARCH:-$(dpkg --print-architecture)}"; \
    case "${image_arch}" in \
        amd64|x86_64) gcloud_arch="x86_64"; gcloud_sha256="${GCLOUD_CLI_SHA256_AMD64}" ;; \
        arm64|aarch64) gcloud_arch="arm"; gcloud_sha256="${GCLOUD_CLI_SHA256_ARM64}" ;; \
        *) echo "Unsupported image architecture for gcloud CLI: ${image_arch}" >&2; exit 1 ;; \
    esac; \
    gcloud_file="google-cloud-cli-${GCLOUD_CLI_VERSION}-linux-${gcloud_arch}.tar.gz"; \
    curl -fsSL "https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/${gcloud_file}" -o "/tmp/${gcloud_file}"; \
    echo "${gcloud_sha256}  /tmp/${gcloud_file}" | sha256sum -c -; \
    tar -xzf "/tmp/${gcloud_file}" -C /usr/local --no-same-owner; \
    rm "/tmp/${gcloud_file}"; \
    test -x /usr/local/google-cloud-sdk/bin/gcloud; \
    printf 'export PATH="/usr/local/google-cloud-sdk/bin:${PATH}"\n' > /etc/profile.d/google-cloud-cli.sh; \
    chmod 0644 /etc/profile.d/google-cloud-cli.sh; \
    export PATH="/usr/local/google-cloud-sdk/bin:${PATH}"; \
    hash -r; \
    test "$(command -v gcloud)" = "/usr/local/google-cloud-sdk/bin/gcloud"; \
    gcloud_ver_out="$(gcloud version 2>&1)"; \
    printf '%s\n' "${gcloud_ver_out}"; \
    printf '%s\n' "${gcloud_ver_out}" | grep -F "Google Cloud SDK ${GCLOUD_CLI_VERSION}"
ENV PATH="/usr/local/google-cloud-sdk/bin:${PATH}"

RUN echo "%sudo ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/dev-users \
    && chmod 0440 /etc/sudoers.d/dev-users \
    && install -d -m 0755 /home/dev \
    && mkdir -p /workspace \
    && chmod 0777 /workspace

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
    groupadd -K GID_MIN=0 --gid "${gid}" "${group_name}"
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
    useradd -K UID_MIN=0 --uid "${uid}" --gid "${gid}" "${useradd_home_args[@]}" --shell /bin/bash "${user_name}"
elif [[ "${user_name}" != "${requested_name}" && "${LOCAL_ALLOW_EXISTING_USER:-0}" != "1" ]]; then
    echo "UID ${uid} already belongs to ${user_name}; set LOCAL_USER_NAME=${user_name} or LOCAL_ALLOW_EXISTING_USER=1 to use it." >&2
    exit 1
fi

home_dir="$(getent passwd "${user_name}" | cut -d: -f6)"
install -d -m 0755 -o "${uid}" -g "${gid}" "${home_dir}"
install -d -m 0700 -o "${uid}" -g "${gid}" "${home_dir}/.codex"
install -d -m 0700 -o "${uid}" -g "${gid}" "${home_dir}/.ssh"
chown -R "${uid}:${gid}" "${home_dir}/.codex" 2>/dev/null || true
chown -R "${uid}:${gid}" "${home_dir}/.ssh" 2>/dev/null || true
mkdir -p "${workspace}"
install -d -m 0775 -o "${uid}" -g "${gid}" /go /go/bin /go/pkg

if [[ ! -f "${home_dir}/.bashrc" && -f /etc/skel/.bashrc ]]; then
    cp /etc/skel/.bashrc "${home_dir}/.bashrc"
    chown "${uid}:${gid}" "${home_dir}/.bashrc"
elif [[ ! -f "${home_dir}/.bashrc" ]]; then
    install -m 0644 -o "${uid}" -g "${gid}" /dev/null "${home_dir}/.bashrc"
fi

bashrc="${home_dir}/.bashrc"
if ! grep -Fq '# >>> env dev prompt >>>' "${bashrc}"; then
    if ! cat >> "${bashrc}" <<'PROMPT'

# >>> env dev prompt >>>
if [[ "${DEV_CONTAINER_DISABLE_PS1:-0}" != "1" ]]; then
    case $- in
        *i*) PS1="${DEV_CONTAINER_PS1:-# }" ;;
    esac
fi
# <<< env dev prompt <<<
PROMPT
    then
        echo "warning: could not update ${bashrc} with dev prompt" >&2
    fi
fi

if [[ ! -f "${home_dir}/.codex/config.toml" && -f /etc/skel/.codex/config.toml ]]; then
    cp /etc/skel/.codex/config.toml "${home_dir}/.codex/config.toml"
    chown "${uid}:${gid}" "${home_dir}/.codex/config.toml"
    chmod 0600 "${home_dir}/.codex/config.toml"
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
            groupadd -K GID_MIN=0 --gid "${docker_gid}" "${docker_group}"
        fi
        usermod -aG "${docker_group}" "${user_name}"
    fi
fi

export HOME="${home_dir}"
export CODEX_HOME="${home_dir}/.codex"
export USER="${user_name}"
export LOGNAME="${user_name}"
export SHELL=/bin/bash

exec gosu "${user_name}" "$@"
SCRIPT
chmod 0755 /usr/local/bin/dev-entrypoint
EOF

# Runtime-only defaults stay late so simple CLI-experience tweaks do not
# invalidate the expensive tool installation layers.
ENV PGDATA=/workspace/.postgres-data \
    TERM=xterm-256color

WORKDIR /workspace
ENTRYPOINT ["dev-entrypoint"]
CMD ["bash"]
