FROM ubuntu:24.04

# Pin version here. To upgrade: update both ARGs and rebuild images.
# Get new SHA512 from https://www.waterfox.com/download/
ARG WATERFOX_VERSION=6.6.12
ARG WATERFOX_SHA512=f7aae05bf262fa560608a5bed1ac884e3b57a249cbac63a4726ed54da52695fe8231b7bd1b318aa41c21158ba13cc42364a23f0f0d923e550e8ac4ef5cb81f4f

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    libdbus-glib-1-2 \
    libgtk-3-0 \
    libx11-xcb1 \
    libxt6 \
    libglib2.0-0 \
    libasound2t64 \
    libpulse0 \
    fonts-liberation \
    bzip2 \
    libgl1-mesa-dri \
    libgl1 \
    libegl1 \
    libgbm1 \
    libfido2-1 \
    libusb-1.0-0 \
    libpcsclite1 \
    libnss3 \
    && rm -rf /var/lib/apt/lists/*

RUN if id -u 1000 >/dev/null 2>&1; then userdel -r "$(getent passwd 1000 | cut -d: -f1)"; fi \
    && useradd -m -u 1000 -s /bin/bash waterfox

WORKDIR /opt

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
