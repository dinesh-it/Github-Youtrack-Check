# Git Sync
The service can notify git sync clients when a repository changes, the client then fetches the configured branches into local repositories.

## Protocol
* A client connects to `ws://<yourhost>:3000/githubpush` and has to authenticate before receiving anything
    1. Server sends `{"type":"challenge","challenge":"<hex>"}`
    2. Client replies `{"type":"auth","repos":[...],"response":"<hmac>"}`, the response is an HMAC-SHA256 over the challenge and the repo list with a key derived from `GH_WEBSOCKET_SECRET`
    3. Server sends `{"type":"ready"}`, the client then sends `give-latest` to receive the latest commit of each branch of its repos
* After that the server sends an update whenever a configured repo changes. Each message is encrypted and authenticated with keys derived from `GH_WEBSOCKET_SECRET` (see `lib/SecureChannel.pm`) and carries `project`, `ref`, `sha`, `remote_url` and, when using a github app, a read only token scoped to that repository.
* Use `wss://` (TLS in front of the service) where possible.

## Client
* `git-sync-client/update_git_repo.pl` is the perl client and `git-sync-client/repo_update_config.pl` a sample config file
* The client loads `lib/SecureChannel.pm` from the checkout and reads the secret from `GH_WEBSOCKET_SECRET` env
* It passes the token to git through a credential helper pinned to the remote host, never on the command line
* Repos using git LFS (an `lfs` directory in the local repo) also get `git lfs fetch --all` with the same credential handling
* `salt_fileserver_update => 1` on a repo runs `salt-run fileserver.update` after a successful fetch (salt master)
* `client_id` (default host name) identifies the client, a re-connect replaces the older session of the same client id and repo list
* `-u` (update head ok) is only used for bare repos, LFS failures skip the salt fileserver update, `salt-run` runs in a sub process
* Keep alive ping every `ping_interval` (60) secs and `give-latest` re-sync every `resync_interval` (180) secs
* Remote URLs sent by the server are only accepted for `allowed_remote_hosts` (default `github.com`) and `allowed_owners` (default `exceleron`), a `remote_url` in the config overrides it

## Ref ordering
Pushes can be delivered late or redelivered (the service redelivers failed web hooks). A push which is not
newer than the state the service already has for that ref never moves it back: the ref is resolved from the
GitHub API instead, and a ref which does not exist there any more is removed.

## Changing the secret / protocol
Server and clients must use the same `GH_WEBSOCKET_SECRET` and protocol version, deploy the server and all clients together. Older clients (before the authenticated handshake) can not connect to the new server.
