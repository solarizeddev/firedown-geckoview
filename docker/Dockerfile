# Build environment for the Firedown GeckoView AAR.
#
# WHY a container: the dev host (Arch) ships a bleeding-edge glibc that breaks
# Firefox's vendored glsl-optimizer (C11/C23 `once_flag`/`call_once` collide with
# its bundled shim). A stable base image with an OLDER glibc + the normal
# `mach bootstrap` toolchain (Mozilla's tested clang/sysroot/wasi/SDK/NDK)
# sidesteps that whole class of failure and is reproducible. Inside here the build
# runs the FULL bootstrap path (the reuse-existing-SDK/NDK env vars are not set),
# so nothing host-specific leaks in.
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
# Host build prerequisites. `mach bootstrap` fetches the heavy Android toolchain
# (clang/sysroot/wasi/SDK/NDK) itself, but it does NOT reliably provide the base
# host build tools on a minimal image — configure needs `make`/`gmake`, a host
# compiler, pkg-config, m4, etc. — so install build-essential & friends here.
# curl/git/python for fetch+bootstrap; sudo so bootstrap can apt-install anything
# else; locales for a UTF-8 build locale.
#
# Keep /var/lib/apt/lists (do NOT `rm` it): `mach bootstrap` runs its own
# `apt-get install`, which fails with empty package lists.
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl wget git mercurial \
      python3 python3-pip python3-venv python3-dev \
      build-essential make pkg-config m4 gawk \
      sudo locales file unzip zip xz-utils \
    && locale-gen en_US.UTF-8
ENV LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

# A non-root build user — `mach bootstrap` refuses to run as root. UID/GID are
# matched to the host caller at image-build time (build-args) so the bind-mounted
# caches (~/.mozbuild, ~/.cargo, ~/.m2, the gecko checkout) stay writable from
# both sides.
ARG UID=1000
ARG GID=1000
RUN (groupadd -g "${GID}" builder || true) \
    && useradd -m -u "${UID}" -g "${GID}" -s /bin/bash builder \
    && echo 'builder ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/builder \
    && chmod 0440 /etc/sudoers.d/builder

USER builder
WORKDIR /work/src
