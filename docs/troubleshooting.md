# Troubleshooting

## Failed web hook deliveries
With GitHub App authentication the service redelivers failed web hook deliveries by itself: every
`REDELIVERY_INTERVAL` (5 min) and once at startup it scans the app's deliveries since the previous scan,
remembers the failed ones (by delivery guid) and asks GitHub to deliver them again with backoff until one
succeeds or `REDELIVERY_MAX_ATTEMPTS` is reached. GitHub keeps deliveries for 3 days. A delivery which keeps
failing (eg: `401` because `GITHUB_SECRET` does not match the app settings) is logged and shown by
`ci-doctor.pl status`.

## ci-doctor
`scripts/ci-doctor.pl` checks and fixes things from the terminal. Run it on the service host as the
service user (a login shell loads the perl env from `/etc/profile.d/pams-perl-env.sh`), it reads the service env file (`/etc/pams/service/github-webhook-listener/env` by default,
or `--env-file`):

```
sudo -u github-webhook-listener bash -lc '/opt/git/micro-ci-chk-youtrack/scripts/ci-doctor.pl <command>'
```

| Command | |
|---------|-|
| `status` | Probe, spooler, check queue and pending web hook redeliveries |
| `check-ticket "OPS-1: message"` | Ticket found in a commit message and the YouTrack result |
| `check-ticket --base PRODUCTION "PR title"` | Same for a PR title, including the `PR_BRANCH_YT_CHECK` rule |
| `check-pr exceleron/PAMS-WWW#123` | What the check posts for the PR title and each commit (dry run) |
| `check-pr --queue exceleron/PAMS-WWW#123` | Re-check the PR for real, the service posts the statuses |
| `deliveries [--failed] [--since 6h]` | GitHub App web hook deliveries, `--failed` shows the not yet delivered ones |
| `redeliver <DELIVERY_ID>` | Deliver one web hook again |
| `redeliver --failed` | Run the automatic redelivery now |
| `queue` / `queue drop <ROW_ID>` | Pending check queue entries / remove one |
| `sync <REPO> [BRANCH]` | Refresh branch state from GitHub, git sync clients fetch it on their next re-sync |

`--debug` shows the API calls.
