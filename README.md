# Github-Youtrack-Check
Micro service to
* check and update status for the commits pushed to github has a valid youtrack ticket mentioned.
* check and update Pull request based on config
* Adds comment in the Youtrack ticket with the respective pull request
* Can be used for auto sync local git repo when remote repository is updated

## Config
All the configs are read from ENV
```
# Required
export YOUTRACK_TOKEN="<youtrack_token>"
export YOUTRACK_HOST="<youtrack_host>"
export GITHUB_SECRET="web_hook_secret"

export GITHUB_TOKEN="github_token"
or
export GITHUB_APP_KEY_FILE='./private-key.pem' (if using a github app)

# Optional
export GITHUB_WEB_HOOK_DB="/tmp/github_web_hook.db"
export GITHUB_WEB_HOOK_DB_USER=""
export GITHUB_WEB_HOOK_DB_PWD=""
export GH_WEBSOCKET_SECRET="$(openssl rand -hex 32)"
export PR_BRANCH_YT_CHECK='PRODUCTION*=CLUSTER-*'
export DISABLE_CHECK_API=1
```

#### YOUTRACK_TOKEN
YouTrack permanent token. Refer [Create a Permanent Token](https://www.jetbrains.com/help/youtrack/standalone/Manage-Permanent-Token.html#obtain-permanent-token) at youtrack help section to create one.
    * Select YouTrack scope while generating the token.

#### YOUTRACK_HOST
Host name with protocol where the youtrack is served eg: https://company.myjetbrains.com

#### GITHUB_SECRET
The secret string used while creating github web hook. Required - every web hook payload is verified with the `X-Hub-Signature-256` header and rejected when it does not match.

#### GITHUB_TOKEN
Github personal access token, Refer [Creating a personal access token](https://help.github.com/en/articles/creating-a-personal-access-token-for-the-command-line) at github help section.
     * Repo privilage is required for this token

#### GITHUB_APP_KEY_FILE / GITHUB_APP_KEY
Github App private key file path (or the key itself in `GITHUB_APP_KEY`). `GITHUB_APP_ID` and `GITHUB_TOKEN_URL` (`https://api.github.com/app/installations/<id>/access_tokens`) are needed until the token file is created.

#### GITHUB_WEB_HOOK_DB
This script uses a sqlite database file to store commit details temporarily, please specify the full path including database name. By default it is set to `/tmp/github_web_hook.db`.

#### GITHUB_WEB_HOOK_DB_USER and GITHUB_WEB_HOOK_DB_PWD
UserName and password for the above mentioned database if preferred.

#### GH_WEBSOCKET_SECRET
Shared secret between the service and the git sync clients, at least 32 characters - generate it with `openssl rand -hex 32`. The git sync websocket is disabled when it is not set.

#### PR_BRANCH_YT_CHECK
eg value: 'PRODUCTION*=CLUSTER-*' - Enables specific ticket check for PR's created against mentioned branch - check happens on the title of the PR

#### DISABLE_CHECK_API=1
If GITHUB_APP_KEY_FILE is set, github checks API will be used to better utilise the github app feature, we can set the flag to disable this behaviour. Github status API will be used otherwise. Enabling this feature will send checks API with a link to open the Github App - So if you have created an app for Authentication purpose only then its recomended to disable this feature.

#### Other optional ENV
| ENV | Default | Description |
|-----|---------|-------------|
| GITHUB_ORG | exceleron | Organisation polled for missed events |
| GITHUB_TOKEN_FILE | /tmp/github_app_access.token | App access token shared with the helper scripts (written with 0600) |
| YOUTRACK_CI_LOGIN | ci | YouTrack login of the token owner, its comment is updated with the PR links |
| HTTP_TIMEOUT | 20 | Timeout in seconds for github / youtrack API calls |
| MAX_RETRY_AGE | 86400 | Seconds a failing commit / PR check is retried before giving up |
| PROBE_MAX_AGE | 120 | Probe responds 503 when the spooler did not run for this many seconds |
| GH_WEBSOCKET_MAX_CLIENTS | 50 | Max concurrent git sync connections |
| LOG_LEVEL | info (production) | trace, debug, info, warn, error or fatal |

## Usage
* Install all the perl modules required using `cpanm` command
`cpanm --installdeps .`

* Start github web hook listener and spool service
`github_web_hook.pl daemon -m production -l http://*:3000`

* Now a micro service to listen for github web hook is ready at your server on port 3000.
* Configure your Github web hook with address pointing to `http://<yourhost>:3000/check_youtrack` for `push` and `pull_request` event types, with the same secret as `GITHUB_SECRET`.
    * Web Hook settings can be found at Github.com Repository->settings->Hooks
* You should start seeing the request coming to your microservice on each push to github now.

Additionally there are helper scripts to force check pull requests without waiting for github web hook.
`./scripts/add_pull_request.pl 'repo_owner' 'repo_name' 'pull_request_number'`
`./scripts/add_all_open_pull.pl 'repo_owner' 'repo_name'`

Thats all, green tick marks (if comment has valid ticket) or red cross mark (if commits does not have a valid youtrack ticket) will appear for each commits you push to github now.

Note: Configure the service via daemon or systemd to auto restart on exception.

* To test if the service is up and running there is a probe path supported by the service - hit `http://<yourhost>:3000/ghyt-ci` and you should see json output with status 'ok' to make sure the service is running. It responds with 503 when the spooler is not running.

## Tests
`make test` - runs the unit tests and end to end tests against a mock GitHub / YouTrack API, no real credentials are used.

`make test-docker` - runs the same tests in `ghcr.io/exceleron/alma9-perl`, the AlmaLinux perl base matching the EC2 hosts (`docker/Dockerfile.test`, test only - not used for deployment).

## Git Sync Feature
* A client connects to `ws://<yourhost>:3000/githubpush` and has to authenticate before receiving anything
    1. Server sends `{"type":"challenge","challenge":"<hex>"}`
    2. Client replies `{"type":"auth","repos":[...],"response":"<hmac>"}`, the response is an HMAC-SHA256 over the challenge and the repo list with a key derived from `GH_WEBSOCKET_SECRET`
    3. Server sends `{"type":"ready"}`, the client then sends `give-latest` to receive the latest commit of each branch of its repos
* After that the server sends an update whenever a configured repo changes. Each message is encrypted and authenticated with keys derived from `GH_WEBSOCKET_SECRET` (see `SecureChannel.pm`) and carries `project`, `ref`, `sha`, `remote_url` and, when using a github app, a read only token scoped to that repository.
* Use `wss://` (TLS in front of the service) where possible.

* Refer: `./git-sync-client/update_git_repo.pl` and `./git-sync-client/repo_update_config.pl` - For the perl client and a sample config file. The client needs `SecureChannel.pm` from the project root and reads the secret from `GH_WEBSOCKET_SECRET` env. It passes the token to git through a credential helper, never on the command line.

## Deployment
The service and the git sync client run directly on AlmaLinux EC2 hosts under systemd, from a checkout at `/opt/git/Github-Youtrack-Check` (adjust the unit files for another path).

### Server
1. Run the tests: `make test`
2. On the server, update the checkout: `cd /opt/git/Github-Youtrack-Check && git pull`
3. Install / update the perl modules: `cpanm --installdeps .`
4. Keep the config in `/opt/git/Github-Youtrack-Check/.env` (`chmod 600`, owned by root) with at least `GITHUB_SECRET` (same as the GitHub web hook settings), `YOUTRACK_TOKEN`, `YOUTRACK_HOST`, the GitHub app / token envs and `GH_WEBSOCKET_SECRET` (min 32 characters - `openssl rand -hex 32`)
5. Install the unit once and restart on every deploy
```
cp service/github-webhook-listener.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now github-webhook-listener
systemctl restart github-webhook-listener
```
6. Verify `curl http://localhost/ghyt-ci` returns `status: ok` and check `journalctl -u github-webhook-listener`
    * The probe returns 503 when the spooler is not running, keep any health check tolerant to short spooler pauses

### Git sync client
On each host that mirrors repositories:
1. Requirements: perl with `Mojolicious` and `Config::Any` (`cpanm --installdeps --with-feature=git-sync-client .`) and git 2.10 or newer
2. Use a checkout of this repository (the client needs `SecureChannel.pm` from the project root)
3. Create the config from `git-sync-client/repo_update_config.pl` with the repos / branches to sync, `chmod 600` it
4. Create `git-sync-client/.env` (`chmod 600`) with `EX_GITHOOK_CONFIG_FILE=<config file>` and `GH_WEBSOCKET_SECRET=<same secret as the server>` (optional `DEBUG=1`)
5. Install and start `service/git-sync-client.service` the same way as the server unit
6. `journalctl -u git-sync-client` should show `Connected! Getting latest info...` - authentication failures are logged on the server

### Changing the git sync secret / protocol
Server and clients must use the same `GH_WEBSOCKET_SECRET` and protocol version, deploy the server and all clients together. Older clients (before the authenticated handshake) can not connect to the new server.
