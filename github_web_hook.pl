#!/usr/bin/env perl

# Micro service which
#  - checks the commits / pull request titles pushed to github have a valid
#    youtrack ticket and posts the result as a github status (or check run)
#  - adds the pull request link as a comment in the youtrack ticket
#  - notifies authenticated git sync clients about repository updates

use Mojolicious::Lite;
use Mojo::IOLoop;
use Mojo::JSON qw(encode_json from_json);
use Mojo::Util qw(secure_compare);
use Digest::SHA qw(hmac_sha256_hex);
use HTTP::Date qw(str2time);

use FindBin;
use lib "$FindBin::Bin/lib";
use Github;
use Youtrack;
use Store;
use Checker;
use Redelivery;
use SecureChannel;

$| = 1;

my $log = app->log;
$log->level($ENV{LOG_LEVEL}) if ($ENV{LOG_LEVEL});

# Signed cookies are not used, random secret avoids the default passphrase
app->secrets([unpack('H*', SecureChannel::random_bytes(32))]);

# GitHub web hook payloads are capped at 25 MB
app->max_request_size(25 * 1024 * 1024);

# ============================================================================ #
# Configuration
# ============================================================================ #

if (!$ENV{GITHUB_TOKEN} and !$ENV{GITHUB_APP_KEY_FILE} and !$ENV{GITHUB_APP_KEY}) {
    die "GITHUB_TOKEN or GITHUB_APP_KEY_FILE or GITHUB_APP_KEY ENV required\n";
}

foreach my $var (qw/YOUTRACK_TOKEN YOUTRACK_HOST GITHUB_SECRET/) {
    die "$var ENV required\n" if (!$ENV{$var});
}

# Shared secret for the git sync websocket, the websocket is disabled without it
my $channel;
if ($ENV{GH_WEBSOCKET_SECRET}) {
    # A weak secret only disables git sync, the CI checks keep running
    $channel = eval { SecureChannel->new(secret => $ENV{GH_WEBSOCKET_SECRET}) };
    $log->error("Git sync websocket is disabled: $@") if (!$channel);
}
else {
    $log->warn("GH_WEBSOCKET_SECRET not set, git sync websocket is disabled");
}


my $max_retry_age  = $ENV{MAX_RETRY_AGE}  || 24 * 3600;
my $probe_max_age  = $ENV{PROBE_MAX_AGE}  || 120;
my $ws_max_clients = $ENV{GH_WEBSOCKET_MAX_CLIENTS} || 50;
my $git_url        = ($ENV{GITHUB_GIT_URL} || 'https://github.com') =~ s{/+$}{}r;

my $gt = Github->new(
    private_key_file => $ENV{GITHUB_APP_KEY_FILE},
    private_key      => $ENV{GITHUB_APP_KEY},
    logger           => $log,
);
my $yt_obj = Youtrack->new(logger => $log);

# PR_BRANCH_YT_CHECK eg: 'PRODUCTION*=CLUSTER-*' - PR title against a branch
# matching the left regex must have a ticket matching the right regex
my $checker = Checker->new(youtrack => $yt_obj, logger => $log, pr_branch_check => $ENV{PR_BRANCH_YT_CHECK});

die "Failed to get github access token\n" if (!$gt->get_access_token);

# Use checks API if the token belongs to github app and DISABLE_CHECK_API env is not set
my $use_checks_api = ($gt->is_app and $gt->private_key_file and !$ENV{DISABLE_CHECK_API}) ? 1 : 0;

Store::init_schema();
Store::update_alive();

# Failed github web hook deliveries are redelivered (github app only)
my $redelivery          = Redelivery->new(github => $gt, logger => $log);
my $redelivery_interval = $ENV{REDELIVERY_INTERVAL} // 300;

my $server_start_time = time;

# ============================================================================ #
# Probe
# ============================================================================ #

get '/ghyt-ci' => sub {
    my ($c) = @_;

    my $last = eval { Store::last_alive() };
    my ($state, $age);

    if ($@) {
        $state = 'failed';
        $age   = -1;
        $log->error("Probe failed to read spooler state: $@");
    }
    elsif (!defined $last) {
        $age   = time - $server_start_time;
        $state = $age <= $probe_max_age ? 'ok' : 'not started yet';
    }
    else {
        $age   = time - $last;
        $state = $age <= $probe_max_age ? 'ok' : 'failed';
    }

    my $ok = $state eq 'ok';
    $log->info("Probe request received and responding spooler state: '$state'");

    return $c->render(
        json => {
            status              => $ok ? 'ok' : 'failed',
            msg                 => $ok ? 'Service online!' : 'Spooler is not running',
            spooler_state       => $state,
            spooler_last_update => "$age secs ago",
        },
        status => $ok ? 200 : 503,
    );
};

# ============================================================================ #
# GitHub web hook
# ============================================================================ #

my %event_handlers = (
    ping                      => \&on_ping,
    push                      => \&on_push,
    pull_request              => \&on_pull_request,
    check_run                 => \&on_check_run,
    installation              => \&on_installation,
    installation_repositories => \&on_installation,
);

post '/check_youtrack' => sub {
    my ($c) = @_;

    my $ip = $c->tx->remote_address;

    # Signature verification (X-Hub-Signature-256), always required
    my $signature = $c->req->headers->header('X-Hub-Signature-256') // '';
    my $expected  = 'sha256=' . hmac_sha256_hex($c->req->body // '', $ENV{GITHUB_SECRET});
    if (!secure_compare($signature, $expected)) {
        $log->error("Web hook signature verification failed for request from $ip");
        return $c->render(json => {status => 'failed', msg => 'Signature mismatch'}, status => 401);
    }

    my $event = $c->req->headers->header('X-GitHub-Event');
    if (!$event) {
        $log->error("Github request received without X-GitHub-Event header");
        return $c->render(json => {status => 'failed', msg => 'X-GitHub-Event header missing'}, status => 400);
    }

    my $handler = $event_handlers{$event};
    if (!$handler) {
        $log->warn("Consider disabling web hook for event type $event, only push/pull_request type is required");
        return $c->render(json => {status => 'ignored', msg => "Event $event ignored"});
    }

    # Web hooks can be configured as JSON or form encoded payload
    my $params = $c->req->json;
    if (!$params and defined(my $payload = $c->param('payload'))) {
        $params = eval { from_json($payload) };
    }

    if (ref($params) ne 'HASH') {
        $log->error("Invalid payload received for $event event");
        return $c->render(json => {status => 'failed', msg => 'Invalid payload'}, status => 400);
    }

    my ($code, $resp) = eval { $handler->($params) };
    if (!$code) {
        $log->error("Failed to handle $event event: $@");
        return $c->render(json => {status => 'failed', msg => 'Internal error'}, status => 500);
    }

    return $c->render(json => $resp, status => $code);
};

# ============================================================================ #

sub on_ping {
    my ($params) = @_;
    my $repo_name = ($params->{repository} // {})->{name};
    $log->info("---ping event received---");
    return (200, {status => 'ok', project => $repo_name, msg => 'Configuration Success!'});
}

# ============================================================================ #

sub on_push {
    my ($params) = @_;

    my ($owner, $name) = repo_owner_name($params);
    return (400, {status => 'failed', msg => 'Invalid repository details'}) if (!$name);

    my $ref   = $params->{ref} // '';
    my $after = $params->{after} // '';

    my $pushed_at = $params->{repository}{pushed_at};
    $pushed_at = undef if (!defined $pushed_at or $pushed_at !~ /^\d+$/);

    # Branch / tag deleted, nothing to check or sync
    if ($params->{deleted} or $after =~ /^0+$/) {
        if (!push_is_latest($name, $ref, $pushed_at, '')) {
            refresh_ref_later($owner, $name, $ref);
            return (200, {project => $name, ref => $ref, status => 'ok', msg => 'Older delete ignored'});
        }

        Store::delete_repo_state($name, $ref);
        $log->info("Push event for deleted ref $owner/$name/$ref");
        return (200, {project => $name, ref => $ref, status => 'ok', msg => 'Ref deleted'});
    }

    return (400, {status => 'failed', msg => 'Invalid push details'}) if (!valid_sha($after) or $ref !~ m{^refs/});

    my $count = 0;
    Store::txn(
        sub {
            foreach my $commit (@{$params->{commits} // []}) {
                next if (!valid_sha($commit->{id}));
                Store::add_commit($name, $owner, $commit->{id}, $commit->{message}, undef);
                $count++;
            }
        }
    );

    # Commits are always checked, but a late or redelivered push must never move
    # the ref back for sync clients
    if (push_is_latest($name, $ref, $pushed_at, $after)) {
        my $state = Store::update_repo_state(
            {
                project          => $name,
                ref              => $ref,
                latest_commit_id => $after,
                last_updated     => $pushed_at,
                remote_url       => clone_url($owner, $name),
            }
        );

        # Notify sync clients once the web hook response is sent
        Mojo::IOLoop->timer(0.2 => sub { broadcast_state($state) });
    }
    else {
        refresh_ref_later($owner, $name, $ref);
    }

    $log->info("Push event received for $owner/$name/$ref with $count commit(s) - added to queue");
    return (200, {project => $name, ref => $ref, status => 'ok', msg => 'Commit added for check'});
}

# ============================================================================ #

sub on_pull_request {
    my ($params) = @_;

    my ($owner, $name) = repo_owner_name($params);
    return (400, {status => 'failed', msg => 'Invalid repository details'}) if (!$name);

    my $action = $params->{action} // '';
    my $pr     = $params->{pull_request} // {};

    my $recheck = $action =~ /^(opened|reopened|synchronize|ready_for_review)$/;

    # Title or base branch changes affect the PR title check
    if ($action eq 'edited') {
        my $changes = $params->{changes} // {};
        $recheck = ($changes->{title} or $changes->{base}) ? 1 : 0;
    }

    if (!$recheck) {
        return (200, {project => $name, status => 'ignored', action => $action, msg => "Pull request ignored for action $action"});
    }

    if (!defined $pr->{number} or $pr->{number} !~ /^\d+$/) {
        return (400, {status => 'failed', msg => 'Invalid pull request details'});
    }

    queue_pull_request($owner, $name, $pr->{number}, $pr->{html_url}, ($pr->{head} // {})->{sha});

    $log->info("PR event with action $action received for $owner/$name#$pr->{number} - added to queue");
    return (200, {project => $name, status => 'ok', msg => 'Pull request commits added for check', ref => ($pr->{head} // {})->{sha}});
}

# ============================================================================ #

# Whether a push (pushed at $pushed_at, moving $ref to $sha) is newer than the
# stored state. Not sure (no push time, or not newer than the stored state with
# a different sha) means the ref is resolved from github instead.
sub push_is_latest {
    my ($project, $ref, $pushed_at, $sha) = @_;

    my $stored = Store::get_repo_state($project, $ref);
    return $pushed_at ? 1 : 0 if (!$stored);

    my $stored_at = $stored->{last_updated} // 0;
    $stored_at = str2time($stored_at) // 0 if ($stored_at !~ /^\d+$/);

    return 1 if ($pushed_at and $pushed_at > $stored_at);

    if ($stored->{latest_commit_id} ne $sha) {
        $log->info("Push for $project $ref is not newer than the known state, resolving the ref from github");
    }

    return 0;
}

# ============================================================================ #

# Resolve the current target of a ref from github, update and broadcast it
sub refresh_ref_later {
    my ($owner, $project, $ref) = @_;

    Mojo::IOLoop->timer(0.2 => sub { run_job(refresh_ref => sub { refresh_ref($owner, $project, $ref) }) });
}

sub refresh_ref {
    my ($owner, $project, $ref) = @_;

    my ($data, $res) = $gt->get_ref($owner, $project, $ref);
    my $sha = (ref($data) eq 'HASH' and ref($data->{object}) eq 'HASH') ? $data->{object}{sha} : undef;

    if (valid_sha($sha)) {
        my $stored = Store::get_repo_state($project, $ref);
        return if ($stored and $stored->{latest_commit_id} eq $sha);

        broadcast_state(
            Store::update_repo_state(
                {
                    project          => $project,
                    ref              => $ref,
                    latest_commit_id => $sha,
                    last_updated     => time,
                    remote_url       => clone_url($owner, $project),
                }
            )
        );
        return;
    }

    if ($res and $res->code == 404) {
        $log->info("Ref $owner/$project/$ref does not exist any more");
        Store::delete_repo_state($project, $ref);
        return;
    }

    $log->warn("Could not resolve $owner/$project/$ref, the next poll will correct it");
}

# ============================================================================ #

# Re-run requested from the github checks UI
sub on_check_run {
    my ($params) = @_;

    my ($owner, $name) = repo_owner_name($params);
    return (400, {status => 'failed', msg => 'Invalid repository details'}) if (!$name);

    my $action = $params->{action} // '';
    my $run    = $params->{check_run} // {};

    if ($action ne 'rerequested' or ($run->{name} // '') ne Github::CHECK_NAME) {
        return (200, {project => $name, status => 'ignored', action => $action, msg => "Check run ignored for action $action"});
    }

    my $prs = $run->{pull_requests};
    $prs = ($run->{check_suite} // {})->{pull_requests} if (ref($prs) ne 'ARRAY' or !@{$prs});

    my $queued = 0;
    foreach my $pr (@{$prs // []}) {
        next if (!defined $pr->{number} or $pr->{number} !~ /^\d+$/);

        my $base_repo = (($pr->{base} // {})->{repo} // {})->{name};
        next if ($base_repo and $base_repo ne $name);

        queue_pull_request($owner, $name, $pr->{number}, undef, $run->{head_sha});
        $queued++;
    }

    if (!$queued) {
        $log->warn("Check re-run requested for $owner/$name $run->{head_sha} without a pull request, ignored");
        return (200, {project => $name, status => 'ignored', msg => 'No pull request found for the check run'});
    }

    $log->info("Check re-run requested for $owner/$name, $queued pull request(s) added to queue");
    return (200, {project => $name, status => 'ok', msg => 'Pull request commits added for check', ref => $run->{head_sha}});
}

# ============================================================================ #

# Github app installation/update
sub on_installation {
    my ($params) = @_;

    my $action = $params->{action} // '';
    my $inst   = $params->{installation} // {};

    $log->info("Installation event received for action $action");

    if ($action !~ /^(created|new_permissions_accepted|unsuspend|added|removed)$/) {
        return (200, {status => 'ignored', msg => "Installation action $action ignored"});
    }

    if (!$gt->is_app) {
        return (200, {status => 'ignored', msg => 'Not using github app authentication'});
    }

    my $account = ($inst->{account} // {})->{login} // '';
    if (lc($account) ne lc($gt->org)) {
        $log->warn("Installation event for account '$account' ignored, only " . $gt->org . " is served");
        return (200, {status => 'ignored', msg => 'Installation account not served'});
    }

    my $configured_app_id = $gt->github_app_id // $ENV{GITHUB_APP_ID};
    if ($configured_app_id and $inst->{app_id} and $inst->{app_id} ne $configured_app_id) {
        $log->warn("Installation event for unknown app id $inst->{app_id} ignored");
        return (200, {status => 'ignored', msg => 'Unknown app id'});
    }

    my $new_gt = Github->new(
        private_key_file => $ENV{GITHUB_APP_KEY_FILE},
        private_key      => $ENV{GITHUB_APP_KEY},
        github_app_id    => $inst->{app_id} || $configured_app_id,
        access_token_url => $inst->{access_tokens_url},
        logger           => $log,
        force_update     => 1,
    );

    # Switch only when the new installation token works
    if ($new_gt->get_access_token) {
        $gt = $new_gt;
        return (200, {status => 'ok', msg => 'New access token generated'});
    }

    $log->error("Failed to create/refresh access_token, keeping the current one");
    return (500, {status => 'failed', msg => 'Failed to create/refresh access_token'});
}

# ============================================================================ #
# Git sync websocket
# ============================================================================ #

my %ws_sessions;

websocket '/githubpush' => sub {
    my ($c) = @_;

    my $ip = $c->tx->remote_address;

    if (!$channel) {
        $log->warn("Git sync connection from $ip rejected, GH_WEBSOCKET_SECRET not configured");
        return $c->render(text => 'Git sync is disabled', status => 503);
    }

    my @sessions = values %ws_sessions;
    my $pending  = grep { !$_->{authed} } @sessions;
    my $from_ip  = grep { $_->{ip} eq $ip } @sessions;

    if (@sessions >= $ws_max_clients or $pending >= 10 or $from_ip >= 5) {
        $log->error("Git sync connection from $ip rejected, too many connections");
        return $c->render(text => 'Too many connections', status => 503);
    }

    my $id      = "$c";
    my $session = {
        c         => $c,
        ip        => $ip,
        challenge => SecureChannel::new_challenge(),
        authed    => 0,
        repos     => {},
        last_sync => 0,
    };
    $ws_sessions{$id} = $session;

    # Pings keep the connection alive and drop dead peers via inactivity timeout
    $c->inactivity_timeout(300);
    $session->{ping_timer} = Mojo::IOLoop->recurring(
        60 => sub {
            $c->tx->send([1, 0, 0, 0, Mojo::WebSocket::WS_PING(), 'ping']) if ($c->tx);
        }
    );

    $session->{auth_timer} = Mojo::IOLoop->timer(
        10 => sub {
            return if ($session->{authed});
            $log->error("Git sync client $ip did not authenticate in time");
            $c->finish(4001, 'Authentication timeout');
        }
    );

    $c->on(message => sub { handle_ws_message($session, $_[1]) });

    $c->on(
        finish => sub {
            my ($ws, $code, $reason) = @_;
            Mojo::IOLoop->remove($_) for (grep {defined} @{$session}{qw(ping_timer auth_timer)});
            delete $ws_sessions{$id};
            my $msg = "Websocket connection closed from $ip, Code: " . ($code // '');
            $msg .= " Reason: $reason" if ($reason);
            $log->info($msg);
        }
    );

    $c->send({json => {type => 'challenge', version => 1, challenge => $session->{challenge}}});
};

# ============================================================================ #

sub handle_ws_message {
    my ($session, $msg) = @_;

    my $c = $session->{c};

    if (!$session->{authed}) {
        my $data = eval { from_json($msg) };

        my $repos = ref($data) eq 'HASH' ? $data->{repos} : undef;
        my $valid = (ref($data) eq 'HASH' and ($data->{type} // '') eq 'auth' and ref($repos) eq 'ARRAY'
              and !grep { !valid_name($_) } @{$repos});

        if (!$valid or !$channel->verify_auth_response($session->{challenge}, join(',', @{$repos}), $data->{response})) {
            $log->error("Git sync client $session->{ip} failed authentication");
            $c->finish(4003, 'Authentication failed');
            return;
        }

        Mojo::IOLoop->remove($session->{auth_timer});
        delete $session->{auth_timer};

        # Client id (eg: host name) identifies a client, also behind a proxy
        # where all clients share one ip
        my $client_id = $data->{client_id};
        $client_id = undef if (!defined $client_id or ref($client_id) or $client_id !~ /\A[A-Za-z0-9_.:-]{1,100}\z/);

        $session->{authed}  = 1;
        $session->{repos}   = {map { $_ => 1 } @{$repos}};
        $session->{context} = join(',', @{$repos});
        $session->{client}  = $client_id // "ip:$session->{ip}";

        # A re-connecting client replaces its own older session, so dead
        # connections (eg: dropped by a NAT) do not pile up
        foreach my $old (values %ws_sessions) {
            next if ($old == $session or !$old->{authed});
            next if ($old->{client} ne $session->{client} or $old->{context} ne $session->{context});
            $log->info("Closing previous git sync session from $old->{ip}");
            $old->{c}->finish(4000, 'Replaced by a new connection');
        }
        $log->info("Git sync client $session->{client} ($session->{ip}) authenticated for repos: " . join(', ', @{$repos}));

        $c->send({json => {type => 'ready'}});
        return;
    }

    if ($msg eq 'give-latest') {
        if ($session->{last_sync} > time - 10) {
            $log->warn("Ignoring frequent give-latest from $session->{ip}");
            return;
        }
        $session->{last_sync} = time;
        $log->info("Received give-latest from $session->{ip}");

        foreach my $state (@{Store::get_all_repo_state()}) {
            send_state($session, $state) if ($session->{repos}{$state->{project}});
        }
        return;
    }

    $log->error("Un-recognised message received from $session->{ip}");
}

# ============================================================================ #

sub broadcast_state {
    my ($state) = @_;
    foreach my $session (values %ws_sessions) {
        next if (!$session->{authed} or !$session->{repos}{$state->{project}});
        send_state($session, $state);
    }
}

# ============================================================================ #

sub send_state {
    my ($session, $state) = @_;

    return if (!valid_sha($state->{latest_commit_id}));

    my $payload = {
        type          => 'state',
        project       => $state->{project},
        ref           => $state->{ref},
        sha           => $state->{latest_commit_id},
        last_updated  => $state->{last_updated},
        updated_epoch => $state->{updated_epoch},
        remote_url    => state_clone_url($state),
        ts            => time,
    };

    # Read only token scoped to this repository, if using a github app
    my $token = $gt->get_read_only_access_token($state->{project});
    $payload->{token} = $token if ($token);

    $session->{c}->send($channel->seal(encode_json($payload)));
}

# ============================================================================ #
# Spooler
# ============================================================================ #

sub queue_pull_request {
    my ($owner, $repo, $number, $html_url, $head_sha) = @_;
    my $commits_url = $gt->api_path('repos', $owner, $repo, 'pulls', $number, 'commits');
    $html_url ||= "$git_url/$owner/$repo/pull/$number";
    return Store::add_pull_request($repo, $commits_url, $html_url, valid_sha($head_sha) ? $head_sha : undef);
}

# ============================================================================ #

# A pull request which cannot be verified fails closed on its head commit
sub fail_pull_request {
    my ($pr, $owner, $head_sha, $reason) = @_;

    $head_sha = $pr->{commit_id} if (!valid_sha($head_sha));
    $log->error("Pull request $pr->{message} could not be verified: $reason");

    if (valid_sha($head_sha)) {
        my $commit = {commit_id => $head_sha, owner => $owner, project => $pr->{project}};
        return if (!post_status($commit, 'error', 'Could not verify the PR title, please push again or re-run'));
    }

    Store::delete_pull_request($pr->{project}, $pr->{message});
}

# ============================================================================ #

# Fetch the pull request title and commits, and queue them for check together
# so the PR title check is always evaluated with its head commit
sub process_pull_requests {
    my $api = quotemeta($gt->api_url);

    foreach my $pr (@{Store::get_pull_requests()}) {
        my $commits_url = $pr->{message};
        my $project     = $pr->{project};

        my ($owner, $repo, $number) = ($commits_url =~ m{^$api/repos/([^/]+)/([^/]+)/pulls/(\d+)/commits$});

        if (!$owner or $repo ne $project) {
            $log->error("Invalid pull request commits URL $commits_url for project $project, removing");
            Store::delete_pull_request($project, $commits_url);
            next;
        }

        if (expired($pr)) {
            $log->error("Giving up on pull request $commits_url after retrying for $max_retry_age secs");
            Store::delete_pull_request($project, $commits_url);
            next;
        }

        my ($details, $res) = $gt->get_api_response($gt->api_path('repos', $owner, $repo, 'pulls', $number));
        if (ref($details) ne 'HASH') {
            if ($res and $gt->is_retryable($res)) {
                $log->info("Pull request $owner/$repo#$number will be tried again");
            }
            else {
                fail_pull_request($pr, $owner, undef, 'pull request details not available');
            }
            next;
        }

        if (($details->{state} // '') ne 'open') {
            $log->info("Pull request $owner/$repo#$number is $details->{state}, skipping check");
            Store::delete_pull_request($project, $commits_url);
            next;
        }

        my $no_delete = 0;
        my $commits   = $gt->fetch_all_commits($commits_url, \$no_delete);

        if (!$commits) {
            if ($no_delete) {
                $log->info("Pull request $owner/$repo#$number will be tried again");
            }
            else {
                fail_pull_request($pr, $owner, ($details->{head} // {})->{sha}, 'commits not available');
            }
            next;
        }

        my $head_sha = ($details->{head} // {})->{sha};
        my $base_ref = ($details->{base} // {})->{ref} // '';
        my $pr_link  = $details->{html_url} || $pr->{git_link};

        # The head commit must be checked together with the PR title, even when
        # it is not in the list (API returns max 250 commits, or pushed meanwhile)
        if (valid_sha($head_sha) and !grep { ($_->{sha} // '') eq $head_sha } @{$commits}) {
            my ($head, $head_res) = $gt->get_commit($owner, $repo, $head_sha);
            if (ref($head) ne 'HASH') {
                if ($head_res and $gt->is_retryable($head_res)) {
                    $log->info("Head commit of $owner/$repo#$number not available yet, will be tried again");
                }
                else {
                    fail_pull_request($pr, $owner, $head_sha, 'head commit not available');
                }
                next;
            }
            push(@{$commits}, $head);
        }

        Store::txn(
            sub {
                if (valid_sha($head_sha)) {
                    Store::add_commit($project, $owner, "PRT|$base_ref|$head_sha", $details->{title} // '', $pr_link);
                }
                foreach my $commit (@{$commits}) {
                    next if (!valid_sha($commit->{sha}));
                    Store::add_commit($project, $owner, $commit->{sha}, ($commit->{commit} // {})->{message}, $pr_link);
                }
                Store::delete_pull_request($project, $commits_url);
            }
        );

        $log->info("Pull request $owner/$repo#$number queued with " . scalar(@{$commits}) . " commit(s)");

        if (valid_sha($head_sha)) {
            post_status(
                {commit_id => $head_sha, owner => $owner, project => $project},
                'pending', 'Commit queued for checking Youtrack ticket'
            );
        }
    }

    return 1;
}

# ============================================================================ #

sub check_all_commits {
    my $rows = Store::get_commits();
    return if (!@{$rows});

    my (%commits, %titles, @order);

    foreach my $row (@{$rows}) {
        my $commit_id = $row->{commit_id} // '';

        if ($commit_id =~ /^PRT\|(.*)\|([0-9a-f]{40,64})$/) {
            push(@{$titles{"$row->{project}|$2"}}, {%{$row}, commit_id => $2, base_branch => $1});
            next;
        }

        if (!valid_sha($commit_id)) {
            $log->error("Removing invalid commit entry '$commit_id' for $row->{project}");
            Store::delete_commit($row->{project}, $commit_id);
            next;
        }

        my $key = "$row->{project}|$commit_id";
        if (!$commits{$key}) {
            $commits{$key} = {%{$row}};
            push(@order, $key);
        }
        elsif (!$commits{$key}{git_link} and $row->{git_link}) {
            # Prefer the entry which knows the pull request link
            $commits{$key}{git_link} = $row->{git_link};
        }
    }

    my %pr_pending;

    foreach my $key (@order) {
        my $commit = $commits{$key};
        my $titles = $titles{$key};

        # Wait while a pull request of this project is still being fetched, so a
        # head commit is never passed without its PR title check
        my $project = $commit->{project};
        $pr_pending{$project} //= Store::has_pending_pull_request($project);
        next if ($pr_pending{$project} and !expired($commit));

        if (expired($commit)) {
            $log->error("Giving up on $commit->{project} $commit->{commit_id} after retrying for $max_retry_age secs");
            post_status($commit, 'error', 'Youtrack check could not be completed, please re-run');
            finish_commit($commit, $titles);
            next;
        }

        my $result = $checker->evaluate_commit($commit, $titles);

        # YouTrack is not reachable, try again later
        return if ($result eq 'WAIT');

        if (post_status($commit, $result->{state}, $result->{desc}, $result->{link})) {
            finish_commit($commit, $titles);
            $yt_obj->add_pr_link_to_comment(@{$_}) for (@{$result->{comments}});
        }
    }

    check_stale_titles(\%titles, \%commits);

    return 1;
}

# ============================================================================ #

# PR titles whose head commit is not in the queue, eg: the pull request has
# more commits than the API returns
sub check_stale_titles {
    my ($titles, $commits) = @_;

    foreach my $key (keys %{$titles}) {
        next if ($commits->{$key});

        my $first = $titles->{$key}[0];
        next if (Store::has_pending_pull_request($first->{project}));

        my $result = $checker->evaluate_titles($titles->{$key}, {state => 'success'});
        return if ($result eq 'WAIT');

        my $done = 1;
        if ($result->{state} ne 'success') {
            $done = post_status($first, $result->{state}, $result->{desc}, $result->{link});
        }

        if ($done) {
            finish_commit($first, $titles->{$key}, 1);
            $yt_obj->add_pr_link_to_comment(@{$_}) for (@{$result->{comments}});
        }
    }
}

# ============================================================================ #

sub finish_commit {
    my ($commit, $titles, $titles_only) = @_;
    Store::delete_commit($commit->{project}, $commit->{commit_id}) if (!$titles_only);
    foreach my $title (@{$titles // []}) {
        Store::delete_commit($title->{project}, "PRT|$title->{base_branch}|$title->{commit_id}");
    }
}

# ============================================================================ #

# Returns 1 when done, 0 when the update has to be retried
sub post_status {
    my ($commit, $state, $desc, $link) = @_;

    my $data = {%{$commit}, desc => $desc};

    return $gt->post_github_status($data, $state, $link) if (!$use_checks_api);

    my $summary = 'If multiple tickets mentioned in the message, only the first ticket will be considered';
    $summary = "Youtrack: $link\n\n$summary" if ($link);

    my $status     = $state eq 'pending' ? 'in_progress' : 'completed';
    my $conclusion = $state eq 'success' ? 'success'     : 'failure';

    return $gt->post_github_check($data, $desc, $summary, $status, $conclusion, $link);
}

# ============================================================================ #
# Polling, catches up events missed while the service was down
# ============================================================================ #

my $last_polled_at = time - ($ENV{POLL_LOOKBACK} || 180);

sub poll_github {
    my $started = time;

    $log->info("Polling for latest changes from github...");

    my $repos = $gt->get_repositories();
    if (!$repos) {
        $log->error("Failed to get repositories from github, will try again");
        return;
    }

    foreach my $rep (@{$repos}) {
        next if ($rep->{archived} or !valid_name($rep->{name}));

        my $last_pushed  = str2time($rep->{pushed_at}  // '') || 0;
        my $last_updated = str2time($rep->{updated_at} // '') || 0;
        next if ($last_updated <= $last_polled_at and $last_pushed <= $last_polled_at);

        my $owner = ($rep->{owner} // {})->{login} // $gt->org;

        $log->info("Polling repo $owner/$rep->{name}");
        poll_pull_requests($owner, $rep->{name});
        refresh_branches($owner, $rep->{name});
    }

    $last_polled_at = $started - 10;
    return 1;
}

# ============================================================================ #

sub poll_pull_requests {
    my ($owner, $repo) = @_;

    my $prs = $gt->get_pull_requests($repo, $owner) or return;

    # Sorted by updated time, latest first
    foreach my $pr (@{$prs}) {
        my $pr_updated = str2time($pr->{updated_at} // $pr->{created_at} // '') || 0;
        last if ($pr_updated < $last_polled_at);

        my $head_sha = ($pr->{head} // {})->{sha};
        next if (!valid_sha($head_sha));

        my ($state, $state_epoch) = $gt->get_check_state($owner, $repo, $head_sha, $use_checks_api);

        # Re-check when not passed or when the PR changed after our last check,
        # this also covers missed synchronize / edited web hook deliveries
        if ($state ne 'success' or $state_epoch < $pr_updated) {
            $log->info("Adding PR for check from polling: $pr->{html_url}, Last state: $state");
            queue_pull_request($owner, $repo, $pr->{number}, $pr->{html_url}, $head_sha);
        }
    }
}

# ============================================================================ #

sub refresh_branches {
    my ($owner, $repo) = @_;

    $log->info("Refreshing latest commits for $owner/$repo ...");

    my $branches = $gt->get_repo_branches($repo, $owner) or return;

    foreach my $branch (@{$branches}) {
        my $sha = ($branch->{commit} // {})->{sha};
        next if (!valid_sha($sha) or !defined $branch->{name});

        broadcast_state(
            Store::update_repo_state(
                {
                    project          => $repo,
                    ref              => "refs/heads/$branch->{name}",
                    latest_commit_id => $sha,
                    last_updated     => time,
                    remote_url       => clone_url($owner, $repo),
                }
            )
        );
    }
}

# ============================================================================ #
# Helpers
# ============================================================================ #

sub valid_sha {
    my ($sha) = @_;
    return (defined $sha and $sha =~ /\A[0-9a-f]{40}(?:[0-9a-f]{24})?\z/ and $sha !~ /\A0+\z/) ? 1 : 0;
}

sub valid_name {
    my ($name) = @_;
    return (defined $name and !ref($name) and $name =~ /\A[A-Za-z0-9_.-]{1,100}\z/ and $name !~ /\A\.+\z/) ? 1 : 0;
}

sub expired {
    my ($row) = @_;
    return (time - ($row->{created_epoch} // time)) > $max_retry_age;
}

sub repo_owner_name {
    my ($params) = @_;
    my $repo  = $params->{repository} // {};
    my $owner = ($repo->{owner} // {})->{login} // ($repo->{owner} // {})->{name};
    return if (!valid_name($repo->{name}) or !valid_name($owner));
    return ($owner, $repo->{name});
}

sub clone_url {
    my ($owner, $repo) = @_;
    return "$git_url/$owner/$repo.git";
}

# Clone URL for stored state, older rows have ssh or API URLs
sub state_clone_url {
    my ($state) = @_;
    my $remote = $state->{remote_url} // '';
    my $owner;

    if ($remote =~ m{^git\@[^:]+:([^/]+)/}) {
        $owner = $1;
    }
    elsif ($remote =~ m{/repos/([^/]+)/[^/]+/}) {
        $owner = $1;
    }
    elsif ($remote =~ m{^https://[^/]+/([^/]+)/[^/]+?(?:\.git)?$}) {
        $owner = $1;
    }

    $owner = $gt->org if (!valid_name($owner));
    return clone_url($owner, $state->{project});
}

# ============================================================================ #

sub run_job {
    my ($name, $code) = @_;
    my $ok = eval { $code->(); 1 };
    $log->error("Job $name failed: $@") if (!$ok);

    # Long jobs block the loop, refresh the heartbeat once they are done
    eval { Store::update_alive() };
}

my $loop = Mojo::IOLoop->singleton;

$loop->recurring(
    10 => sub {
        run_job(pull_requests => \&process_pull_requests);
        run_job(commits       => \&check_all_commits);
    }
);

# Poll github for changes every 5 minutes
$loop->recurring(300 => sub { run_job(poll => \&poll_github) });

$loop->recurring(25 => sub { run_job(alive => \&Store::update_alive) });

if ($redelivery_interval > 0) {
    $loop->recurring($redelivery_interval => sub { run_job(redelivery => sub { $redelivery->run }) });
}

$loop->next_tick(
    sub {
        run_job(poll          => \&poll_github);
        run_job(pull_requests => \&process_pull_requests);
        run_job(commits       => \&check_all_commits);

        # Catch up deliveries which failed while the service was down
        run_job(redelivery => sub { $redelivery->run }) if ($redelivery_interval > 0);
    }
);

# ============================================================================ #

app->start();
