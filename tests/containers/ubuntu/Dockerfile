FROM ubuntu:24.04@sha256:4fbb8e6a8395de5a7550b33509421a2bafbc0aab6c06ba2cef9ebffbc7092d90

# Refresh the digest with:
# docker buildx imagetools inspect ubuntu:24.04 --format '{{json .Manifest.Digest}}'
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

ENV HOME_WEAVE_CONTAINER_DISTRO=ubuntu
ENV PATH="/nix/var/nix/profiles/default/bin:${PATH}"
