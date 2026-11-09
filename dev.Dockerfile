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
        time \
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
    && /usr/bin/time --version \
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

ARG GITHUB_CLI_VERSION=2.103.3
ARG GITHUB_CLI_SHA256_AMD64=4c806978ffce1cec70853302a56d70ac6da4f19bae7adca4e1a8ab00633dd91d
ARG GITHUB_CLI_SHA256_ARM64=ee32df2323c8847f5fac6cb6b4b69ca75828e9329a8f22f677021f7b3306ce63
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

# Blender is large and slow-moving. Keep it with the expensive runtimes so
# assistant CLI, gcloud, kubectl, Dagger CLI, Terraform, and herdr bumps do not rebuild it. Upstream publishes
# linux-x64 only; arm64 uses an unofficial portable Rocky Linux 8 build.
ARG BLENDER_VERSION=5.2.1
ARG BLENDER_SHA256_AMD64=a31f524fa99a527d3d52b7f5aaa68c34e1a19d5a1c9473f79c5cc610fd5b10e9
ARG BLENDER_ARM64_VERSION=5.1.0
ARG BLENDER_ARM64_ASSET=blender-5.1.0-git20260325.ae6d847d66fa-aarch64.tar.gz
ARG BLENDER_SHA256_ARM64=a4927219950566af13572e72f31b5bcb8baf87190ee86a26e2572ce7fd059793
RUN set -eux; \
    image_arch="${TARGETARCH:-$(dpkg --print-architecture)}"; \
    case "${image_arch}" in \
        amd64|x86_64) \
            blender_version="${BLENDER_VERSION}"; \
            blender_sha256="${BLENDER_SHA256_AMD64}"; \
            blender_major_minor="${BLENDER_VERSION%.*}"; \
            blender_file="blender-${BLENDER_VERSION}-linux-x64.tar.xz"; \
            blender_url="https://download.blender.org/release/Blender${blender_major_minor}/${blender_file}" ;; \
        arm64|aarch64) \
            blender_version="${BLENDER_ARM64_VERSION}"; \
            blender_sha256="${BLENDER_SHA256_ARM64}"; \
            blender_file="${BLENDER_ARM64_ASSET}"; \
            blender_url="https://github.com/lfdevs/blender-linux-arm64/releases/download/v${BLENDER_ARM64_VERSION}/${blender_file}" ;; \
        *) echo "Unsupported image architecture for Blender: ${image_arch}" >&2; exit 1 ;; \
    esac; \
    apt-get update; \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        libegl1 \
        libgl1 \
        libgomp1 \
        libice6 \
        libsm6 \
        libx11-6 \
        libxext6 \
        libxfixes3 \
        libxi6 \
        libxkbcommon0 \
        libxrender1 \
        libxxf86vm1; \
    rm -rf /var/lib/apt/lists/*; \
    curl -fsSL "${blender_url}" -o "/tmp/${blender_file}"; \
    echo "${blender_sha256}  /tmp/${blender_file}" | sha256sum -c -; \
    install -d -m 0755 /usr/local/blender; \
    tar --no-same-owner --strip-components=1 -xf "/tmp/${blender_file}" -C /usr/local/blender; \
    rm "/tmp/${blender_file}"; \
    test -x /usr/local/blender/blender; \
    ln -s /usr/local/blender/blender /usr/local/bin/blender; \
    hash -r; \
    test "$(command -v blender)" = "/usr/local/bin/blender"; \
    blender_ver_out="$(blender --factory-startup --version)"; \
    printf '%s\n' "${blender_ver_out}"; \
    printf '%s\n' "${blender_ver_out}" | grep -F "Blender ${blender_version}"; \
    blender --factory-startup -b --python-exit-code 1 --python-expr "import bpy; print(bpy.app.version_string)"

# OS libraries for the Playwright browsers shared from the host's ~/.cache/ms-playwright.
# Update with scripts/update-playwright.sh.
ARG PLAYWRIGHT_VERSION=1.65.0
RUN set -eux; \
    npx -y "playwright@${PLAYWRIGHT_VERSION}" install-deps chromium webkit; \
    rm -rf /var/lib/apt/lists/* /root/.npm

# Fast-moving assistant CLIs stay after the expensive language runtimes and Homebrew
# layers. Version bumps here should only rebuild these layers and cheap final setup.
ARG GEMINI_CLI_VERSION=0.56.0
RUN set -eux; \
    pnpm add -g "@google/gemini-cli@${GEMINI_CLI_VERSION}"; \
    gemini --version

ARG CLAUDE_CODE_VERSION=2.1.319
RUN set -eux; \
    pnpm add -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}"; \
    claude_pkg="$(pnpm list -g --depth -1 --json @anthropic-ai/claude-code | jq -r '.[0].dependencies["@anthropic-ai/claude-code"].path')"; \
    node "${claude_pkg}/install.cjs"; \
    claude_ver_out="$(claude --version)"; \
    printf '%s\n' "${claude_ver_out}"; \
    printf '%s\n' "${claude_ver_out}" | grep -F "${CLAUDE_CODE_VERSION}"; \
    pnpm store prune; \
    chgrp -R devtools "${COREPACK_HOME}" "${PNPM_HOME}"; \
    chmod -R g+rwX,a+rX "${COREPACK_HOME}" "${PNPM_HOME}"; \
    find "${COREPACK_HOME}" "${PNPM_HOME}" -type d -exec chmod g+s {} +

ARG GROK_CLI_VERSION=1.0.78
ARG GROK_CLI_SHA256_AMD64=8e59eb3e32ef1a185de8ec5ebed7b64d30986abd5e20923d1695accca6e0645b
ARG GROK_CLI_SHA256_ARM64=755da16ff70632c03820956decb5e98e7aeba9e345c2e03d8429cf004866f915
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

# Codex 0.157 starts its app server only from a complete local package.
# CODEX_SHA256_* are digests of codex-package-${target}.tar.gz, which contains
# bin/codex, bin/codex-code-mode-host, codex-package.json, codex-path/rg, and
# codex-resources/bwrap. Installing the bare codex-${target} binary alone
# makes `codex` exit with "this CLI has no complete local package".
ARG CODEX_VERSION=rust-v0.167.0
ARG CODEX_SHA256_AMD64=3bbf75e83de6b58aed28f2cf6e33ad423ec31fd4700a1457b94be557ea5a7c6e
ARG CODEX_SHA256_ARM64=0de261ecf1e7f3028a7952f03fca2093f749277d38590b78bb32f8567756bbb7
RUN set -eux; \
    image_arch="${TARGETARCH:-$(dpkg --print-architecture)}"; \
    case "${image_arch}" in \
        amd64|x86_64) \
            codex_target="x86_64-unknown-linux-musl"; \
            codex_sha256="${CODEX_SHA256_AMD64}" ;; \
        arm64|aarch64) \
            codex_target="aarch64-unknown-linux-musl"; \
            codex_sha256="${CODEX_SHA256_ARM64}" ;; \
        *) echo "Unsupported image architecture for Codex: ${image_arch}" >&2; exit 1 ;; \
    esac; \
    codex_version="${CODEX_VERSION#rust-v}"; \
    codex_asset="codex-package-${codex_target}.tar.gz"; \
    codex_url="https://github.com/openai/codex/releases/download/${CODEX_VERSION}/${codex_asset}"; \
    curl -fsSL "${codex_url}" -o /tmp/codex-package.tar.gz; \
    echo "${codex_sha256}  /tmp/codex-package.tar.gz" | sha256sum -c -; \
    codex_root="/usr/local/lib/codex/${codex_version}-${codex_target}"; \
    mkdir -p "${codex_root}"; \
    tar --no-same-owner -xzf /tmp/codex-package.tar.gz -C "${codex_root}"; \
    rm /tmp/codex-package.tar.gz; \
    test -f "${codex_root}/codex-package.json"; \
    test -x "${codex_root}/bin/codex"; \
    test -x "${codex_root}/bin/codex-code-mode-host"; \
    test -x "${codex_root}/codex-path/rg"; \
    test -x "${codex_root}/codex-resources/bwrap"; \
    ln -sfn "${codex_root}" /usr/local/lib/codex/current; \
    ln -sfn /usr/local/lib/codex/current/bin/codex /usr/local/bin/codex; \
    ln -sfn /usr/local/lib/codex/current/bin/codex-code-mode-host /usr/local/bin/codex-code-mode-host; \
    test "$(readlink -f /usr/local/bin/codex)" = "${codex_root}/bin/codex"; \
    test "$(codex --version)" = "codex-cli ${codex_version}"; \
    test -x /usr/local/bin/codex-code-mode-host

ARG CURSOR_CLI_VERSION=2026.11.05-86047df
ARG CURSOR_CLI_SHA256_AMD64=170b77786cbf4c93064d64fff12b71a178b968730561c64afc2e8e752535442e
ARG CURSOR_CLI_SHA256_ARM64=131554bfdbf683d8ebfef83a2bb46ac4e5d060f198711040b07ed063c2471871
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
# only rebuild this install and the cheap final setup. gke-gcloud-auth-plugin
# is a gcloud component, so it is installed here with `gcloud components
# install` rather than as a separately pinned CLI.
ARG GCLOUD_CLI_VERSION=592.0.0
ARG GCLOUD_CLI_SHA256_AMD64=2d841a23a681ab94486af6841e5f1cd123cd300fb8c4be6ba5b51350fca3d50b
ARG GCLOUD_CLI_SHA256_ARM64=ba588759c4c42122a8c14536009738c0f0030989ca75788235f9956555e44f4d
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
    printf '%s\n' "${gcloud_ver_out}" | grep -F "Google Cloud SDK ${GCLOUD_CLI_VERSION}"; \
    CLOUDSDK_CORE_DISABLE_PROMPTS=1 gcloud components install --quiet gke-gcloud-auth-plugin; \
    test -x /usr/local/google-cloud-sdk/bin/gke-gcloud-auth-plugin; \
    hash -r; \
    test "$(command -v gke-gcloud-auth-plugin)" = "/usr/local/google-cloud-sdk/bin/gke-gcloud-auth-plugin"; \
    plugin_ver_out="$(gke-gcloud-auth-plugin --version)"; \
    printf '%s\n' "${plugin_ver_out}"; \
    test -n "${plugin_ver_out}"
ENV PATH="/usr/local/google-cloud-sdk/bin:${PATH}"

# kubectl is pinned to a concrete Kubernetes release. Keep this layer after
# gcloud so version bumps only rebuild this install and the cheap final setup.
ARG KUBECTL_VERSION=v1.37.2
ARG KUBECTL_SHA256_AMD64=c04487523e7aa7d1493f7808174c899db93d7a9cf57531420cd76b9bd415f8f4
ARG KUBECTL_SHA256_ARM64=fcc16f63186659d9722014b7e02d5fdd2d4e669cb8c0ab66365d7d3b8ba03509
RUN set -eux; \
    image_arch="${TARGETARCH:-$(dpkg --print-architecture)}"; \
    case "${image_arch}" in \
        amd64|x86_64) kubectl_arch="amd64"; kubectl_sha256="${KUBECTL_SHA256_AMD64}" ;; \
        arm64|aarch64) kubectl_arch="arm64"; kubectl_sha256="${KUBECTL_SHA256_ARM64}" ;; \
        *) echo "Unsupported image architecture for kubectl: ${image_arch}" >&2; exit 1 ;; \
    esac; \
    kubectl_url="https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${kubectl_arch}/kubectl"; \
    curl -fsSL "${kubectl_url}" -o /tmp/kubectl; \
    echo "${kubectl_sha256}  /tmp/kubectl" | sha256sum -c -; \
    install -m 0755 /tmp/kubectl /usr/local/bin/kubectl; \
    rm /tmp/kubectl; \
    test -x /usr/local/bin/kubectl; \
    hash -r; \
    test "$(command -v kubectl)" = "/usr/local/bin/kubectl"; \
    kubectl_ver_out="$(kubectl version --client=true)"; \
    printf '%s\n' "${kubectl_ver_out}"; \
    printf '%s\n' "${kubectl_ver_out}" | grep -F "Client Version: ${KUBECTL_VERSION}"

# Dagger CLI tracks the newest v1.0.0-beta.N release. Keep this layer after
# kubectl so version bumps only rebuild this install and the cheap final setup.
ARG DAGGER_CLI_VERSION=v1.0.0-beta.25
ARG DAGGER_CLI_SHA256_AMD64=32405fd37daa95d9444e9faf66b9d6bd1ddd1580916f145fa2fc6f3cec6e7b69
ARG DAGGER_CLI_SHA256_ARM64=0f5abed7003cfaa2b6bcbb85286c802d0119336a805f54589f3859c9a4f02b0a
RUN set -eux; \
    image_arch="${TARGETARCH:-$(dpkg --print-architecture)}"; \
    case "${image_arch}" in \
        amd64|x86_64) dagger_arch="amd64"; dagger_sha256="${DAGGER_CLI_SHA256_AMD64}" ;; \
        arm64|aarch64) dagger_arch="arm64"; dagger_sha256="${DAGGER_CLI_SHA256_ARM64}" ;; \
        *) echo "Unsupported image architecture for Dagger CLI: ${image_arch}" >&2; exit 1 ;; \
    esac; \
    dagger_version="${DAGGER_CLI_VERSION#v}"; \
    dagger_file="dagger_${DAGGER_CLI_VERSION}_linux_${dagger_arch}.tar.gz"; \
    curl -fsSL "https://dl.dagger.io/dagger/releases/${dagger_version}/${dagger_file}" -o "/tmp/${dagger_file}"; \
    echo "${dagger_sha256}  /tmp/${dagger_file}" | sha256sum -c -; \
    mkdir -p /tmp/dagger-cli; \
    tar --no-same-owner -xzf "/tmp/${dagger_file}" -C /tmp/dagger-cli; \
    install -m 0755 /tmp/dagger-cli/dagger /usr/local/bin/dagger; \
    rm -rf /tmp/dagger-cli "/tmp/${dagger_file}"; \
    test -x /usr/local/bin/dagger; \
    hash -r; \
    test "$(command -v dagger)" = "/usr/local/bin/dagger"; \
    dagger_ver_out="$(dagger version)"; \
    printf '%s\n' "${dagger_ver_out}"; \
    printf '%s\n' "${dagger_ver_out}" | grep -F "${DAGGER_CLI_VERSION}"

# Terraform is pinned to a concrete stable HashiCorp release. Keep this layer
# after the Dagger CLI so version bumps only rebuild this install and the cheap
# final setup.
ARG TERRAFORM_VERSION=1.17.1
ARG TERRAFORM_SHA256_AMD64=4638628058e71a55212b1c563712eac03b902128f40740f3dc8174df12135061
ARG TERRAFORM_SHA256_ARM64=988e950a1c23058093b0e66ab2d5fb53fc18345ecfbd5871acf51dbac9325edd
RUN set -eux; \
    image_arch="${TARGETARCH:-$(dpkg --print-architecture)}"; \
    case "${image_arch}" in \
        amd64|x86_64) terraform_arch="amd64"; terraform_sha256="${TERRAFORM_SHA256_AMD64}" ;; \
        arm64|aarch64) terraform_arch="arm64"; terraform_sha256="${TERRAFORM_SHA256_ARM64}" ;; \
        *) echo "Unsupported image architecture for Terraform: ${image_arch}" >&2; exit 1 ;; \
    esac; \
    terraform_file="terraform_${TERRAFORM_VERSION}_linux_${terraform_arch}.zip"; \
    curl -fsSL "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/${terraform_file}" -o "/tmp/${terraform_file}"; \
    echo "${terraform_sha256}  /tmp/${terraform_file}" | sha256sum -c -; \
    mkdir -p /tmp/terraform-cli; \
    unzip -oq "/tmp/${terraform_file}" -d /tmp/terraform-cli; \
    install -m 0755 /tmp/terraform-cli/terraform /usr/local/bin/terraform; \
    rm -rf /tmp/terraform-cli "/tmp/${terraform_file}"; \
    test -x /usr/local/bin/terraform; \
    hash -r; \
    test "$(command -v terraform)" = "/usr/local/bin/terraform"; \
    terraform_ver_out="$(CHECKPOINT_DISABLE=1 terraform version)"; \
    printf '%s\n' "${terraform_ver_out}"; \
    printf '%s\n' "${terraform_ver_out}" | grep -F "Terraform v${TERRAFORM_VERSION}"

# herdr is pinned to a concrete stable release. Keep this layer after
# Terraform so version bumps only rebuild this install and the cheap final
# setup. The archives are the static Linux binaries named by the herdr.dev
# release manifest.
ARG HERDR_VERSION=0.9.5
ARG HERDR_SHA256_AMD64=14d9e8bc8b4a9e0118d77c32266f76d461f09b40342eb23752960bd89f59929d
ARG HERDR_SHA256_ARM64=17d7536f2da50859523680ef279dffcac8e4a235f4e46fe8da6c2ec44141897c
RUN set -eux; \
    image_arch="${TARGETARCH:-$(dpkg --print-architecture)}"; \
    case "${image_arch}" in \
        amd64|x86_64) herdr_target="linux-x86_64"; herdr_sha256="${HERDR_SHA256_AMD64}" ;; \
        arm64|aarch64) herdr_target="linux-aarch64"; herdr_sha256="${HERDR_SHA256_ARM64}" ;; \
        *) echo "Unsupported image architecture for herdr: ${image_arch}" >&2; exit 1 ;; \
    esac; \
    herdr_file="herdr-${herdr_target}"; \
    curl -fsSL "https://github.com/herdrdev/herdr/releases/download/v${HERDR_VERSION}/${herdr_file}" -o "/tmp/${herdr_file}"; \
    echo "${herdr_sha256}  /tmp/${herdr_file}" | sha256sum -c -; \
    install -m 0755 "/tmp/${herdr_file}" /usr/local/bin/herdr; \
    rm "/tmp/${herdr_file}"; \
    test -x /usr/local/bin/herdr; \
    hash -r; \
    test "$(command -v herdr)" = "/usr/local/bin/herdr"; \
    herdr_ver_out="$(herdr --version)"; \
    printf '%s\n' "${herdr_ver_out}"; \
    printf '%s\n' "${herdr_ver_out}" | grep -Fx "herdr ${HERDR_VERSION}"

# herdr-core (hc) is the server the Herdr desktop app talks to. It is pinned
# the same way, right after herdr. The release manifest at
# releases.herdr.dev/core/<version>/manifest.json publishes the archive
# digests. The archive holds the static binary plus two license files; only
# the binary is installed, with the hc symlink beside it.
ARG HERDR_CORE_VERSION=0.1.19
ARG HERDR_CORE_SHA256_AMD64=4adcfb423d52f24c5cc4a1e2cd2fcad1f62d28bb77876ac472c29082a3eaa424
ARG HERDR_CORE_SHA256_ARM64=f95c34fd7177ed58807d74fe4ee78bb3dc73eb37f21c69496064000a21abcb10
RUN set -eux; \
    image_arch="${TARGETARCH:-$(dpkg --print-architecture)}"; \
    case "${image_arch}" in \
        amd64|x86_64) herdr_core_target="linux-x86_64"; herdr_core_sha256="${HERDR_CORE_SHA256_AMD64}" ;; \
        arm64|aarch64) herdr_core_target="linux-aarch64"; herdr_core_sha256="${HERDR_CORE_SHA256_ARM64}" ;; \
        *) echo "Unsupported image architecture for herdr-core: ${image_arch}" >&2; exit 1 ;; \
    esac; \
    herdr_core_file="herdr-core-${herdr_core_target}.tar.gz"; \
    curl -fsSL "https://releases.herdr.dev/core/${HERDR_CORE_VERSION}/${herdr_core_file}" -o "/tmp/${herdr_core_file}"; \
    echo "${herdr_core_sha256}  /tmp/${herdr_core_file}" | sha256sum -c -; \
    mkdir -p /tmp/herdr-core; \
    tar -xzf "/tmp/${herdr_core_file}" -C /tmp/herdr-core herdr-core; \
    install -m 0755 /tmp/herdr-core/herdr-core /usr/local/bin/herdr-core; \
    ln -sfn herdr-core /usr/local/bin/hc; \
    rm -rf /tmp/herdr-core "/tmp/${herdr_core_file}"; \
    test -x /usr/local/bin/herdr-core; \
    hash -r; \
    test "$(command -v hc)" = "/usr/local/bin/hc"; \
    herdr_core_ver_out="$(hc --version)"; \
    printf '%s\n' "${herdr_core_ver_out}"; \
    printf '%s\n' "${herdr_core_ver_out}" | grep -Fx "hc ${HERDR_CORE_VERSION}"

# devenv runs each container as a Herdr machine: sshd is the main process
# and tini is PID 1 in front of the entrypoint. The host keys the package
# generates at build time are deleted; dev-entrypoint installs the per-user
# host key from /devenv/herdr on every start so a recreated container keeps
# its identity.
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        openssh-server \
        tini \
    && rm -rf /var/lib/apt/lists/* \
    && rm -f /etc/ssh/ssh_host_* \
    && test -x /usr/sbin/sshd \
    && test -x /usr/bin/tini

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
    echo "dev-entrypoint must start as root; devenv starts this image with its default user" >&2
    exit 1
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

# Claude Code has no system defaults layer below user settings, so seed its
# default permission mode unless the user already picked one. Pre-accepting the
# bypass dialog keeps the first launch from stopping on it.
claude_dir="${home_dir}/.claude"
claude_settings="${claude_dir}/settings.json"
if [[ ! -d "${claude_dir}" ]]; then
    install -d -m 0700 -o "${uid}" -g "${gid}" "${claude_dir}"
fi
if [[ ! -s "${claude_settings}" ]]; then
    install -m 0600 -o "${uid}" -g "${gid}" /dev/null "${claude_settings}"
    printf '{}\n' > "${claude_settings}"
fi
if jq -e '.permissions.defaultMode == null' "${claude_settings}" >/dev/null 2>&1; then
    if claude_seeded="$(jq '.permissions.defaultMode = "bypassPermissions" | .skipDangerousModePermissionPrompt //= true' "${claude_settings}")"; then
        printf '%s\n' "${claude_seeded}" > "${claude_settings}"
    else
        echo "warning: could not set Claude Code default permission mode in ${claude_settings}" >&2
    fi
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

sqlite_home="${CODEX_SQLITE_HOME:-/var/lib/codex-sqlite}"
install -d -m 0700 -o "${uid}" -g "${gid}" "${sqlite_home}"
# Bind-mounted ~/.codex on macOS is too slow for Codex's SQLite logs.
# Oversized logs_2.sqlite stalls TUI startup on "loading" the model.
codex_logs="${home_dir}/.codex/logs_2.sqlite"
codex_logs_size=0
if [[ -f "${codex_logs}" ]]; then
    codex_logs_size="$(stat -c '%s' "${codex_logs}" 2>/dev/null || echo 0)"
fi
if [[ -f "${codex_logs}-wal" ]]; then
    codex_logs_size="$((codex_logs_size + $(stat -c '%s' "${codex_logs}-wal" 2>/dev/null || echo 0)))"
fi
if [[ "${codex_logs_size}" -gt 1073741824 ]]; then
    stamp="$(date -u +%Y%m%dT%H%M%SZ)"
    echo "warning: Codex logs are $((codex_logs_size / 1024 / 1024))MiB; moving them aside so startup is not blocked" >&2
    mv -f "${codex_logs}" "${codex_logs}.stale-${stamp}" 2>/dev/null || true
    mv -f "${codex_logs}-wal" "${codex_logs}-wal.stale-${stamp}" 2>/dev/null || true
    mv -f "${codex_logs}-shm" "${codex_logs}-shm.stale-${stamp}" 2>/dev/null || true
fi

# Serve mode. The container is a Herdr machine: sshd is the main process and
# the Herdr server runs as the container user. There is no shell to exec.
devenv_dir="${DEVENV_DIR:-/devenv}"
pane_cwd="${DEVENV_PANE_CWD:-${workspace}}"
herdr_volume="${DEVENV_HERDR_VOLUME:-/var/lib/devenv/herdr}"
image_path="${PATH}"

for required in \
    "${devenv_dir}/herdr/ssh_host_ed25519_key" \
    "${devenv_dir}/herdr/ssh_host_ed25519_key.pub" \
    "${devenv_dir}/herdr/id_ed25519.pub"; do
    if [[ ! -f "${required}" ]]; then
        echo "missing ${required}; start this container with 'dev up' so devenv mounts its Herdr keys" >&2
        exit 1
    fi
done

# sshd runs with UsePAM no and refuses a locked account itself. useradd wrote
# '!' into the shadow entry; '*' has no valid hash, so password login stays
# impossible. Any other value, such as a real hash on a pre-existing user,
# is left alone.
shadow_password="$(getent shadow "${user_name}" | cut -d: -f2)"
if [[ "${shadow_password}" == '!'* ]]; then
    usermod -p '*' "${user_name}"
fi

# Keys live on /run, a real Linux filesystem, so sshd's owner and mode checks
# pass. The macOS bind mount of ~/.devenv is the wrong place for them. They
# are copied on every start, so a recreated container presents the same key.
install -d -m 0755 -o root -g root /run/devenv /run/sshd
install -m 0600 -o root -g root "${devenv_dir}/herdr/ssh_host_ed25519_key" /run/devenv/ssh_host_ed25519_key
install -m 0644 -o root -g root "${devenv_dir}/herdr/ssh_host_ed25519_key.pub" /run/devenv/ssh_host_ed25519_key.pub
install -m 0600 -o "${uid}" -g "${gid}" "${devenv_dir}/herdr/id_ed25519.pub" /run/devenv/authorized_keys

# OpenSSH 9.2 keeps only the first SetEnv directive, so every variable goes
# on that one line. This is what an SSH-started herdr server inherits.
session_env="HOME=${home_dir} USER=${user_name} LOGNAME=${user_name} SHELL=/bin/bash"
session_env+=" CODEX_HOME=${home_dir}/.codex CODEX_SQLITE_HOME=${sqlite_home}"
for name in DOCKER_HOST GIT_CONFIG_GLOBAL; do
    if [[ -n "${!name:-}" ]]; then
        session_env+=" ${name}=${!name}"
    fi
done
session_env+=" PATH=${image_path}"
cat > /etc/ssh/sshd_config.d/devenv.conf <<SSHD_CONF
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
UseDNS no
UsePAM no
PrintMotd no
PrintLastLog no
Banner none
PermitUserRC no
PermitUserEnvironment no
AllowUsers ${user_name}
AuthorizedKeysFile /run/devenv/authorized_keys
HostKey /run/devenv/ssh_host_ed25519_key
PidFile /run/sshd.pid
SetEnv ${session_env}
SSHD_CONF
/usr/sbin/sshd -t

# Herdr config, sockets, and state live on the per-worktree volume. The home
# is shared by every container, so a symlink there resolves per container.
# XDG_CONFIG_HOME is never set: gh, git, and other XDG-aware tools in every
# pane would follow it onto the volume.
install -d -m 0755 "${herdr_volume}"
chown "${uid}:${gid}" "${herdr_volume}"
install -d -m 0700 -o "${uid}" -g "${gid}" "${herdr_volume}/herdr" "${herdr_volume}/state" "${herdr_volume}/core-state"

ensure_user_dir() {
    if [[ ! -d "$1" ]]; then
        install -d -m 0755 -o "${uid}" -g "${gid}" "$1"
    fi
}

link_herdr_dir() {
    local link="$1" target="$2"
    if [[ -L "${link}" ]]; then
        if [[ "$(readlink "${link}")" == "${target}" ]]; then
            return 0
        fi
        rm -f "${link}"
    elif [[ -e "${link}" ]]; then
        local aside="${link}.pre-devenv-$(date -u +%Y%m%dT%H%M%SZ)"
        echo "warning: moving ${link} to ${aside}; Herdr state now lives on the per-worktree volume" >&2
        mv "${link}" "${aside}"
    fi
    ln -s "${target}" "${link}"
    chown -h "${uid}:${gid}" "${link}"
}

ensure_user_dir "${home_dir}/.config"
link_herdr_dir "${home_dir}/.config/herdr" "${herdr_volume}/herdr"
ensure_user_dir "${home_dir}/.local"
ensure_user_dir "${home_dir}/.local/state"
link_herdr_dir "${home_dir}/.local/state/herdr" "${herdr_volume}/state"
# herdr-core keeps its identity (core.json), state, and socket under
# ~/.local/state/herdr-core. The Mac's core pins that identity, so it has to
# survive dev down and dev up on the per-worktree volume.
link_herdr_dir "${home_dir}/.local/state/herdr-core" "${herdr_volume}/core-state"

# Herdr's default new_cwd is "follow", which starts the first pane in $HOME.
# A fixed path puts it in the worktree. The file is written once; the server
# updates it afterwards.
herdr_config="${herdr_volume}/herdr/config.toml"
if [[ ! -f "${herdr_config}" ]]; then
    install -m 0644 -o "${uid}" -g "${gid}" /dev/null "${herdr_config}"
    printf 'onboarding = false\n\n[terminal]\nnew_cwd = "%s"\n' "${pane_cwd}" > "${herdr_config}"
fi

# herdr server stays in the foreground. The loop restarts it when it dies
# and stays out of the way when a client already started one over SSH:
# a second start fails with "already running". setsid makes the server its
# own session leader, which is how Herdr tells a server that survives SSH
# disconnects from one that would get SIGHUP; without it, machine add asks
# to restart the server. -w keeps the loop waiting on the server's exit.
herdr_env=(
    "HOME=${home_dir}"
    "USER=${user_name}"
    "LOGNAME=${user_name}"
    "SHELL=/bin/bash"
    "CODEX_HOME=${home_dir}/.codex"
    "CODEX_SQLITE_HOME=${sqlite_home}"
    "PATH=${image_path}"
)
for name in DOCKER_HOST GIT_CONFIG_GLOBAL; do
    if [[ -n "${!name:-}" ]]; then
        herdr_env+=("${name}=${!name}")
    fi
done

herdr_server_running() {
    gosu "${user_name}" env "${herdr_env[@]}" herdr status server 2>/dev/null | grep -q '^status: running'
}

supervise_herdr_server() {
    local status
    while true; do
        if herdr_server_running; then
            sleep 10
            continue
        fi
        echo "devenv: starting herdr server" >&2
        status=0
        setsid -w gosu "${user_name}" env "${herdr_env[@]}" herdr server </dev/null || status=$?
        echo "devenv: herdr server exited with status ${status}" >&2
        sleep 3
    done
}

# herdr-core (hc) is the server the Herdr desktop app talks to. The app
# opens new terminals in the core's working directory, so the core starts
# here, from the pane directory, instead of waiting for the Mac's core to
# start it over SSH from the home. hc server start detaches the core into
# its own session and returns at once; when a core is already running, in
# any directory, it only reports it. Every hc command auto-starts a missing
# core, so the loop keeps the directory right after an hc server stop too.
# It warns "no systemd user manager here" on each start; that is expected.
start_hc_core() {
    (cd "${pane_cwd}" 2>/dev/null || cd /
     gosu "${user_name}" env "${herdr_env[@]}" hc server start >/dev/null </dev/null) ||
        echo "devenv: hc server start failed" >&2
}

supervise_hc_core() {
    while true; do
        start_hc_core
        sleep 10
    done
}

cd "${pane_cwd}" 2>/dev/null || cd /
supervise_herdr_server &
supervise_hc_core &

exec /usr/sbin/sshd -D -e
SCRIPT
chmod 0755 /usr/local/bin/dev-entrypoint
EOF

# Codex 0.153 looks for the code-mode helper under libexec. SQLite state is
# kept off the macOS home bind mount so large logs_2.sqlite files do not stall
# TUI startup on "loading" the model.
RUN set -eux; \
    install -d -m 0755 /usr/local/libexec; \
    ln -sfn ../bin/codex-code-mode-host /usr/local/libexec/codex-code-mode-host; \
    test -x /usr/local/bin/codex-code-mode-host; \
    test -x /usr/local/libexec/codex-code-mode-host; \
    install -d -m 1777 /var/lib/codex-sqlite

# Assistant CLIs default to their allow-all mode because the container is the
# isolation boundary. Codex and Grok read system config that user config still
# overrides. Gemini only accepts YOLO as a flag (and not on subcommands), and
# Cursor always writes its approval mode into ~/.cursor, so wrappers ahead of
# PATH add the flag unless the caller already chose a mode. Claude Code is
# seeded by dev-entrypoint. The profile.d name sorts last so login shells also
# put the wrappers ahead of pnpm.
RUN <<'EOF'
set -eux
install -d -m 0755 /etc/codex /etc/grok /usr/local/lib/agent-defaults/bin
printf '%s\n' \
    'sandbox_mode = "danger-full-access"' \
    'approval_policy = "never"' \
    > /etc/codex/config.toml
printf '%s\n' \
    '[ui]' \
    'permission_mode = "always-approve"' \
    > /etc/grok/managed_config.toml
chmod 0644 /etc/codex/config.toml /etc/grok/managed_config.toml

cat > /usr/local/lib/agent-defaults/bin/gemini <<'SCRIPT'
#!/bin/sh
real=/usr/local/share/pnpm/bin/gemini
case "${1:-}" in
    mcp|extensions|extension|skills|skill|hooks|hook|gemma) exec "${real}" "$@" ;;
esac
for arg in "$@"; do
    case "${arg}" in
        -y|--yolo|--approval-mode|--approval-mode=*) exec "${real}" "$@" ;;
    esac
done
exec "${real}" --approval-mode=yolo "$@"
SCRIPT

cat > /usr/local/lib/agent-defaults/bin/cursor-agent <<'SCRIPT'
#!/bin/sh
real="/usr/local/bin/$(basename "$0")"
for arg in "$@"; do
    case "${arg}" in
        -f|--force|--yolo|--auto-review) exec "${real}" "$@" ;;
    esac
done
exec "${real}" --yolo "$@"
SCRIPT

chmod 0755 /usr/local/lib/agent-defaults/bin/gemini /usr/local/lib/agent-defaults/bin/cursor-agent
ln -sfn cursor-agent /usr/local/lib/agent-defaults/bin/agent
printf 'export PATH="/usr/local/lib/agent-defaults/bin:${PATH}"\n' > /etc/profile.d/zz-agent-defaults.sh
chmod 0644 /etc/profile.d/zz-agent-defaults.sh
export PATH="/usr/local/lib/agent-defaults/bin:${PATH}"
hash -r
test "$(command -v gemini)" = /usr/local/lib/agent-defaults/bin/gemini
test "$(command -v agent)" = /usr/local/lib/agent-defaults/bin/agent
test "$(command -v cursor-agent)" = /usr/local/lib/agent-defaults/bin/cursor-agent
gemini --version
agent --version
cursor-agent --version
EOF
ENV PATH="/usr/local/lib/agent-defaults/bin:${PATH}"

# Runtime-only defaults stay late so simple CLI-experience tweaks do not
# invalidate the expensive tool installation layers.
ENV PGDATA=/workspace/.postgres-data \
    CODEX_SQLITE_HOME=/var/lib/codex-sqlite \
    TERM=xterm-256color

WORKDIR /workspace
ENTRYPOINT ["tini", "--", "/usr/local/bin/dev-entrypoint"]
