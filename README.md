# Github-Youtrack-Check
Micro service to
* check and update status for the commits pushed to github has a valid youtrack ticket mentioned.
* check and update Pull request based on config
* Adds comment in the Youtrack ticket with the respective pull request
* Can be used for auto sync local git repo when remote repository is updated

## Layout
| Path | |
|------|-|
| `github_web_hook.pl` | The service - web hook listener, check spooler and git sync websocket |
| `lib/` | Perl modules |
| `scripts/` | Helper scripts |
| `git-sync-client/` | Git sync client and sample config |
| `service/` | systemd units |
| `t/` | Tests |
| `docker/` | Test only Dockerfile |
| `docs/` | Documentation |
| `local/` | Local env, keys, database and scratch files - ignored by git |

## Quick start
* Install the perl modules: `cpanm --installdeps .`
* Set the required ENV (see [configuration](docs/configuration.md)) and start the service
`github_web_hook.pl daemon -m production -l http://*:3000`
* Configure your Github web hook with address pointing to `http://<yourhost>:3000/check_youtrack` for `push` and `pull_request` event types, with the same secret as `GITHUB_SECRET`.
    * Web Hook settings can be found at Github.com Repository->settings->Hooks
* Green tick marks (if comment has valid ticket) or red cross mark (if commits does not have a valid youtrack ticket) will appear for each commits you push to github now.
* Probe: `http://<yourhost>:3000/ghyt-ci` responds with status 'ok', or 503 when the spooler is not running.

Helper scripts to force check pull requests without waiting for github web hook:
`./scripts/add_pull_request.pl 'repo_owner' 'repo_name' 'pull_request_number'`
`./scripts/add_all_open_pull.pl 'repo_owner' 'repo_name'`

## Troubleshooting
`scripts/ci-doctor.pl` - status, ticket / PR checks, web hook deliveries and redelivery, queue and git sync
state from the terminal. Failed GitHub App web hook deliveries are redelivered automatically.
See [troubleshooting](docs/troubleshooting.md).

## Docs
* [Configuration](docs/configuration.md)
* [Troubleshooting](docs/troubleshooting.md) - `ci-doctor.pl`, web hook redelivery
* [Deployment](docs/deployment.md) - EC2 / systemd for the server and git sync clients
* [Git sync](docs/git-sync.md) - protocol and client

## Tests
`make test` - runs the unit tests and end to end tests against a mock GitHub / YouTrack API, no real credentials are used.

`make test-docker` - runs the same tests in `ghcr.io/exceleron/alma9-perl`, the AlmaLinux perl base matching the EC2 hosts (`docker/Dockerfile.test`, test only - not used for deployment).
