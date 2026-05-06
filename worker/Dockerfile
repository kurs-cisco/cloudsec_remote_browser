FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive
ENV PYTHONUNBUFFERED=1
ENV DISPLAY=:99

RUN apt-get update && apt-get install -y --no-install-recommends \
    chromium \
    chromium-sandbox \
    dbus-x11 \
    ffmpeg \
    fonts-noto-color-emoji \
    fonts-noto-core \
    openbox \
    pulseaudio \
    pulseaudio-utils \
    python3 \
    python3-pip \
    python3-venv \
    x11-utils \
    xdotool \
    xvfb \
    fonts-liberation \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN dpkg-query -W chromium chromium-sandbox > /opt/chromium-package-info.txt \
    && (/usr/bin/chromium --version > /opt/chromium-version.txt || true)

RUN groupadd --system rbi && useradd --system --create-home --gid rbi --shell /bin/bash rbi
RUN mkdir -p /tmp/.X11-unix /home/rbi/chromium-profile \
    && chmod 1777 /tmp/.X11-unix \
    && chown -R rbi:rbi /home/rbi

WORKDIR /app

ENV VIRTUAL_ENV=/opt/venv
ENV PATH="/opt/venv/bin:${PATH}"

RUN python3 -m venv "${VIRTUAL_ENV}"

COPY requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir --upgrade pip setuptools wheel \
    && pip install --no-cache-dir -r /app/requirements.txt

COPY worker.py /app/worker.py
COPY turn_probe.py /app/turn_probe.py
COPY turn_auth_diag.py /app/turn_auth_diag.py
COPY start-browser.sh /app/start-browser.sh

RUN chmod +x /app/start-browser.sh

USER rbi
ENTRYPOINT ["/app/start-browser.sh"]
