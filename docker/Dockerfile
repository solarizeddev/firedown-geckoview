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
# Minimal host packages — `mach bootstrap` installs the actual build toolchain
# itself (it knows apt). curl/git/python for fetch+bootstrap; sudo so bootstrap
# can apt-install; locales because the build wants a UTF-8 locale; ca-certificates
# for HTTPS fetches.
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl wget git mercurial \
      python3 python3-pip python3-venv \
      sudo locales file unzip zip xz-utils \
    && rm -rf /var/lib/apt/lists/* \
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
