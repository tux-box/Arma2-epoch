#!/usr/bin/env bash
#
# Container entrypoint for the Arma 2 / Operation Arrowhead dedicated server.
#
#   1. download/update the Arma 2 OA server files with SteamCMD (Windows build, run under Wine)
#   2. install the DayZ / DayZ Epoch packs when asked (MOD_PROFILE, INSTALL_MODS)
#   3. create or patch the server configuration
#   4. prepare the MySQL hive database the mods store their state in
#   5. exec the dedicated server so it receives SIGTERM from the container runtime
set -Eeuo pipefail

# Allow ad-hoc commands, e.g. `docker compose run --rm arma2 bash` or a manual
# steamcmd update. Without arguments the server itself is started.
if [ "$#" -gt 0 ]; then
    exec "$@"
fi

log()  { printf '[entrypoint] %s\n' "$*"; }
warn() { printf '[entrypoint] WARNING: %s\n' "$*" >&2; }
die()  { printf '[entrypoint] ERROR: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- configuration
ARMA_DIR="${ARMA_DIR:-/arma2}"
STEAMCMD="${STEAMCMD:-/opt/steamcmd/steamcmd.sh}"

# SteamCMD / download
STEAM_USERNAME="${STEAM_USERNAME:-anonymous}"
STEAM_PASSWORD="${STEAM_PASSWORD:-}"
STEAM_APPS="${STEAM_APPS:-33935}"
UPDATE_ON_START="${UPDATE_ON_START:-1}"
STEAM_VALIDATE="${STEAM_VALIDATE:-1}"
STEAM_TIMEOUT="${STEAM_TIMEOUT:-1800}"

# Server launch
SERVER_EXE="${SERVER_EXE:-}"
SERVER_NAME="${SERVER_NAME:-server}"          # -name, the profile directory name
PORT="${PORT:-2302}"                          # -port, game port
MODS="${MODS:-}"                              # -mod, e.g. "@DayZ_Epoch;@DayZ_Epoch_Server"
WORLD="${WORLD:-}"                            # -world, usually "empty"
CPUCCOUNT="${CPUCCOUNT:-}"                    # -cpuCount
EXTHREADS="${EXTHREADS:-}"                    # -exThreads
EXTRA_ARGS="${EXTRA_ARGS:-}"                  # anything else, appended verbatim

# Mods
MOD_PROFILE="${MOD_PROFILE:-none}"            # none | dayz | epoch
INSTALL_MODS="${INSTALL_MODS:-}"              # extra packs: "dayz epoch"
MOD_REINSTALL="${MOD_REINSTALL:-0}"           # 1 = re-extract packs over existing files

# Generated configuration
GENERATE_CONFIGS="${GENERATE_CONFIGS:-1}"
PATCH_CONFIG="${PATCH_CONFIG:-1}"
SERVER_CFG_FILE="${SERVER_CFG_FILE:-}"
BASIC_CFG_FILE="${BASIC_CFG_FILE:-}"
PROFILES_DIR="${PROFILES_DIR:-}"
SERVER_HOSTNAME="${SERVER_HOSTNAME:-Arma 2 Server}"
MAX_PLAYERS="${MAX_PLAYERS:-32}"
SERVER_PASSWORD="${SERVER_PASSWORD:-}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-changeme}"
MOTD="${MOTD:-Welcome to ${SERVER_HOSTNAME}|Have fun}"
MISSION="${MISSION:-}"                        # e.g. "coop_01.Chernarus"
BATTLEYE="${BATTLEYE:-1}"
STEAM_PORT="${STEAM_PORT:-8766}"
STEAM_QUERY_PORT="${STEAM_QUERY_PORT:-27016}"
BE_PATH="${BE_PATH:-}"                      # -BEpath, BattlEye filter folder
BE_RCON_PASSWORD="${BE_RCON_PASSWORD:-}"     # written into BEServer.cfg

# Hive database (only used when DB_HOST is set)
DB_HOST="${DB_HOST:-}"
DB_PORT="${DB_PORT:-3306}"
DB_NAME="${DB_NAME:-dayz_epoch}"
DB_USER="${DB_USER:-dayz}"
DB_PASSWORD="${DB_PASSWORD:-}"

mkdir -p "${ARMA_DIR}"
cd "${ARMA_DIR}"

# ------------------------------------------------------------------ downloads
install_or_update() {
    local -a args=(+@sSteamCmdForcePlatformType windows
                   +force_install_dir "${ARMA_DIR}"
                   +login "${STEAM_USERNAME}")

    if [ "${STEAM_USERNAME}" != "anonymous" ] && [ -n "${STEAM_PASSWORD}" ]; then
        args+=("${STEAM_PASSWORD}")
    fi

    local app
    for app in ${STEAM_APPS}; do
        args+=(+app_update "${app}")
        [ "${STEAM_VALIDATE}" = "1" ] && args+=(validate)
    done
    args+=(+quit)

    log "running SteamCMD (apps: ${STEAM_APPS}, user: ${STEAM_USERNAME})"
    log "note: a Steam Guard prompt needs an interactive container (docker run -it / compose run)"

    if ! timeout "${STEAM_TIMEOUT}" "${STEAMCMD}" "${args[@]}"; then
        die "SteamCMD failed (apps: ${STEAM_APPS}). If it reported 'No subscription', STEAM_USERNAME has to \
be a Steam account that owns Arma 2 / Operation Arrowhead - the dedicated server tool ships with the game, \
so anonymous login does not work. Otherwise check for a Steam Guard prompt, wrong app IDs for your store \
package (33910 vs 33900) and network access. Restart with UPDATE_ON_START=0 to skip the update."
    fi
}

if [ "${UPDATE_ON_START}" = "1" ]; then
    install_or_update
else
    log "UPDATE_ON_START=0, skipping SteamCMD"
fi

# ----------------------------------------------------------------------- mods
install_mods() {
    local -a wanted=()
    [ -n "${INSTALL_MODS}" ] && read -r -a wanted <<< "${INSTALL_MODS}"
    case "${MOD_PROFILE}" in
        dayz|epoch) wanted+=("${MOD_PROFILE}") ;;
    esac
    [ "${#wanted[@]}" -gt 0 ] || return 0

    local mod
    for mod in "${wanted[@]}"; do
        log "installing mod pack: ${mod}"
        /usr/local/bin/install-mods.sh "${mod}"
    done
}

install_mods

# -------------------------------------------------- profile and configuration
# mod profile -> the config files the mod's own pack ships
resolve_profile() {
    local candidates=() candidate
    case "${MOD_PROFILE}" in
        none) return 0 ;;
        epoch)
            MODS="${MODS:-@DayZ_Epoch;@DayZ_Epoch_Server}"
            candidates=("DZE_Server_Config/11_chernarus.cfg" "instance_11_Chernarus/config.cfg")
            ;;
        dayz)
            MODS="${MODS:-@DayZ;@hive}"
            candidates=("cfgdayz/server.cfg" "cfgdayz/cfgdayz.cfg" "cfgdayz/dayz.cfg")
            ;;
        *)
            die "MOD_PROFILE='${MOD_PROFILE}' is not supported (none, dayz, epoch)"
            ;;
    esac

    # The packs bring a full server config; ours is only a fallback.
    GENERATE_CONFIGS=0
    if [ -z "${SERVER_CFG_FILE}" ]; then
        for candidate in "${candidates[@]}"; do
            if [ -f "${ARMA_DIR}/${candidate}" ]; then
                SERVER_CFG_FILE="${candidate}"
                break
            fi
        done
        [ -n "${SERVER_CFG_FILE}" ] || die "no ${MOD_PROFILE} server config found (looked for: ${candidates[*]}). \
Install the pack first (MOD_REINSTALL=1) or set SERVER_CFG_FILE."
    fi

    [ -n "${PROFILES_DIR}" ] || PROFILES_DIR="$(dirname "${SERVER_CFG_FILE}")"

    if [ -z "${BASIC_CFG_FILE}" ]; then
        if [ -f "${ARMA_DIR}/$(dirname "${SERVER_CFG_FILE}")/basic.cfg" ]; then
            BASIC_CFG_FILE="$(dirname "${SERVER_CFG_FILE}")/basic.cfg"
        else
            BASIC_CFG_FILE="basic.cfg"
            GENERATE_CONFIGS=1
        fi
    fi
}

resolve_profile
SERVER_CFG_FILE="${SERVER_CFG_FILE:-server.cfg}"
BASIC_CFG_FILE="${BASIC_CFG_FILE:-basic.cfg}"
PROFILES_DIR="${PROFILES_DIR:-profiles}"

write_server_cfg() {
    local motd_entries="" line
    local IFS='|'
    for line in ${MOTD}; do
        [ -n "${motd_entries}" ] && motd_entries+=", "
        motd_entries+="\"${line//\"/}\""
    done
    unset IFS

    {
        cat <<EOF
// Generated by the arma2-server container on first start.
// Delete the file to regenerate it from environment variables, or just edit it.

hostname = "${SERVER_HOSTNAME}";
password = "${SERVER_PASSWORD}";
passwordAdmin = "${ADMIN_PASSWORD}";
maxPlayers = ${MAX_PLAYERS};

steamport = ${STEAM_PORT};
steamqueryport = ${STEAM_QUERY_PORT};

verifySignatures = 2;
equalModRequired = 0;
kickDuplicate = 1;
BattlEye = ${BATTLEYE};

disableVoN = 0;
vonCodecQuality = 10;
persistent = 1;
timeStampFormat = "short";

motd[] = { ${motd_entries} };
motdInterval = 5;

voteThreshold = 1.5;
voteMissionPlayers = 1;

EOF
        if [ -n "${MISSION}" ]; then
            cat <<EOF
class Missions
{
    class Mission1
    {
        template = "${MISSION}";
        difficulty = "regular";
    };
};
EOF
        else
            cat <<'EOF'
// Add a mission by setting MISSION (e.g. "coop_01.Chernarus") or by editing this
// class. The mission .pbo must exist in <game dir>/MPMissions.
class Missions
{
};
EOF
        fi
    } > "${SERVER_CFG_FILE}"
    log "created ${ARMA_DIR}/${SERVER_CFG_FILE}"
}

write_basic_cfg() {
    cat > "${BASIC_CFG_FILE}" <<'EOF'
// Generated by the arma2-server container on first start.
// Network tuning; adjust to the server's real bandwidth and player count.

MinBandwidth = 2097152;
MaxBandwidth = 10485760;
MaxMsgSend = 1024;
MaxSizeGuaranteed = 512;
MaxSizeNonguaranteed = 256;
MinErrorToSend = 0.008;
MinErrorToSendNear = 0.08;
MaxCustomFileSize = 110000;
EOF
    log "created ${ARMA_DIR}/${BASIC_CFG_FILE}"
}

# --- small config editors -----------------------------------------------------
sed_value_escape() { printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'; }

# Sets the first occurrence of a key in an Arma config (server.cfg style,
# case-insensitive key names, values may contain any characters).
cfg_set_value() {
    local file="$1" key="$2" value="$3" template="$4"
    CFG_KEY="${key}" CFG_VALUE="${value}" CFG_TEMPLATE="${template}" awk '
        BEGIN { k = tolower(ENVIRON["CFG_KEY"]); done = 0 }
        {
            if (!done && tolower($0) ~ "^[[:space:]]*" k "[[:space:]]*=") {
                print ENVIRON["CFG_TEMPLATE"]
                done = 1
                next
            }
            print
        }
        END { if (!done) print ENVIRON["CFG_TEMPLATE"] }' "${file}" > "${file}.tmp" && mv "${file}.tmp" "${file}"
}

cfg_set_string() {
    local file="$1" key="$2" value="$3"
    cfg_set_value "${file}" "${key}" "${value}" "${key} = \"${value}\";"
}

cfg_set_number() {
    local file="$1" key="$2" value="$3"
    cfg_set_value "${file}" "${key}" "${value}" "${key} = ${value};"
}

# Sets a key only inside the [Database] section of a HiveExt.ini.
ini_set_database() {
    local file="$1" key="$2" value="$3"
    awk -v key="${key}" -v val="${value}" '
        /^[[:space:]]*\[/ {
            section = tolower($0)
            in_db = (section ~ /\[database\]/)
            print
            next
        }
        in_db && !done {
            if ($0 ~ "^[[:space:]]*;?[[:space:]]*" key "[[:space:]]*=") {
                print key " = " val
                done = 1
                next
            }
        }
        { print }
        END { if (in_db && !done) print key " = " val }' "${file}" > "${file}.tmp" && mv "${file}.tmp" "${file}"
}

if [ "${GENERATE_CONFIGS}" = "1" ]; then
    [ -f "${SERVER_CFG_FILE}" ] || write_server_cfg
    [ -f "${BASIC_CFG_FILE}" ]  || write_basic_cfg
fi
[ -f "${SERVER_CFG_FILE}" ] || die "server config ${ARMA_DIR}/${SERVER_CFG_FILE} is missing"
[ -f "${BASIC_CFG_FILE}" ]  || die "basic config ${ARMA_DIR}/${BASIC_CFG_FILE} is missing"

mkdir -p "${PROFILES_DIR}"
mkdir -p MPMissions

# BattlEye filters ship inside the mod packs; point the server at them and keep
# the RCon password under the container's control.
vbe_dir="${ARMA_DIR}/${PROFILES_DIR}/BattlEye"
if [ -z "${BE_PATH}" ] && [ -d "${vbe_dir}" ]; then
    BE_PATH="${PROFILES_DIR}/BattlEye"
fi
if [ -n "${BE_RCON_PASSWORD}" ] && [ -n "${BE_PATH}" ] && [ -f "${ARMA_DIR}/${BE_PATH}/BEServer.cfg" ]; then
    sed -i -E "s/^RConPassword .*/RConPassword $(sed_value_escape "${BE_RCON_PASSWORD}")/" \
        "${ARMA_DIR}/${BE_PATH}/BEServer.cfg"
    log "set the BattlEye RCon password in ${BE_PATH}/BEServer.cfg"
fi

# Apply the container's identity settings to a config the mod pack shipped, once:
# the generated marker keeps later hand edits from being overwritten.
patch_profile_config() {
    [ "${PATCH_CONFIG}" = "1" ] || return 0
    [ "${MOD_PROFILE}" != "none" ] || return 0

    local cfg="${ARMA_DIR}/${SERVER_CFG_FILE}"
    local marker="${ARMA_DIR}/.container-patched-${MOD_PROFILE}"
    if [ -f "${marker}" ]; then
        log "${MOD_PROFILE} config already patched with container settings (${marker})"
        return 0
    fi

    log "applying container settings to ${SERVER_CFG_FILE}"
    cfg_set_string "${cfg}" "hostname" "${SERVER_HOSTNAME}"
    cfg_set_string "${cfg}" "password" "${SERVER_PASSWORD}"
    cfg_set_string "${cfg}" "passwordAdmin" "${ADMIN_PASSWORD}"
    cfg_set_number "${cfg}" "maxPlayers" "${MAX_PLAYERS}"
    cfg_set_number "${cfg}" "steamport" "${STEAM_PORT}"
    cfg_set_number "${cfg}" "steamqueryport" "${STEAM_QUERY_PORT}"
    cfg_set_number "${cfg}" "BattlEye" "${BATTLEYE}"
    touch "${marker}"
}

patch_hive_config() {
    # HiveExt.ini holds the database connection; the container's env is authoritative.
    [ -n "${DB_HOST}" ] || return 0

    local -a hive_files=()
    mapfile -t hive_files < <(find "${ARMA_DIR}" -maxdepth 3 -type f -iname 'hiveext.ini')
    if [ "${#hive_files[@]}" -eq 0 ]; then
        warn "no HiveExt.ini found; the hive will use its own settings (mount one into ${PROFILES_DIR})"
        return 0
    fi

    local hive
    for hive in "${hive_files[@]}"; do
        if ! grep -qi '^[[:space:]]*\[Database\]' "${hive}"; then
            printf '\n[Database]\n' >> "${hive}"
        fi
        log "pointing ${hive} at ${DB_USER}@${DB_HOST}:${DB_PORT}/${DB_NAME}"
        ini_set_database "${hive}" "Type" "MySQL"
        ini_set_database "${hive}" "Host" "${DB_HOST}"
        ini_set_database "${hive}" "Port" "${DB_PORT}"
        ini_set_database "${hive}" "Database" "${DB_NAME}"
        ini_set_database "${hive}" "Username" "${DB_USER}"
        ini_set_database "${hive}" "Password" "${DB_PASSWORD}"
    done
}

patch_profile_config
patch_hive_config

if [ -n "${DB_HOST}" ]; then
    /usr/local/bin/bootstrap-db.sh "${MOD_PROFILE}"
else
    log "DB_HOST not set, skipping hive database setup"
fi

# --------------------------------------------------------------------- launch
if [ -z "${SERVER_EXE}" ]; then
    for candidate in arma2oaserver.exe arma2server.exe; do
        if [ -f "${ARMA_DIR}/${candidate}" ]; then
            SERVER_EXE="${candidate}"
            break
        fi
    done
fi
[ -n "${SERVER_EXE}" ] || die "no server executable found in ${ARMA_DIR} (expected arma2oaserver.exe or arma2server.exe). Is the download complete?"

# Config paths stay relative so that Wine resolves them inside the game directory
# instead of turning them into a bogus drive path.
cmd=(wine "${SERVER_EXE}"
     "-port=${PORT}"
     "-name=${SERVER_NAME}"
     "-config=${SERVER_CFG_FILE}"
     "-cfg=${BASIC_CFG_FILE}"
     "-profiles=${PROFILES_DIR}"
     -noSound
     -noPause)

[ -n "${BE_PATH}" ]   && cmd+=("-BEpath=${BE_PATH}")
[ -n "${MODS}" ]      && cmd+=("-mod=${MODS}")
[ -n "${WORLD}" ]     && cmd+=("-world=${WORLD}")
[ -n "${CPUCCOUNT}" ] && cmd+=("-cpuCount=${CPUCCOUNT}")
[ -n "${EXTHREADS}" ] && cmd+=("-exThreads=${EXTHREADS}")
if [ -n "${EXTRA_ARGS}" ]; then
    read -r -a extra <<< "${EXTRA_ARGS}"
    cmd+=("${extra[@]}")
fi

log "profile: ${MOD_PROFILE}, mods: ${MODS:-<none>}"
log "starting: ${cmd[*]}"
log "listening on UDP ${PORT} (steam ${STEAM_PORT}, query ${STEAM_QUERY_PORT})"

exec "${cmd[@]}"
