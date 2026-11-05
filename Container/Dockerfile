# Arma 2 Operation Arrowhead dedicated server (arma2oaserver.exe) on Wine.
#
# Nothing licensed is baked into this image: steamcmd downloads Arma 2 and Operation
# Arrowhead into the /arma volume the first time the container starts.
FROM steamcmd/steamcmd:latest

USER root

# steamcmd and arma2oaserver.exe are 32-bit binaries.
RUN dpkg --add-architecture i386 \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
      wine \
      wine32:i386 \
      xvfb \
      procps \
 && rm -rf /var/lib/apt/lists/*

# Xvfb runs as an unprivileged user, so the X socket directory must already exist.
RUN mkdir -p /tmp/.X11-unix && chmod 1777 /tmp/.X11-unix

# The unprivileged account shipped by the base image changes between releases, so the
# server gets its own.
RUN useradd --create-home --shell /bin/bash arma

COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 0755 /usr/local/bin/entrypoint.sh

USER arma

ENV HOME=/home/arma \
    ARMA_DIR=/arma \
    WINEPREFIX=/arma/.wine \
    WINEDEBUG=-all \
    XDG_RUNTIME_DIR=/tmp/xdg-arma \
    ARMA2_APP=33910 \
    OA_APP=33930

WORKDIR /arma

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["server"]
