# Configuration
All the configs are read from ENV. Keep the env file, the github app private key and the database in `local/` (ignored by git), eg: `local/.env`.
```
# Required
export YOUTRACK_TOKEN="<youtrack_token>"
export YOUTRACK_HOST="<youtrack_host>"
export GITHUB_SECRET="web_hook_secret"

export GITHUB_TOKEN="github_token"
or
export GITHUB_APP_KEY_FILE='./local/private-key.pem' (if using a github app)

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
| REDELIVERY_INTERVAL | 300 | Seconds between scans for failed GitHub App web hook deliveries, `0` disables redelivery |
| REDELIVERY_MAX_ATTEMPTS | 10 | Redeliveries per failed delivery (backoff 5m, 10m, 20m ... max 6h) |
| REDELIVERY_LOOKBACK | 21600 | Seconds of deliveries scanned on the very first run |
