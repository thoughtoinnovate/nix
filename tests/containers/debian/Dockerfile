FROM debian:13-slim@sha256:020c0d20b9880058cbe785a9db107156c3c75c2ac944a6aa7ab59f2add76a7bd

# Refresh the digest with:
# docker buildx imagetools inspect debian:13-slim --format '{{json .Manifest.Digest}}'
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      bash ca-certificates coreutils curl git jq passwd rsync sudo xz-utils \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --create-home --shell /bin/bash homeweave

COPY install-nix.sh /tmp/install-nix.sh
RUN bash /tmp/install-nix.sh \
    && rm -f /tmp/install-nix.sh \
    && printf 'homeweave ALL=(ALL) NOPASSWD: ALL\n' >/etc/sudoers.d/homeweave \
    && chmod 0440 /etc/sudoers.d/homeweave

ENV HOME_WEAVE_CONTAINER_DISTRO=debian
ENV PATH="/nix/var/nix/profiles/default/bin:${PATH}"
