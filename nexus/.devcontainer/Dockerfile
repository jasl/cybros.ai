# The Rails Ruby feature in devcontainer.json installs the project's version.
FROM mcr.microsoft.com/devcontainers/base:2-trixie

# Ensure binding is always 0.0.0.0
# Binds the server to all IP addresses of the container, so it can be accessed from outside the container.
ENV BINDING="0.0.0.0"

# BUN, BECAUSE `bin/setup` RUNS `bun install`. Without it this container's own
# postCreateCommand aborts with Errno::ENOENT before it reaches the database,
# so the devcontainer has never come up. Same installer and same default
# version as the app image; override with `--build-arg BUN_VERSION=…`.
#
# ROOT TO INSTALL, `vscode` TO WORK: installation writes to /usr/local, and
# the devcontainer hands the session back to its unprivileged user. The
# symlink is not decoration either — this image's login shells
# rebuild PATH from /etc/profile, so an `ENV PATH` alone leaves `bun` unfound
# in exactly the shell a person opens.
ENV BUN_INSTALL=/usr/local/bun
ENV PATH=/usr/local/bun/bin:$PATH
ARG BUN_VERSION=1.4.2
USER root
RUN curl -fsSL https://bun.sh/install | bash -s -- "bun-v${BUN_VERSION}" && \
    chmod -R a+rX /usr/local/bun && \
    ln -s /usr/local/bun/bin/bun /usr/local/bin/bun
USER vscode
