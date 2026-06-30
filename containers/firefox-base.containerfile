FROM ubuntu:24.04

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
    xz-utils \
    libgl1-mesa-dri \
    libgl1 \
    libegl1 \
    libgbm1 \
    libfido2-1 \
    libusb-1.0-0 \
    libpcsclite1 \
    libnss3 \
    libpci3 \
    libwayland-client0 \
    && rm -rf /var/lib/apt/lists/*

RUN if id -u 1000 >/dev/null 2>&1; then userdel -r "$(getent passwd 1000 | cut -d: -f1)"; fi \
    && useradd -m -u 1000 -s /bin/bash firefox

WORKDIR /opt

RUN curl -fsSL -o firefox.tar.xz \
    "https://download.mozilla.org/?product=firefox-latest-ssl&os=linux64&lang=en-US" \
    && tar -xJf firefox.tar.xz \
    && rm firefox.tar.xz \
    && chown -R firefox:firefox /opt/firefox

USER firefox
ENV HOME=/home/firefox

ENTRYPOINT ["/opt/firefox/firefox"]
CMD ["--no-remote"]
