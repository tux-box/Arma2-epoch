#!/usr/bin/env bash
#
# Installs a DayZ / DayZ Epoch dedicated-server pack into $ARMA_DIR.
#
#   install-mods.sh epoch    @DayZ_Epoch, @DayZ_Epoch_Server, DZE_Server_Config, mission
#   install-mods.sh dayz     @DayZ, @hive, DayZ server config, mission
#
# Neither mod is a Steam app that downloads anonymously, so the packs come from
# their community releases: an archive (.7z/.zip/.rar) fetched from the configured
# URL, or one dropped into /mods. Packs are unpacked into a staging area and
# copied on top of the Arma 2 OA server files.
#
# DayZ Epoch needs two archives: the client pack (provides @DayZ_Epoch) and the
# server pack (provides @DayZ_Epoch_Server, config, mission and SQL schema).
set -Eeuo pipefail

log()  { printf '[mods] %s\n' "$*"; }
warn() { printf '[mods] WARNING: %s\n' "$*" >&2; }
die()  { printf '[mods] ERROR: %s\n' "$*" >&2; exit 1; }

ARMA_DIR="${ARMA_DIR:-/arma2}"
MODS_DIR="${MODS_DIR:-/mods}"
STAGE_ROOT="${STAGE_ROOT:-/tmp/modstage}"

PROFILE="${1:-}"
[ -n "${PROFILE}" ] || die "usage: install-mods.sh <epoch|dayz>"

# Official DayZ Epoch 1.0.7.1 Google Drive releases (password 123456).
EPOCH_CLIENT_DRIVE_ID="${EPOCH_CLIENT_DRIVE_ID:-19iCJevU008g311vsxJNR0PjYmkSv36YK}"
EPOCH_SERVER_DRIVE_ID="${EPOCH_SERVER_DRIVE_ID:-1jDn86sfTwcRae4NZgHK76k_CaY1jOUP2}"

# role | fallback Drive file id | env var with an override URL | folder the pack must provide
ENTRIES=()
case "${PROFILE}" in
    epoch)
        ARCHIVE_PASSWORD="${EPOCH_ARCHIVE_PASSWORD-123456}"
        ENTRIES=(
            "server|${EPOCH_SERVER_DRIVE_ID}|EPOCH_SERVER_URL|@DayZ_Epoch_Server"
            "client|${EPOCH_CLIENT_DRIVE_ID}|EPOCH_CLIENT_URL|@DayZ_Epoch"
        )
        ;;
    dayz)
        ARCHIVE_PASSWORD="${DAYZ_ARCHIVE_PASSWORD:-}"
        ENTRIES=(
            "pack||DAYZ_SERVER_URL|@DayZ"
        )
        ;;
    *)
        die "unknown mod profile '${PROFILE}' (expected epoch or dayz)"
        ;;
esac

# Pull the file id out of any of the Google Drive URL shapes, or accept a bare id.
drive_id_from_url() {
    if [[ "$1" =~ /file/d/([A-Za-z0-9_-]{20,}) ]] \
        || [[ "$1" =~ [\?\&]id=([A-Za-z0-9_-]{20,}) ]] \
        || [[ "$1" =~ ^([A-Za-z0-9_-]{25,})$ ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
        return 0
    fi
    return 1
}

find_local_archive() {
    local role="$1" file base
    [ -d "${MODS_DIR}" ] || return 1
    for file in "${MODS_DIR}"/*; do
        [ -f "${file}" ] || continue
        base="${file##*/}"
        base="${base,,}"
        case "${base}" in
            *.7z|*.zip|*.rar|*.tar.gz|*.tgz) ;;
            *) continue ;;
        esac
        case "${PROFILE}" in
            epoch)
                case "${base}" in *epoch*) ;; *) continue ;; esac
                if [ "${role}" != "pack" ]; then
                    case "${base}" in *"${role}"*) ;; *) continue ;; esac
                fi
                ;;
            dayz)
                case "${base}" in *epoch*) continue ;; esac
                ;;
        esac
        printf '%s\n' "${file}"
        return 0
    done
    return 1
}

download_archive() {
    local url="$1" out="$2" file_id
    if file_id="$(drive_id_from_url "${url}")"; then
        log "downloading Google Drive file ${file_id}"
        python3 - "${file_id}" "${out}" <<'PY' || die "Google Drive download failed (${file_id})"
import sys, gdown
gdown.download(id=sys.argv[1], output=sys.argv[2], quiet=False)
PY
    else
        log "downloading ${url}"
        curl -fL --retry 3 --connect-timeout 30 --max-time 7200 -o "${out}" "${url}" \
            || die "download failed: ${url}"
    fi
    [ -s "${out}" ] || die "downloaded archive is empty: ${url}"
}

unpack_archive() {
    local archive="$1" dest="$2"
    mkdir -p "${dest}"
    case "${archive}" in
        *.tar.gz|*.tgz)
            tar -xzf "${archive}" -C "${dest}"
            ;;
        *)
            local -a seven_zip_args=(-y "-o${dest}")
            [ -n "${ARCHIVE_PASSWORD}" ] && seven_zip_args+=("-p${ARCHIVE_PASSWORD}")
            7zz x "${seven_zip_args[@]}" "${archive}" >/dev/null \
                || die "cannot unpack $(basename "${archive}") (wrong archive password, or a corrupt download)"
            ;;
    esac
}

install_entry() {
    local entry="$1" role file_id env_name marker
    IFS='|' read -r role file_id env_name marker <<< "${entry}"

    if [ -d "${ARMA_DIR}/${marker}" ] && [ "${MOD_REINSTALL:-0}" != "1" ]; then
        log "${marker} already installed, skipping ${role}"
        return 0
    fi

    local workdir archive url local_archive
    workdir="$(mktemp -d "${STAGE_ROOT}.XXXXXX")"
    archive="${workdir}/modpack"

    if local_archive="$(find_local_archive "${role}")"; then
        log "using local archive ${local_archive}"
        cp "${local_archive}" "${archive}"
    else
        url="${!env_name:-}"
        if [ -n "${url}" ]; then
            :
        elif [ -n "${file_id}" ]; then
            url="${file_id}"
        else
            die "no ${PROFILE} ${role} archive: put a pack in ${MODS_DIR} or set ${env_name}"
        fi
        download_archive "${url}" "${archive}"
    fi

    local unpacked="${workdir}/unpacked"
    log "unpacking $(basename "${archive}") (${role})"
    unpack_archive "${archive}" "${unpacked}"

    # Packs either contain the mod folder at the top level or a directory down.
    local found pack_root="${unpacked}"
    found="$(find "${unpacked}" -maxdepth 6 -type d -name "${marker}" -print -quit || true)"
    if [ -n "${found}" ]; then
        pack_root="$(dirname "${found}")"
    else
        die "$(basename "${archive}") does not contain ${marker}; is this the right pack?"
    fi

    log "installing ${marker} from ${pack_root}"
    mkdir -p "${ARMA_DIR}"
    # Copy everything except the game/server executables: the image ships the
    # current Arma 2 OA server binaries and older pack copies would replace them.
    (cd "${pack_root}" && tar -cf - \
            --exclude='arma2oaserver.exe' --exclude='arma2server.exe' \
            --exclude='arma2oa.exe' --exclude='arma2.exe' .) | tar -xf - -C "${ARMA_DIR}"

    rm -rf "${workdir}"
}

mkdir -p "${ARMA_DIR}/MPMissions" "${ARMA_DIR}/keys" "${ARMA_DIR}/sql"
for entry in "${ENTRIES[@]}"; do
    install_entry "${entry}"
done

# The packs either use a lowercase missions folder or ship missions unpacked.
if [ -d "${ARMA_DIR}/mpmissions" ] && [ ! -d "${ARMA_DIR}/MPMissions" ]; then
    mv "${ARMA_DIR}/mpmissions" "${ARMA_DIR}/MPMissions"
fi
mkdir -p "${ARMA_DIR}/MPMissions" "${ARMA_DIR}/keys" "${ARMA_DIR}/sql"

# Packs ship the signature keys as keys/ or Keys/. Wine resolves either, but on a
# case-sensitive filesystem both can appear and split the .bikey files.
if [ -d "${ARMA_DIR}/Keys" ] && [ ! "${ARMA_DIR}/Keys" -ef "${ARMA_DIR}/keys" ]; then
    mkdir -p "${ARMA_DIR}/keys"
    cp -a "${ARMA_DIR}/Keys/." "${ARMA_DIR}/keys/" 2>/dev/null || true
    rm -rf "${ARMA_DIR}/Keys"
    log "merged Keys/ into keys/"
fi

# Epoch ships the hive DLLs separately; they have to sit next to the server exe.
if [ -d "${ARMA_DIR}/dlls" ]; then
    for dll in "${ARMA_DIR}/dlls/"*.dll; do
        [ -f "${dll}" ] || continue
        cp -n "${dll}" "${ARMA_DIR}/" 2>/dev/null || true
    done
    log "copied hive DLLs into ${ARMA_DIR}"
fi

# Collect the hive schema where the DB bootstrap expects it.
find "${ARMA_DIR}" -maxdepth 4 -type f -iname '*.sql' ! -path "${ARMA_DIR}/sql/*" \
    -exec cp -n {} "${ARMA_DIR}/sql/" \;

missing=
for entry in "${ENTRIES[@]}"; do
    IFS='|' read -r _role _id _env marker <<< "${entry}"
    [ -d "${ARMA_DIR}/${marker}" ] || missing="${missing} ${marker}"
done
[ -z "${missing}" ] || die "pack installed but these folders are missing:${missing}"

log "${PROFILE} ready in ${ARMA_DIR}"
log "sql files:$(ls -1 "${ARMA_DIR}/sql" 2>/dev/null | sed 's/^/ /' | tr '\n' ' ')"
