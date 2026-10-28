# How to host an Arma 2 / DayZ Epoch server with this container

A step-by-step walkthrough from an empty checkout to a running server: what to
put in `.env`, how the first start behaves, how to check that it actually came
up, how players connect, and what to do for updates, backups and mod trouble.

Reference material lives in [README.md](README.md); this file is the procedure.

---

## 1. What you need

| Requirement | Why |
| --- | --- |
| Docker with Linux containers (Docker Desktop on Windows/macOS, Docker Engine on Linux) | The image is Debian + Wine |
| A Steam account that **owns Arma 2 and Arma 2: Operation Arrowhead** | SteamCMD refuses the server tool apps for `anonymous` (`No subscription`) |
| ~20 GB free disk | ~5 GB Arma server files, ~4.6 GB Epoch client download, ~7 GB unpacked `@DayZ_Epoch`, MariaDB data |
| 2 GB+ RAM for the container, 4 GB recommended | 32-bit server + Wine + MariaDB |
| Open UDP ports 2302, 8766, 27016 (and 2303–2305) | Players, Steam listing, Steam query |

The Steam account is only used to download files. It is not the account players
use, and it is not needed on the server after the login is cached.

---

## 2. Get the project and build the image

Run every command from the project folder.

```bash
docker compose build
```

Expect 2–5 minutes: Debian packages, Wine prefix, DirectX 9 and the MSVC
runtimes are baked in. The result is the local image `arma2-server:latest`.

---

## 3. Create `.env`

```bash
cp .env.example .env
```

Now edit `.env`. The minimum for a **DayZ Epoch on Chernarus** server:

```ini
# --- Steam (needed once, for the download) ---
STEAM_USERNAME=your_steam_account
STEAM_PASSWORD=your_password
STEAM_APPS=33935 33930 33910       # OA dedicated server + OA data + Arma 2 data
UPDATE_ON_START=1

# --- What to host ---
MOD_PROFILE=epoch
SERVER_HOSTNAME=My Epoch Server
MAX_PLAYERS=40
ADMIN_PASSWORD=pick-a-real-admin-password
SERVER_PASSWORD=                    # empty = public server
BE_RCON_PASSWORD=pick-another-password

# --- Hive database (leave as is) ---
DB_HOST=mariadb
DB_NAME=dayz_epoch
DB_USER=dayz
DB_PASSWORD=dayz
DB_ROOT_PASSWORD=dayzroot
```

Notes:

* `STEAM_APPS=33935 33930 33910` gives you Combined Operations, which Chernarus
  and Epoch require. `33910` is the Arma 2 store package; if SteamCMD reports it
  as not owned, try `33900` instead.
* `DB_*` values are used by both the MariaDB service and the hive config, so
  keep them consistent. Change them before the first start, not after.
* Everything else (`PORT`, `MODS`, `BATTLEYE`, `STEAM_PORT`, …) already has a
  sensible default; see the table in [README.md](README.md#configuration).

---

## 4. Prime the Steam login once (Steam Guard)

The container is not interactive by default, so a Steam Guard prompt would stall
the first start. Run the download by hand once:

```bash
docker compose run --rm -it --entrypoint /opt/steamcmd/steamcmd.sh arma2 \
  +@sSteamCmdForcePlatformType windows +force_install_dir /arma2 \
  +login YOUR_STEAM_ACCOUNT +app_update 33935 validate +quit
```

* Enter your password and the Steam Guard code when asked.
* Repeat with `+app_update 33930 validate` and `+app_update 33910 validate` (or
  `33900`) if you want Combined Operations data in the same pass.
* The login session is stored in the `steam` volume, so later starts and even
  re-created containers do not ask again.
* If you skipped this step, `docker compose up` still works as long as the
  account needs no Steam Guard code, because `.env` carries the password.

---

## 5. Start the server

```bash
docker compose up -d
docker compose logs -f arma2
```

### What the first start does (in order)

1. **Steam download / validation** — `33935` (+ any other `STEAM_APPS`) into
   `/arma2`. Several GB, takes a while.
2. **Mod install** — downloads the official DayZ Epoch 1.0.7.1 client (4.6 GB)
   and server (43 MB) packs from Google Drive, unpacks them and copies
   `@DayZ_Epoch`, `@DayZ_Epoch_Server`, `DZE_Server_Config`, `MPMissions`,
   `keys`, `sql` and the hive DLLs into `./data/arma2`.
3. **Config** — applies your `.env` values to
   `data/arma2/DZE_Server_Config/11_chernarus.cfg` once.
4. **Database** — waits for MariaDB, creates `dayz_epoch`, imports
   `epoch.sql` + `add_recommended_mysql_events.sql`, enables the event
   scheduler.
5. **Launch** — `wine arma2oaserver.exe -mod=@DayZ_Epoch;@DayZ_Epoch_Server …`.

Lines that mean it worked:

```
[mods] epoch ready in /arma2
[entrypoint] pointing /arma2/DZE_Server_Config/HiveExt.ini at dayz@mariadb:3306/dayz_epoch
[db] database dayz_epoch ready with 5 tables
[entrypoint] profile: epoch, mods: @DayZ_Epoch;@DayZ_Epoch_Server
[entrypoint] starting: wine arma2oaserver.exe -port=2302 … -BEpath=DZE_Server_Config/BattlEye
```

The server keeps running in the foreground of that container; `Ctrl+C` on the
log command does not stop it.

---

## 6. Check that it is really up

```bash
docker compose ps                     # arma2 up/healthy, mariadb up/healthy
docker port arma2-server              # 2302-2305/udp, 8766/udp, 27016/udp published
docker compose logs --tail=50 arma2   # no repeated restarts / Wine errors
```

Server-side proof:

```bash
ls data/arma2                                  # @DayZ_Epoch, @DayZ_Epoch_Server, DZE_Server_Config, MPMissions
ls data/arma2/DZE_Server_Config                 # 11_chernarus.cfg, HiveExt.ini, BattlEye/, Users/
ls -lt data/arma2/DZE_Server_Config | head      # profiles/, log files; cfg sets logFile = server_log.txt
docker compose exec mariadb sh -c \
  'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" -e "USE dayz_epoch; SHOW TABLES; SELECT COUNT(*) FROM Character_DATA;"'
```

RPT diagnostics (crash/startup problems) land under `data/arma2` — look for
`*.rpt` next to the config dir:

```bash
find data/arma2 -name '*.rpt' -newermt '-1 hour'
```

A server that is up will also answer the Steam query port from outside; if
`docker port` shows the mappings but nobody can see it, it is a firewall/port
forwarding problem, not an Arma problem.

---

## 7. Connect as a player

The client needs exactly what the server has:

1. **Arma 2: Operation Arrowhead + Arma 2** (Combined Operations) on the same
   build as the server — the shipped config requires build `144629`.
2. **`@DayZ_Epoch` 1.0.7.1** in the game folder (the same client pack the
   container downloads, so players can be handed the archive).
3. Launch parameter on the client: `-mod=@DayZ_Epoch` (plus `-nosplash` etc. as
   you like), then find the server in the Steam browser or connect directly to
   `IP:2302`.

In-game admin: press chat and use `#login <ADMIN_PASSWORD>`. BattlEye RCon uses
`BE_RCON_PASSWORD` from `.env`; the filters come from
`data/arma2/DZE_Server_Config/BattlEye`.

If players get kicked immediately for signature or build mismatch, check
`verifySignatures` in `11_chernarus.cfg` (the pack sets `2`) and that the
`keys/DayZEpoch1071.bikey` file is present.

---

## 8. Day-to-day operation

```bash
docker compose stop           # graceful stop (60 s grace for profile + hive flush)
docker compose start
docker compose restart
docker compose down           # stop and remove containers, keep data/steam/db volumes
```

**Change hostname, slots, passwords, ports** — edit `.env`, then re-apply once:

```bash
rm -f data/arma2/.container-patched-epoch   # allows the env values to be written again
docker compose up -d
```

Without deleting the marker, your hand edits in `11_chernarus.cfg` stay
authoritative — that is intentional. `HiveExt.ini` is re-pointed at the
database on every start, so never fix DB settings there.

**Update the Arma server**:

```bash
docker compose build --pull
docker compose up -d          # UPDATE_ON_START=1 validates and patches the game files
```

**Update the mod packs** (new Epoch release, or a pack you swapped in `./mods`):

```bash
# .env:  MOD_REINSTALL=1
docker compose up -d
# then set MOD_REINSTALL=0 again; read the pack's SQL *Updates.sql before using
# an upgraded pack against an existing database
```

**Backup / restore the hive**:

```bash
mkdir -p backups
docker compose exec -T mariadb sh -c \
  'mariadb-dump -uroot -p"$MARIADB_ROOT_PASSWORD" --single-transaction dayz_epoch' \
  > "backups/dayz_epoch-$(date +%F-%H%M).sql"

# restore into a fresh database
docker compose down
docker volume rm arma2_db          # name is <project>_db; see `docker volume ls`
docker compose up -d mariadb       # fresh volume, empty dayz_epoch database
docker compose logs --tail=5 mariadb   # wait for "ready for connections"
docker compose exec -T mariadb sh -c \
  'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" dayz_epoch' < backups/dayz_epoch-2026-10-25-1200.sql
docker compose up -d
```

Back up `data/arma2` too if you changed configs or added missions; the mod
folders themselves can be re-downloaded.

**Start over** (new map, corrupted hive, new account):

```bash
docker compose down -v        # -v also deletes the steam login and the database!
rm -rf data/arma2             # optional: re-download the game + mods
docker compose up -d
```

---

## 9. Other modes

### Plain Arma 2 / OA server (no mods, no database)

```ini
MOD_PROFILE=none
STEAM_APPS=33935
SERVER_HOSTNAME=Arma 2 Coop
MISSION=coop_01.Chernarus       # mission .pbo/.folder must be in data/arma2/MPMissions
```

Optional: drop `DB_HOST` from `.env` (or remove the `depends_on`/`mariadb`
service from `docker-compose.yml`) so no database starts.

### Vanilla DayZ

```ini
MOD_PROFILE=dayz
STEAM_APPS=33935 33930 33910
DAYZ_SERVER_URL=https://…/dayz-server-pack.zip   # required: no official download exists
DB_NAME=dayz                                     # keeps DayZ data apart from Epoch
```

Put the archive in `./mods` instead of a URL if you prefer (any `.7z`/`.zip`/`.rar`
without `epoch` in the name is used as the DayZ pack). Community packs differ in
layout; if the profile cannot find its config, set `SERVER_CFG_FILE`,
`BASIC_CFG_FILE`, `PROFILES_DIR` and `MODS` to match the pack.

### Other maps and extra mods

* Another Chernarus-like map: copy the pack's `DZE_Server_Config/<n>_<map>.cfg`
  pattern into use by setting `SERVER_CFG_FILE=DZE_Server_Config/1_takistan.cfg`
  (the cfg's `class Missions` selects the matching
  `data/arma2/MPMissions/DayZ_Epoch_1.Takistan`).
* Extra client mods: place `@MyMod` in `data/arma2` and append it to `MODS`
  (e.g. `MODS=@DayZ_Epoch;@DayZ_Epoch_Server;@MyMod`). Clients need the same mod
  and its `.bikey` in `data/arma2/keys`.

---

## 10. Ports and firewall

| Port | Protocol | What |
| --- | --- | --- |
| 2302 | UDP | Game traffic (`PORT`) |
| 2303–2305 | UDP | Adjacent/voice ports some mods bind |
| 8766 | UDP | Steam port (`steamport` in the cfg) |
| 27016 | UDP | Steam query port (`steamqueryport`) |

Forward exactly these on your router/firewall; keep them identical in the
published ports, `STEAM_PORT`/`STEAM_QUERY_PORT` and `11_chernarus.cfg`. Running
one server per host is simplest — a second instance needs its own ports, config
dir and database name.

---

## 11. Quick troubleshooting

| Symptom | Cause and fix |
| --- | --- |
| `No subscription` from SteamCMD | Account does not own the game, or `STEAM_USERNAME` is still `anonymous`. Fix `.env`, re-run step 4. |
| SteamCMD waits forever on first start | Steam Guard prompt in a non-interactive container — run step 4 interactively. |
| `no server executable found` | Steam download did not finish; check the SteamCMD output above the error, then restart with `UPDATE_ON_START=1`. |
| `Google Drive download failed` | Drive throttling/quarantine. Retry, or download the pack in a browser and drop it into `./mods` as `epoch-client-1.0.7.1.7z` / `epoch-server-1.0.7.1.7z`. |
| `cannot unpack … wrong archive password` | Epoch's release password is `123456`; set `EPOCH_ARCHIVE_PASSWORD` for a different pack. |
| `no dayz pack archive` | `MOD_PROFILE=dayz` needs `DAYZ_SERVER_URL` or a pack in `./mods`. |
| `no schema .sql file found` | The pack did not bring SQL; set `DB_SCHEMA=/arma2/sql/epoch.sql` (or the pack's file). |
| Hive errors, players spawn without gear, no persistence | `docker compose logs mariadb`, check `DB_*` matches the MariaDB service, and confirm the tables from step 6. Event scheduler must be `ON`. |
| Kicked for `requiredBuild` | Client and server Arma 2 OA builds differ; both must be `144629` for the shipped Epoch config. |
| BattlEye kicks/crashes under Wine | Set `BATTLEYE=0`, delete `data/arma2/.container-patched-epoch`, restart. |
| Wine complains about `d3dx9_*` / `vcruntime140.dll` | Rebuild without cache: `docker compose build --no-cache`. |
| Nothing in the Steam browser | UDP 8766/27016 not forwarded, or Steam ports differ between compose and the cfg. |
