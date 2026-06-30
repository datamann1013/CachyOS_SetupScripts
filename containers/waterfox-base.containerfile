FROM archlinux:latest

RUN pacman -Syu --noconfirm && pacman -S --noconfirm --needed \
    ca-certificates \
    curl \
    dbus-glib \
    gtk3 \
    libxt \
    glib2 \
    libpulse \
    ttf-liberation \
    bzip2 \
    mesa \
    libglvnd \
    libfido2 \
    libusb \
    pcsclite \
    nss \
    libpciaccess \
    wayland \
    && rm -rf /var/cache/pacman/pkg

RUN if id -u 1000 >/dev/null 2>&1; then userdel -r "$(getent passwd 1000 | cut -d: -f1)"; fi \
    && useradd -m -u 1000 -s /bin/bash waterfox

WORKDIR /opt

ARG WATERFOX_VERSION=6.6.15
ARG WATERFOX_SHA512=7f1b1075385e0ac9f59017a69731a0d6fee27054ea9f594251a58b3851f3fc27de5365194e35bc20cf262b6dab9be64c45d48513532fb838bfb004860f25913a

RUN curl -fsSL \
    "https://cdn.waterfox.com/waterfox/releases/${WATERFOX_VERSION}/Linux_x86_64/waterfox-${WATERFOX_VERSION}.tar.bz2" \
    -o waterfox.tar.bz2 \
    && echo "${WATERFOX_SHA512}  waterfox.tar.bz2" | sha512sum -c - \
    && tar -xjf waterfox.tar.bz2 \
    && rm waterfox.tar.bz2 \
    && chown -R waterfox:waterfox /opt/waterfox

USER waterfox
ENV HOME=/home/waterfox

ENTRYPOINT ["/opt/waterfox/waterfox"]
CMD ["--no-remote"]
