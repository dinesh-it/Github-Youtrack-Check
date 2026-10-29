# Deployment
The service and the git sync client run directly on AlmaLinux EC2 hosts under systemd, from a checkout at `/opt/git/Github-Youtrack-Check` (adjust the unit files for another path).

Local files (env file, github app key, database) go in `local/` of the checkout, it is ignored by git. The units also read a `.env` from the checkout root for older setups.

The unit files in `service/` are for a plain checkout. The salt managed AWS deployment (`pams-salt-cfg`,
`sysmodules/micro-ci` and `network-management/git-repo`) has its own units: the service runs as
`github-webhook-listener` with its env in `/etc/pams/service/github-webhook-listener/env`, state in
`/var/lib/github-youtrack`, and the nm02 client is a salt managed copy. `ci-doctor.pl` looks for the salt env
file first, then `local/.env` and `.env`.

## Server
1. Run the tests: `make test` (or `make test-docker`)
2. On the server, update the checkout: `cd /opt/git/Github-Youtrack-Check && git pull`
3. Install / update the perl modules: `cpanm --installdeps .`
4. Keep the config in `local/.env` (`chmod 600`, owned by root) with at least `GITHUB_SECRET` (same as the GitHub web hook settings), `YOUTRACK_TOKEN`, `YOUTRACK_HOST`, the GitHub app / token envs and `GH_WEBSOCKET_SECRET` (min 32 characters - `openssl rand -hex 32`), see [configuration](configuration.md)
5. Install the unit once and restart on every deploy
```
cp service/github-webhook-listener.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now github-webhook-listener
systemctl restart github-webhook-listener
```
6. Verify `curl http://localhost/ghyt-ci` returns `status: ok` and check `journalctl -u github-webhook-listener`
    * The probe returns 503 when the spooler is not running, keep any health check tolerant to short spooler pauses

## Git sync client
On each host that mirrors repositories:
1. Requirements: perl with `Mojolicious` and `Config::Any` (`cpanm --installdeps --with-feature=git-sync-client .`) and git 2.10 or newer
2. Use a checkout of this repository (the client needs `lib/SecureChannel.pm`)
3. Create the config from `git-sync-client/repo_update_config.pl` in `local/` with the repos / branches to sync, `chmod 600` it
4. Create `local/git-sync-client.env` (`chmod 600`) with `EX_GITHOOK_CONFIG_FILE=<config file>` and `GH_WEBSOCKET_SECRET=<same secret as the server>` (optional `DEBUG=1`)
5. Install and start `service/git-sync-client.service` the same way as the server unit
6. `journalctl -u git-sync-client` should show `Connected! Getting latest info...` - authentication failures are logged on the server

See [git sync](git-sync.md) for the protocol and secret rotation.
