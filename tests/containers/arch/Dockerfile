FROM archlinux:base-20260712.0.555161@sha256:fe6972d4dc1f660c0c10f4c41b2de8986bab89e7e2955378f8beadb8ebcd7433

# Refresh the digest with:
# docker buildx imagetools inspect archlinux:base-20260712.0.555161 --format '{{json .Manifest.Digest}}'
RUN pacman -Syu --noconfirm --needed \
      bash ca-certificates coreutils curl git jq rsync sudo xz \
    && pacman -Scc --noconfirm \
    && useradd --create-home --shell /bin/bash homeweave

COPY install-nix.sh /tmp/install-nix.sh
RUN bash /tmp/install-nix.sh \
    && rm -f /tmp/install-nix.sh \
    && printf 'homeweave ALL=(ALL) NOPASSWD: ALL\n' >/etc/sudoers.d/homeweave \
    && chmod 0440 /etc/sudoers.d/homeweave

ENV HOME_WEAVE_CONTAINER_DISTRO=arch
ENV PATH="/nix/var/nix/profiles/default/bin:${PATH}"
