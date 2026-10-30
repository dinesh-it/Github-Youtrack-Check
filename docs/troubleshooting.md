# Troubleshooting

## Failed web hook deliveries
With GitHub App authentication the service redelivers failed web hook deliveries by itself: every
`REDELIVERY_INTERVAL` (5 min) and once at startup it scans the app's deliveries since the previous scan,
remembers the failed ones (by delivery guid) and asks GitHub to deliver them again with backoff until one
succeeds or `REDELIVERY_MAX_ATTEMPTS` is reached. GitHub keeps deliveries for 3 days. A delivery which keeps
failing (eg: `401` because `GITHUB_SECRET` does not match the app settings) is logged and shown by
`ci-doctor.pl status`.

Deliveries which fail with `timed out` and never show up in the service log are usually dropped by the
IP allow list: github added a web hook IP range (https://api.github.com/meta, `hooks`) which the micro-ci
security group (`tf-aws-network` `app-vpc/securitygroups.tf`) does not allow yet. `ci-doctor.pl status` lists
such ranges as `NOT ALLOWED` and fails, allow them in the security group and `GITHUB_HOOK_CIDRS`.

## ci-doctor
`scripts/ci-doctor.pl` checks and fixes things from the terminal. Run it on the service host as the
service user (a login shell loads the perl env from `/etc/profile.d/pams-perl-env.sh`), it reads the service env file (`/etc/pams/service/github-webhook-listener/env` by default,
or `--env-file`):

```
sudo -u github-webhook-listener bash -lc '/opt/git/micro-ci-chk-youtrack/scripts/ci-doctor.pl <command>'
```

| Command | |
|---------|-|
| `status` | Probe, spooler, check queue, pending web hook redeliveries and github web hook IP ranges not allowed |
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

## JSON output for monitoring
`--json` (before the command) prints one JSON document on stdout, logs go to stderr. Every document has
`command` and `ok`, errors are `{"ok": false, "error": "..."}`. Exit code: `0` ok, `1` problem found or
command failed, `2` usage error.

```
ci-doctor.pl --json status
{"command":"status","ok":true,
 "probe":{"code":200,"ok":true,"status":"ok","url":"http://localhost/ghyt-ci"},
 "spooler":{"age_secs":12,"last_run":"2026-10-29T08:00:00Z"},
 "queue":{"commits":0,"oldest_secs":null,"pr_titles":0,"pull_requests":0},
 "redelivery":{"failed_count":1,"gave_up_count":0,"last_scan":"...","last_scan_secs":40,
   "failed":[{"guid":"...","event":"push","status_code":502,"attempts":1,"gave_up":false,...}]},
 "database":"/var/lib/github-youtrack/github_web_hook.db"}
```

Useful alerts from `status`: `ok` false (probe down), `spooler.age_secs` > 120, `queue.oldest_secs` growing
(checks stuck), `redelivery.gave_up_count` > 0 (web hooks keep failing), `redelivery.last_scan_secs` > 900.
`deliveries --failed --json` exits `1` while any web hook delivery is not delivered yet.
