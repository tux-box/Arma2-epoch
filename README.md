# Arma 2 dedicated server in Docker

Container image for hosting an **Arma 2 / Arma 2: Operation Arrowhead** dedicated
server, including the **DayZ** and **DayZ Epoch** mods. Server files are
downloaded with **SteamCMD** and the (Windows) dedicated server binary is run
with **Wine**, because Bohemia never shipped a maintained Linux server for
Arma 2 — the old native Linux server stopped at 1.63 and was not updated when
the game moved to 1.64.

Both mods keep player and world state in a MySQL hive (`HiveExt.dll`), so a
`mariadb` service is included and its schema is imported automatically.

**New to this? Start with [HOWTO.md](HOWTO.md)** — a step-by-step walkthrough
from an empty checkout to a running Epoch server, including Steam Guard, player
connection, updates, backups and troubleshooting.

## Requirements

* Docker with Linux containers (Docker Desktop, Docker Engine, or a Linux host)
* A Steam account that owns **Arma 2** and **Arma 2: Operation Arrowhead**.
  The dedicated-server tool apps (`33935` Arma 2: OA, `33905` Arma 2) ship with
  the games and are *not* downloadable anonymously — SteamCMD answers
  `No subscription` for the `anonymous` user.
* For the mods: **Arma 2 OA 1.64** and the Combined Operations data (Chernarus
  lives in the Arma 2 game files), i.e. `STEAM_APPS=33935 33930 33910`.
* ~5 GB for the server files, plus the mod packs: DayZ Epoch is a ~4.6 GB client
  download plus a 43 MB server download, and `@DayZ_Epoch` unpacks to about 7 GB.
  Vanilla DayZ packs are usually 2–4 GB.

## Quick start

```bash
cp .env.example .env      # set STEAM_USERNAME / STEAM_PASSWORD, hostname, passwords
docker compose build
docker compose up -d
docker compose logs -f
```

The first start downloads the server files (several GB), generates
`server.cfg` and `basic.cfg` into `./data/arma2`, then launches the server.

Note: `docker compose up` is the wrong place for an interactive Steam Guard
prompt. If your account needs a Steam Guard code, prime the download first:

```bash
docker compose run --rm -it --entrypoint /opt/steamcmd/steamcmd.sh arma2 \
  +@sSteamCmdForcePlatformType windows +force_install_dir /arma2 \
  +login YOUR_STEAM_USER +app_update 33935 validate +quit
```

After that, `docker compose up -d` starts straight away.

### Without compose

```bash
docker build -t arma2-server .

docker run -d --name arma2-server \
  --restart unless-stopped \
  -p 2302-2305:2302-2305/udp -p 8766:8766/udp -p 27016:27016/udp \
  -v "$PWD/data/arma2:/arma2" -v "$PWD/mods:/mods:ro" \
  -e SERVER_HOSTNAME="Arma 2 Dedicated Server" \
  -e ADMIN_PASSWORD="change-me" \
  arma2-server
```

A plain server needs no database. `mariadb`/`DB_*` only matter for the mod
profiles, so drop `DEPENDS_ON`/`DB_HOST` when running standalone.

## Layout

| Path | Contents |
| --- | --- |
| `./data/arma2` | Container `/arma2`: server files, configs, `profiles/`, `MPMissions/`, mod folders, `keys/`, `sql/` |
| `./mods` | Optional mod packs (`.7z`/`.zip`/`.rar`); used instead of downloading |
| `steam` volume | Container `/root/Steam`: SteamCMD login/session, so a Steam Guard login survives container re-creation |
| `db` volume | MariaDB data for the DayZ/Epoch hive |
| `Dockerfile` | Debian bookworm + Wine + SteamCMD + 7-Zip + MySQL client |
| `entrypoint.sh` | Install/update, mod install, config patching, DB bootstrap, launch |
| `scripts/install-mods.sh` | Fetches and unpacks the DayZ / Epoch packs |
| `scripts/bootstrap-db.sh` | Waits for MariaDB and imports the hive schema once |

`server.cfg` and `basic.cfg` are only generated when they do not exist, so your
edits survive restarts and image rebuilds. Delete a file to regenerate it from
the environment.

## Mod profiles

`MOD_PROFILE` selects what is being hosted:

| Profile | What it installs | Config | Mods passed to the server |
| --- | --- | --- | --- |
| `none` (default) | nothing | generated `server.cfg` | `MODS`, empty by default |
| `epoch` | `@DayZ_Epoch` (client pack) + `@DayZ_Epoch_Server`, `DZE_Server_Config`, Chernarus mission, hive DLLs, SQL schema | `DZE_Server_Config/11_chernarus.cfg` | `@DayZ_Epoch;@DayZ_Epoch_Server` |
| `dayz` | `@DayZ` + `@hive` + `cfgdayz` from the pack | `cfgdayz/server.cfg` | `@DayZ;@hive` |

Switch profile, then restart:

```bash
# .env
MOD_PROFILE=epoch
STEAM_APPS=33935 33930 33910
```

### DayZ Epoch

`MOD_PROFILE=epoch` downloads the official **DayZ Epoch 1.0.7.1** release:
client pack (Google Drive id `19iCJevU008g311vsxJNR0PjYmkSv36YK`) and server pack
(`1jDn86sfTwcRae4NZgHK76k_CaY1jOUP2`), both password `123456`. Override with
`EPOCH_CLIENT_URL` / `EPOCH_SERVER_URL` / `EPOCH_ARCHIVE_PASSWORD`, or drop the
archives into `./mods` (names must contain `epoch` and `client`/`server`).

The image then:

* copies the pack's hive DLLs next to `arma2oaserver.exe`,
* points `DZE_Server_Config/HiveExt.ini` at the `mariadb` service,
* imports `SQL/epoch.sql` (+ `add_recommended_mysql_events.sql`) into the empty
  `dayz_epoch` database once, and turns the event scheduler on,
* applies `SERVER_HOSTNAME`, `ADMIN_PASSWORD`, `MAX_PLAYERS`, `BATTLEYE` and the
  Steam ports to `11_chernarus.cfg` **once** (marker `.container-patched-epoch`),
* starts `arma2oaserver.exe -mod=@DayZ_Epoch;@DayZ_Epoch_Server -BEpath=DZE_Server_Config/BattlEye`.

Epoch refuses clients whose build differs: the server and every client must run
the same Arma 2 OA build (`requiredBuild` in the cfg, `144629` for 1.0.7.1).

### DayZ (vanilla)

`MOD_PROFILE=dayz` needs a pack you trust: there is no live official server
download any more (`dayzmod.com` is gone, the Steam listing `224580` only
installs the client and is not anonymously downloadable). Set `DAYZ_SERVER_URL`
to a `.7z`/`.zip`/`.rar` with `@DayZ` (and ideally `@hive`), or put it in
`./mods`.

The pack layout varies between community builds, so adjust when needed:
`SERVER_CFG_FILE`, `BASIC_CFG_FILE`, `PROFILES_DIR`, `MODS`, `MISSION`.
`HiveExt.ini` is patched and the SQL schema imported the same way as Epoch (use
`DB_NAME=dayz` if you keep the two apart).

## Hive database

`docker-compose.yml` runs MariaDB with `MARIADB_DATABASE/USER/PASSWORD` taken
from `DB_NAME`, `DB_USER`, `DB_PASSWORD`. `scripts/bootstrap-db.sh` waits for it,
creates the schema from the pack's SQL **only when the database is empty**, and
is a no-op afterwards — so player data survives restarts.

* Changing `DB_PASSWORD`/`DB_NAME` later: the hive is patched on every start, but
  an existing `db` volume keeps the old credentials. Either update them in
  MariaDB or start fresh with `docker compose down -v` (deletes player data).
* Running DayZ and Epoch side by side means separate servers, DBs and ports.
* Schema files land in `./data/arma2/sql` (from the packs); `DB_SCHEMA` can point
  at a different one.

## Configuration

Everything is driven by environment variables (see `.env.example`):

| Variable | Default | Meaning |
| --- | --- | --- |
| `STEAM_USERNAME` / `STEAM_PASSWORD` | `anonymous` / empty | SteamCMD account; must own the games (anonymous always fails) |
| `STEAM_APPS` | `33935` | Space separated app IDs to install |
| `UPDATE_ON_START` / `STEAM_VALIDATE` | `1` / `1` | Update on start, validate files |
| `MOD_PROFILE` | `none` | `none`, `dayz` or `epoch` |
| `INSTALL_MODS` / `MOD_REINSTALL` | empty / `0` | Extra packs to install / re-extract over existing files |
| `EPOCH_CLIENT_URL`, `EPOCH_SERVER_URL`, `EPOCH_ARCHIVE_PASSWORD` | official Drive release / `123456` | Epoch pack sources |
| `DAYZ_SERVER_URL`, `DAYZ_ARCHIVE_PASSWORD` | empty | DayZ pack source (required for `dayz`) |
| `DB_HOST` / `DB_PORT` | empty / `3306` | Hive database; unset means no DB setup at all |
| `DB_NAME` / `DB_USER` / `DB_PASSWORD` | `dayz_epoch` / `dayz` / empty | Hive credentials |
| `SERVER_EXE` | auto | `arma2oaserver.exe` or `arma2server.exe` |
| `SERVER_NAME` | `server` | `-name`, profile folder name |
| `PORT` | `2302` | `-port` |
| `MODS` | empty (profile default) | `-mod`, e.g. `@DayZ_Epoch;@DayZ_Epoch_Server` |
| `WORLD` | empty | `-world`, commonly `empty` |
| `CPUCCOUNT` / `EXTHREADS` | empty | `-cpuCount` / `-exThreads` |
| `EXTRA_ARGS` | empty | Extra command line arguments, appended verbatim |
| `SERVER_CFG_FILE` / `BASIC_CFG_FILE` / `PROFILES_DIR` | profile-dependent | Override the config paths for unknown pack layouts |
| `PATCH_CONFIG` | `1` | Apply the container settings to the pack config once |
| `GENERATE_CONFIGS` | `1` | Create missing `server.cfg` / `basic.cfg` (profile `none`) |
| `SERVER_HOSTNAME`, `MAX_PLAYERS`, `SERVER_PASSWORD`, `ADMIN_PASSWORD` | see `.env.example` | Written into the config |
| `MOTD` | welcome text | `\|` separated lines |
| `MISSION` | empty | Adds a `class Missions` entry (profile `none`) |
| `BATTLEYE` / `BE_RCON_PASSWORD` / `BE_PATH` | `1` / empty / auto | BattlEye settings |
| `STEAM_PORT` / `STEAM_QUERY_PORT` | `8766` / `27016` | Must match the ports you publish |

## Mods, missions, keys

* Extra mods: drop each mod next to the server files (`./data/arma2/@MyMod`) and
  add it to `MODS` (`@DayZ_Epoch;@DayZ_Epoch_Server;@MyMod`).
* Missions: `./data/arma2/MPMissions` (the Epoch pack ships `DayZ_Epoch_*`
  folders for every map; the server uses the one named in the config's
  `class Missions`).
* Signature keys: `.bikey` files in `./data/arma2/keys`. With
  `verifySignatures = 2`, unsigned content is rejected.

## Ports

| Port | Protocol | Purpose |
| --- | --- | --- |
| 2302 | UDP | Game traffic |
| 2303–2305 | UDP | Adjacent game/voice ports; the Epoch pack's example uses 2303/2304 for Steam/query |
| 8766 | UDP | Steam port (`steamport`) |
| 27016 | UDP | Steam query port (`steamqueryport`) |

Publish and forward all of them if you want the server in the Steam browser. On
a Linux host, `network_mode: host` (commented in `docker-compose.yml`) is the
least surprising option for these older builds; then set `STEAM_PORT` /
`STEAM_QUERY_PORT` (and `PORT`) to unused values if you run several servers.

## Combined Operations

To serve A2 content (Chernarus, A2 units/weapons — required by DayZ and Epoch),
install the OA server **and** the A2 game data with the same install directory,
which merges them into one Combined Operations server:

```ini
STEAM_USERNAME=your_account      # must own Arma 2 and Operation Arrowhead
STEAM_PASSWORD=...
STEAM_APPS=33935 33930 33910
```

A few installs need A2's `AddOns`, `Dta` and `Common` folders copied over the OA
files by hand; if startup reports missing addons, copy them inside
`./data/arma2`. If you keep A2 in a separate directory instead, add it to the mod
list, e.g. `MODS=@DayZ_Epoch;@DayZ_Epoch_Server;EXPANSION;ca`.

## Operating notes

* **BattlEye** runs inside the game process. It generally works under Wine, but
  if the server refuses clients or crash-loops with `BattlEye = 1`, set
  `BATTLEYE=0` (or edit the config). Clients connecting to a BattlEye server
  must run BattlEye too.
* **Shutdown**: `docker compose stop` sends SIGTERM; the server may need the
  60 s grace period to flush its profile and hive data. Avoid `docker kill` on a
  live server.
* **Pack config location**: Epoch's readme recommends keeping the config/profile
  folder outside the game directory so clients cannot read it. In the container
  it lives in `/arma2/DZE_Server_Config`, which is fine as long as you do not
  expose that directory over HTTP or SMB.
* **Performance**: set `CPUCCOUNT`/`EXTHREADS` to match the host, and tune
  `basic.cfg` bandwidth values to real bandwidth. The server is a 32-bit
  process, so `EXTRA_ARGS=-maxMem=2047` is the practical ceiling.
* **Files are owned by root** inside the image. On Linux hosts, edit
  `./data/arma2` with `sudo` or fix ownership once:
  `docker run --rm -v "$PWD/data/arma2:/arma2" -it --entrypoint chown arma2-server -R 1000:1000 /arma2`.

## Updating

```bash
docker compose build --pull
docker compose up -d      # UPDATE_ON_START=1 refreshes the server files
```

Set `STEAM_VALIDATE=0` for faster, non-validating updates. Mod packs are only
installed when their folders are missing; `MOD_REINSTALL=1` re-extracts them
(keep in mind that a newer pack may need a schema update — see the pack's SQL
`*Updates.sql`).

## Troubleshooting

```bash
docker compose logs -f arma2            # entrypoint, mod install, server output
ls data/arma2                           # server files landed?
ls data/arma2/DZE_Server_Config         # Epoch config, BattlEye filters, profiles
docker compose logs mariadb             # hive database
```

* `SteamCMD failed` / `No subscription` — the account does not own Arma 2 or
  Operation Arrowhead, `STEAM_USERNAME` is still `anonymous`, a Steam Guard code
  is pending (run the update interactively), or the app ID is wrong for your
  store package (try `33900` instead of `33910`).
* `no server executable found` — the download did not finish; check the
  SteamCMD output above the error.
* `no DayZ pack archive` — `MOD_PROFILE=dayz` needs `DAYZ_SERVER_URL` or a pack
  in `./mods`.
* `Google Drive download failed` — Google throttles/quarantines large Drive
  downloads; retry, or download the pack by hand and put it in `./mods`.
* `wrong archive password` — Epoch's release uses `123456`; set
  `EPOCH_ARCHIVE_PASSWORD` for a different pack.
* No tables / `HiveExt` errors — check `docker compose logs mariadb`, the
  credentials in `DB_*`, and that `data/arma2/sql/epoch.sql` exists.
* Wine errors about `d3dx9_*.dll` or `vcruntime140.dll` — the image installs
  DirectX 9 and the MSVC runtimes via winetricks at build time; rebuild without
  cache if that step failed.
* Server exits immediately — read the RPT log in
  `data/arma2/DZE_Server_Config/Users/server` (or `data/arma2/profiles/server`),
  and check `MODS` (a missing mod folder stops startup).
