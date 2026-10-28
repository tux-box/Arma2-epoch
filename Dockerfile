# syntax=docker/dockerfile:1
#
# Arma 2 / Arma 2: Operation Arrowhead dedicated server.
#
# Arma 2 has no maintained Linux-native server binary (the 1.63 Linux server was
# never updated), so this image runs the Windows dedicated server under Wine.
# Server files are downloaded with SteamCMD at container start.
FROM debian:bookworm-slim

ARG DEBIAN_FRONTEND=noninteractive

LABEL org.opencontainers.image.title="Arma 2 dedicated server" \
      org.opencontainers.image.description="Arma 2 / Arma 2: Operation Arrowhead dedicated server (Windows server files under Wine)" \
      org.opencontainers.image.source="https://github.com/"

ENV LANG=C.UTF-8 \
    HOME=/root \
    ARMA_DIR=/arma2 \
    STEAMCMD_DIR=/opt/steamcmd \
    WINEPREFIX=/opt/wineprefix \
    WINEARCH=win32 \
    WINEDEBUG=-all \
    WINEDLLOVERRIDES="mscoree,mshtml=" \
    DISPLAY= \
    PATH="/opt/steamcmd:/usr/local/bin:${PATH}"

# i386 is required for both SteamCMD and the 32-bit Wine/Arma binaries.
# winetricks lives in the contrib component on Debian.
RUN dpkg --add-architecture i386 \
 && sed -i 's/^Components: main$/Components: main contrib/' /etc/apt/sources.list.d/debian.sources \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
        ca-certificates curl wget tar gzip xz-utils bzip2 unzip \
        procps tini tzdata \
        libc6-i386 lib32gcc-s1 lib32stdc++6 \
        wine wine32:i386 winetricks cabextract \
        7zip default-mysql-client python3 python3-pip \
 && rm -rf /var/lib/apt/lists/*

# gdown fetches the large Google Drive archives the DayZ/Epoch packs are
# distributed as (plain curl cannot follow Drive's large-file confirmation).
RUN python3 -m pip install --no-cache-dir --break-system-packages gdown

# SteamCMD: used to download the (Windows) dedicated server files.
RUN mkdir -p "${STEAMCMD_DIR}" \
 && curl -fsSL --retry 3 -o /tmp/steamcmd.tar.gz \
        https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz \
 && tar -xzf /tmp/steamcmd.tar.gz -C "${STEAMCMD_DIR}" \
 && rm -f /tmp/steamcmd.tar.gz \
 && chmod +x "${STEAMCMD_DIR}/steamcmd.sh"

# First run self-updates SteamCMD (and fails harmlessly without an app command).
RUN "${STEAMCMD_DIR}/steamcmd.sh" +quit || true

# Prepare a 32-bit Wine prefix at build time so container start is predictable.
RUN wineboot --init || true; wineserver -w || true

# DirectX 9 runtime pieces: the old Arma 2 executables import d3dx9_*.dll.
# Failing here is not fatal for the server, but it is what makes the image
# self-sufficient, so keep the result visible during the build.
RUN winetricks -q d3dx9 || echo "WARNING: winetricks d3dx9 failed; server may need it at runtime"

# DayZ / DayZ Epoch ship native hive DLLs built with the MSVC runtimes, so the
# prefix needs them too (best effort: a failure here only affects the hive).
RUN winetricks -q vcrun2010 vcrun2012 vcrun2013 vcrun2015 \
    || echo "note: winetricks reported a non-zero status (usually 'already installed', 183); checking the DLLs"
RUN test -f /opt/wineprefix/drive_c/windows/system32/vcruntime140.dll \
    || echo "WARNING: vcruntime140.dll is missing; HiveExt.dll may not load"

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY scripts/ /usr/local/bin/
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/install-mods.sh /usr/local/bin/bootstrap-db.sh

# Game port (2302) plus the adjacent ports the server can bind
# (2303-2305), the Steam port (8766) and the Steam query port (27016).
EXPOSE 2302-2305/udp 8766/udp 27016/udp

VOLUME ["/arma2"]

STOPSIGNAL SIGTERM
HEALTHCHECK --interval=30s --timeout=5s --start-period=120s --retries=3 \
    CMD pgrep -f "arma2oaserver.exe|arma2server.exe" >/dev/null || exit 1

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
