#!/usr/bin/env bash
# Runs an Arma 2 Operation Arrowhead dedicated server on Wine.
#
# The default command, "server", downloads Arma 2 + OA with steamcmd when arma2oaserver.exe
# is missing and then launches it. Any other command is executed as given, which is useful
# for poking around: docker compose run --rm server bash
set -Eeuo pipefail

ARMA_DIR="${ARMA_DIR:-/arma}"
SERVER_EXE="${ARMA_DIR}/arma2oaserver.exe"
DISPLAY_NUM="${DISPLAY_NUM:-99}"

# Wine wants a private runtime directory. Without one it prints
# "error: XDG_RUNTIME_DIR is invalid or not set in the environment." on every start.
XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/xdg-arma}"
export XDG_RUNTIME_DIR
export WINEPREFIX="${WINEPREFIX:-${ARMA_DIR}/.wine}"
export WINEDEBUG="${WINEDEBUG:--all}"

log() { printf '[arma2] %s\n' "$*"; }
die() { printf '[arma2] ERROR: %s\n' "$*" >&2; exit 1; }

steamcmd_bin() {
	local bin="${STEAMCMD:-}"
	[ -n "${bin}" ] || bin="$(command -v steamcmd || true)"
	[ -n "${bin}" ] || bin=/home/steam/steamcmd/steamcmd.sh
	[ -x "${bin}" ] || die "steamcmd not found (looked on PATH and at /home/steam/steamcmd/steamcmd.sh)"
	printf '%s' "${bin}"
}

download_game() {
	[ -n "${STEAM_USERNAME:-}" ] && [ -n "${STEAM_PASSWORD:-}" ] \
		|| die "game files are missing and STEAM_USERNAME/STEAM_PASSWORD are empty (fill in .env)"
	local bin app
	bin="$(steamcmd_bin)"
	for app in "${ARMA2_APP:-33910}" "${OA_APP:-33930}"; do
		log "steamcmd: app_update ${app} into ${ARMA_DIR}"
		# The Windows depot is deliberate: the dedicated server is a Windows binary and
		# steamcmd would otherwise refuse with "Invalid platform" for these apps.
		"${bin}" +@sSteamCmdForcePlatformType windows \
			+@sSteamCmdForcePlatformBitness 32 \
			+force_install_dir "${ARMA_DIR}" \
			+login "${STEAM_USERNAME}" "${STEAM_PASSWORD}" \
			+app_update "${app}" validate +quit \
			|| die "steamcmd failed for app ${app}"
	done
}

start_display() {
	command -v Xvfb >/dev/null 2>&1 || die "Xvfb is missing from the image"
	if [ ! -e "/tmp/.X11-unix/X${DISPLAY_NUM}" ]; then
		Xvfb ":${DISPLAY_NUM}" -screen 0 1024x768x16 -nolisten tcp &
		local _
		for _ in $(seq 1 50); do
			[ -e "/tmp/.X11-unix/X${DISPLAY_NUM}" ] && break
			sleep 0.1
		done
	fi
	[ -e "/tmp/.X11-unix/X${DISPLAY_NUM}" ] || die "Xvfb did not come up on :${DISPLAY_NUM}"
	export DISPLAY=":${DISPLAY_NUM}"
	log "display :${DISPLAY_NUM} is up"
}

run_server() {
	local args=("-port=${PORT:-2302}" "-name=${NAME:-server}")
	if [ -n "${CONFIG:-}" ]; then args+=("-config=${CONFIG}"); fi
	if [ -n "${CFG:-}" ]; then args+=("-cfg=${CFG}"); fi
	if [ -n "${PROFILES:-}" ]; then args+=("-profiles=${PROFILES}"); fi
	if [ -n "${MODS:-}" ]; then args+=("-mod=${MODS}"); fi
	log "launching arma2oaserver.exe ${args[*]}"
	exec wine "${SERVER_EXE}" "${args[@]}"
}

case "${1:-server}" in
server)
	mkdir -p "${ARMA_DIR}" "${WINEPREFIX}" "${XDG_RUNTIME_DIR}"
	chmod 700 "${XDG_RUNTIME_DIR}"
	if [ -f "${SERVER_EXE}" ]; then
		log "found ${SERVER_EXE}, skipping the steamcmd download"
	else
		download_game
		[ -f "${SERVER_EXE}" ] || die "steamcmd finished but ${SERVER_EXE} is still missing"
	fi
	start_display
	run_server
	;;
*)
	exec "$@"
	;;
esac
