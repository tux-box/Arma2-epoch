# Arma 2 OA server in Docker

Minimal container: `steamcmd/steamcmd:latest` plus Wine, running `arma2oaserver.exe` headless
under Xvfb. The image holds no game files. On first start steamcmd downloads Arma 2 (33910)
and Arma 2 Operation Arrowhead (33930) into the `./arma` bind mount; whenever
`arma2oaserver.exe` is already there, the download is skipped.

## Run

```sh
cp .env.example .env     # Steam account that owns both games
docker compose up -d --build
docker compose logs -f
```

The first start downloads ~13 GB and is slow. Later starts only launch the server.

## Layout

- `./arma` - game files, plus any mods, missions and server config you put there. Also holds
  the Wine prefix in `.wine`.
- `Dockerfile` - base image, 32-bit Wine, Xvfb, an `arma` user.
- `docker/entrypoint.sh` - download if needed, start Xvfb, launch the server.
- `compose.yml` - one service, UDP 2302-2305.

## Options

| Variable | Default | Meaning |
| --- | --- | --- |
| `STEAM_USERNAME` / `STEAM_PASSWORD` | - | account used by steamcmd |
| `PORT` | `2302` | `-port` |
| `NAME` | `server` | `-name`, the profile folder name |
| `CONFIG` | - | `-config`, for example `DZE_Server_Config/basic.cfg` |
| `CFG` | - | `-cfg`, for example `DZE_Server_Config/1_takistan.cfg` |
| `PROFILES` | - | `-profiles`, for example `DZE_Server_Config` |
| `MODS` | - | `-mod`, for example `@DayZ_Epoch;@DayZ_Epoch_Server;` |

With no `CONFIG`/`CFG` the server starts without a fixed mission, so clients are shown the
mission list. A `-cfg` pointing at a config with a `Missions` class (and the mission folder
present in `MPMissions`) is what makes a specific mission start on its own.

## Notes

- `XDG_RUNTIME_DIR=/tmp/xdg-arma` is set in the image; without it Wine logs
  `error: XDG_RUNTIME_DIR is invalid or not set in the environment.` on every start.
- Add a mod's `.bikey` files to `./arma/Keys` next to the default Arma keys; a server with
  `verifySignatures` enabled rejects missions signed with keys it does not have.
- This container is the game server only: no database or hive layer.
