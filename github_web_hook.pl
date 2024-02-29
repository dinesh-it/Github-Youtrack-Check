#!/usr/bin/env perl

use Mojolicious::Lite;
use Digest::SHA qw(hmac_sha1_hex);
use Mojo::EventEmitter;
use Crypt::Lite;
use DBI;

use HTTP::Date;
use Mojo::IOLoop;
use DateTime;

use FindBin;
use lib $FindBin::Bin;
use Github;
use Youtrack;

my $log = app->log;

$| = 1;
# Check of required ENV's available
if (!$ENV{GITHUB_TOKEN} and !$ENV{GITHUB_APP_KEY_FILE} and !$ENV{GITHUB_APP_KEY}) {
    die "GITHUB_TOKEN or GITHUB_APP_KEY_FILE or GITHUB_APP_KEY ENV required\n";
}

# Check if required youtrack API ENV's available
foreach my $var (qw/YOUTRACK_TOKEN YOUTRACK_HOST/) {
    if (!$ENV{$var}) {
        die "$var ENV required\n";
    }
}

my $push_emitter = Mojo::EventEmitter->new;
my $crypt        = Crypt::Lite->new(debug => 0, encoding => 'hex8');
my $gt           = Github->new(private_key_file => $ENV{GITHUB_APP_KEY_FILE}, logger => $log, private_key => $ENV{GITHUB_APP_KEY});
my $yt_obj       = Youtrack->new(logger => $log);

if(!$gt->get_access_token) {
    die "Failed to get github app access token\n";
}

my $server_start_time = time;

# Option to specify the seconds before to check for
# If the service is down for an hour we can run this script with 3600
# seconds
# Otherwise Pool for changes from last 3 minutes
my $last_pooled_at = time - 180;

# For probe testing to check service is online
get '/ghyt-ci' => sub {
    my ($c) = @_;

    my $ret_code = 200;

    # Check spooler status
    my $dbh    = get_db_conn();
    my $select = qq/SELECT * FROM SpoolerState WHERE name = 'spooler' LIMIT 1/;
    my $result = $dbh->selectall_arrayref($select, {Slice => {}});

    my $spooler_state = 'failed';
    my $last_spool_update = time - $server_start_time;
    if (!$result or !@{$result}) {
        $spooler_state = "not started yet";
    }
    else {
        $last_spool_update = time - $result->[0]{updated_epoch};
    }

    $spooler_state = 'ok' if($last_spool_update < 30);
    $ret_code = '503' if(!$spooler_state eq 'ok');

    $c->render(json => {
            status => 'ok',
            msg => 'Service online!',
            spooler_state => $spooler_state,
            spooler_last_update => "$last_spool_update secs ago",
        });
    $c->app->log->info("Probe request received and responding spooler state: '$spooler_state'");
    return $c->rendered($ret_code);
};

post '/check_youtrack' => sub {
    my ($c) = @_;

    # Signature verification
    if ($ENV{GITHUB_SECRET}) {
        my $req_hmac = $c->req->headers->header('X-Hub-Signature');
        my $hmac     = 'sha1=' . hmac_sha1_hex($c->req->body, $ENV{GITHUB_SECRET});
        if ($req_hmac ne $hmac) {
            $c->render(json => { status => 'failed', msg => 'Signature mismatch' });
            $c->app->log->error("HMAC compare failed, sent 400", $req_hmac, $hmac);
            return $c->rendered(400);
        }
    }

    # Look only for push event
    my $req_event_type = $c->req->headers->header('X-GitHub-Event');
    if (!$req_event_type) {
        $c->app->log->error("Github request received without X-GitHub-Event header");
        return $c->rendered(400);
    }
    elsif ($req_event_type !~ /^(push|pull_request|ping|installation|check_run|installation_repositories)$/) {
        $c->app->log->warn(
            "Consider disabling web hook for event type $req_event_type, only push/pull_request type is required");
        return $c->rendered(200);
    }

    my $params = $c->req->json;

    # Github app installation/update
    if($req_event_type eq 'installation' || $req_event_type eq 'installation_repositories') {

        $c->app->log->info("installation event received for action $params->{action}");

        if(!$ENV{GITHUB_APP_KEY_FILE}) {
            $c->app->log->error("Please set GITHUB_APP_KEY_FILE env");
            $c->render(json => { status => 'failed', msg => 'Server configuration error' });
            return $c->rendered(500);
        }

        my $app_id = $params->{installation}->{app_id};
        my $at_url = $params->{installation}->{access_tokens_url};

        $gt = Github->new(
            private_key_file => $ENV{GITHUB_APP_KEY_FILE},
            github_app_id => $app_id,
            access_token_url => $at_url,
            logger => $log,
            force_update => 1,
        );

        if($gt->get_access_token) {
            $c->render(json => { status => 'ok', msg => 'New access token generated' });
            return $c->rendered(200);
        }

        $c->app->log->error("Failed to create/refresh access_token");
        $c->render(json => { status => 'failed', msg => 'Failed to create/refresh access_token' });
        return $c->rendered(500);
    }

    my $repo      = $params->{repository};
    my $repo_name = $repo->{name};

    if ($req_event_type eq 'ping') {
        $c->app->log->info("---ping event received---");
        $c->render(json => { status => 'ok', project => $repo_name, msg => 'Configuration Success!' });
    }
    elsif ($req_event_type eq 'push') {

        # Store commit details
        my $owner   = $repo->{owner}->{name};
        my $commits = $params->{commits};
        foreach my $commit (@{$commits}) {
            add_commit($repo_name, $owner, $commit);
        }

        # Store this state and publish push event on socket
        my $data = {
            project          => $repo->{name},
            ref              => $params->{ref},
            latest_commit_id => $params->{after},
            last_updated     => $repo->{pushed_at},
            remote_url       => $repo->{ssh_url},
        };
        $push_emitter->emit($req_event_type => update_repo_state($data));
        $c->app->log->info("Push event received for $owner/$data->{project}/$data->{ref} - added to queue");
        $c->render(json => { project => $repo->{name}, ref => $params->{ref}, status => 'ok', msg => 'Commit added for check'});
    }
    else {
        # Store pull request details
        my $pr_action = $params->{action};

        if ($pr_action !~ /^(opened|reopened|synchronize|rerequested|edited)$/) {
            $c->render(json => { project => $repo_name, status => 'ignored', action => $pr_action, msg => "Pull request ignored for action $pr_action" });
            return $c->rendered(200);
        }

        # Hack to add back the PR for check again when user click re-run on the check result
        if($pr_action eq 'rerequested') {

            my $owner = $repo->{owner}->{name} || $repo->{owner}->{login};
            my $pr_num = $params->{check_run}->{check_suite}->{pull_requests}->[0]->{number};

            $params->{pull_request}->{commits_url} = "https://api.github.com/repos/$owner/$repo_name/pulls/$pr_num/commits";
            $params->{pull_request}->{html_url} = $params->{check_run}->{check_suite}->{pull_requests}->[0]->{url};

            $params->{after} = $params->{check_run}->{check_suite}->{after};
            $params->{pull_request}->{head}->{sha} = $params->{check_run}->{head_sha};
        }

        my $commits_url  = $params->{pull_request}->{commits_url};
        my $pr_url       = $params->{pull_request}->{html_url};
        my $pr_title     = $params->{pull_request}->{title};
        my $head_commit  = $params->{pull_request}->{head}->{sha};
        my $after_commit = $params->{after};
        add_pull_request($repo_name, $commits_url, $after_commit, $pr_url);

        if($pr_title) {
            my $owner = $repo->{owner}->{name} || $repo->{owner}->{login};
            my $base_ref = $params->{pull_request}->{base}->{ref};
            add_commit($repo_name, $owner, { message => $pr_title, id => "PRT|$base_ref|" . $head_commit }, $pr_url);
        }

        $c->app->log->info("PR event with action $pr_action received for $pr_url - added to queue");
        $c->render(json => { project => $repo_name, status => 'ok', msg => 'Pull request commits added for check', ref => $head_commit });
    }

    return $c->rendered(200);
};

# ============================================================================ #

websocket '/githubpush' => sub {
    my ($c) = shift;
    Mojo::IOLoop->stream($c->tx->connection)->timeout(0);

    # Subscribe to events
    my $cb_push = $push_emitter->on(
        push => sub {
            my ($pm, $s) = @_;
            my $ghat = $gt->get_read_only_access_token if($gt);
            $s->{token} = $ghat;
            send_stat($s, $c);
        }
    );

    my $cb_error = $push_emitter->on(
        error => sub {
            my ($pm, $error) = @_;
            $log->error($error);
        }
    );

    $c->on(
        message => sub {
            my ($ws, $msg) = @_;
            my $ip = $ws->tx->remote_address;
            if ($msg eq 'give-latest') {
                $log->info("Received $msg from $ip");
                my $stats = get_all_repo_state();
                my $ghat = $gt->get_read_only_access_token if($gt);
                foreach my $s (@{$stats}) {
                    $s->{token} = $ghat;
                    send_stat($s, $c);
                }
            }
            else {
                $log->error("Un-recognised message received: $msg from $ip");
            }
        }
    );

    $c->on(
        finish => sub {
            my ($ws, $code, $reason) = @_;
            my $ip  = $ws->tx->remote_address;
            my $msg = "websocket connection closed from $ip ,Code: $code";
            $msg .= ' Reason: $reason' if ($reason);
            $push_emitter->unsubscribe('push'  => $cb_push);
            $push_emitter->unsubscribe('error' => $cb_error);
            $log->info($msg);
        }
    );
};

# ============================================================================ #

# Send the stat in websocket
sub send_stat {
    my ($s, $c) = @_;

    my $git_url = $s->{remote_url};
    if($s->{token}) {
        # Send remote URL with access_token
        $git_url =~ s/^git\@github.com://;
        my $r = 'https://x-access-token:' . $s->{token} . '@github.com';
        $git_url = "$r/$git_url";
    }

    my $ev_str =
      "$s->{project}|$s->{ref}|$s->{latest_commit_id}|$s->{last_updated}|$git_url|$s->{updated_epoch}";
    if ($ENV{GH_WEBSOCKET_SECRET}) {
        $log->debug("Encrypting: $ev_str");
        $ev_str = $crypt->encrypt($ev_str, $ENV{GH_WEBSOCKET_SECRET});
    }
    $log->info("Sending: $ev_str");
    $c->send("$ev_str");
}

# ============================================================================ #

sub add_commit {
    my ($repo_name, $owner, $commit, $pr_url) = @_;
    my $dbh = get_db_conn();
    my $sql =
      qq/INSERT INTO GitPushEvent (event_type, project, owner, commit_id, message, git_link, created_epoch) VALUES(?,?,?,?,?,?,?)/;
    my $sth = $dbh->prepare($sql);
    return $sth->execute('push', $repo_name, $owner, $commit->{id}, $commit->{message}, $pr_url, time);
}

# ============================================================================ #

sub add_pull_request {
    my ($repo_name, $commits_url, $after_commit, $pr_url) = @_;
    my $dbh = get_db_conn();
    my $sql = qq/INSERT INTO GitPushEvent (event_type, project, commit_id, message, git_link, created_epoch) VALUES(?,?,?,?,?,?)/;
    my $sth = $dbh->prepare($sql);
    return $sth->execute('pull_request', $repo_name, $after_commit, $commits_url, $pr_url, time);
}

# ============================================================================ #

sub delete_pull_request {
    my ($project, $message) = @_;
    my $dbh = get_db_conn();
    my $sql = qq/DELETE FROM GitPushEvent WHERE event_type = 'pull_request' AND project = ? AND message = ?/;
    $dbh->do($sql, undef, $project, $message);
}

# ============================================================================ #

sub add_commits {
    my ($data, $project, $owner, $pr_link) = @_;
    my $dbh = get_db_conn();
    my $sql =
      qq/INSERT INTO GitPushEvent (event_type, project, owner, commit_id, message, git_link, created_epoch) VALUES(?,?,?,?,?,?,?)/;
    my $sth   = $dbh->prepare($sql);
    my $count = 0;

    foreach my $commit (@{$data}) {
        $count += $sth->execute('push', $project, $owner, $commit->{id}, $commit->{message}, $pr_link, time);
        post_github_status({
            commit_id => $commit->{id},
            desc => "Commit queued for checking Youtrack ticket",
            owner => $owner,
            project => $project,
        }, 'pending');
    }

    if ($count != @{$data}) {
        return 0;
    }

    return 1;
}

# ============================================================================ #

sub get_commits {
    my $dbh    = get_db_conn();
    my $sql    = qq/SELECT * FROM GitPushEvent WHERE event_type = 'push' ORDER BY created_epoch asc/;
    my $result = $dbh->selectall_arrayref($sql, {Slice => {}});
    return $result;
}

# ============================================================================ #

sub delete_commit {
    my $commit_id = shift;
    my $dbh       = get_db_conn();
    my $sql       = qq/DELETE FROM GitPushEvent WHERE commit_id = ?/;
    $dbh->do($sql, undef, $commit_id);
}

# ============================================================================ #

my $global_dbh;
sub get_db_conn {
    return $global_dbh if($global_dbh);
    my $driver   = "SQLite";
    my $database = $ENV{GITHUB_WEB_HOOK_DB} ||= "/tmp/github_web_hook.db";
    my $userid   = $ENV{GITHUB_WEB_HOOK_DB_USER} //= "";
    my $password = $ENV{GITHUB_WEB_HOOK_DB_PWD} //= "";
    my $dsn      = "DBI:$driver:dbname=$database";
    my $dbh      = DBI->connect($dsn, $userid, $password, {RaiseError => 1}) or die $DBI::errstr;
    return $dbh;
}

# ============================================================================ #

sub get_all_repo_state {
    my $dbh    = get_db_conn();
    my $select = qq/SELECT * FROM GitRepoState/;
    my $result = $dbh->selectall_arrayref($select, {Slice => {}});

    if (!$result or !@{$result}) {
        return [];
    }

    return $result;
}

# ============================================================================ #

sub update_repo_state {
    my ($data) = @_;

    my $dbh = get_db_conn();

    my ($project, $ref, $last_commit, $last_update, $remote_url) =
      ($data->{project}, $data->{ref}, $data->{latest_commit_id}, $data->{last_updated}, $data->{remote_url});

    my $now = time;

    my $select = qq/SELECT * FROM GitRepoState WHERE project = ? AND ref = ?/;
    my $result = $dbh->selectall_arrayref($select, {Slice => {}}, $project, $ref);

    my $sql;
    if (!$result or !@{$result}) {
        $sql =
qq/INSERT INTO GitRepoState (project, ref, latest_commit_id, last_updated, remote_url, updated_epoch) VALUES(?,?,?,?,?,?)/;
        my $sth = $dbh->prepare($sql);
        $sth->execute($project, $ref, $last_commit, $last_update, $remote_url, $now)
          or $log->error("Failed to insert GitRepoState record:" . $dbh->errstr);
    }
    else {
        $sql =
qq/UPDATE GitRepoState SET latest_commit_id = ?, last_updated = ?, remote_url = ?, updated_epoch = ? WHERE project = ? AND ref = ?/;
        my $sth = $dbh->prepare($sql);
        $sth->execute($last_commit, $last_update, $remote_url, $now, $project, $ref)
          or $log->error("Failed to update GitRepoState record:" . $dbh->errstr);
    }

    $data->{updated_epoch} = $now;
    return $data;
}

# ============================================================================ #

sub create_table_if_not_exist {
    my $dbh  = shift;
    my $stmt = qq/CREATE TABLE IF NOT EXISTS GitPushEvent (
    event_type TEXT NOT NULL,
    project TEXT NOT NULL,
    owner TEXT NULL,
    commit_id TEXT NULL,
    message TEXT NOT NULL,
    git_link TEXT NULL,
    created_epoch INTEGER NOT NULL
    )/;

    my $rv = $dbh->do($stmt);
    if ($rv < 0) {
        die $DBI::errstr;
    }

    $stmt = qq/CREATE TABLE IF NOT EXISTS GitRepoState (
    project TEXT NOT NULL,
    ref TEXT NOT NULL,
    latest_commit_id TEXT NOT NULL,
    last_updated INTEGER NOT NULL,
    remote_url TEXT NOT NULL,
    updated_epoch INTEGER NOT NULL
    )/;

    $rv = $dbh->do($stmt);
    if ($rv < 0) {
        die $DBI::errstr;
    }

    $stmt = qq/
    CREATE TABLE IF NOT EXISTS SpoolerState (name TEXT PRIMARY KEY, updated_epoch INTEGER NOT NULL);
    /;

    $rv = $dbh->do($stmt);
    if ($rv < 0) {
        die $DBI::errstr;
    }

    chmod 777, $ENV{GITHUB_WEB_HOOK_DB};
}

# ============================================================================ #
# ============================================================================ #
# ============================================================================ #

sub check_db_pull_requests {
    my $dbh    = get_db_conn();
    my $sql    = qq/SELECT * FROM GitPushEvent WHERE event_type = 'pull_request' ORDER BY created_epoch asc/;
    my $result = $dbh->selectall_arrayref($sql, {Slice => {}});
    if (!$result or !@{$result}) {
        return 0;
    }

    foreach my $pr (@{$result}) {
        my $commits_url = $pr->{message};
        my $project     = $pr->{project};
        my $pr_link     = $pr->{git_link};

        my @url = split('/', $commits_url);

        if ($project ne $url[5]) {
            $log->error("Project name not matched in the URL, something wen't wrong");
            $log->error("Project: $project is not $url[6], URL: $commits_url");
            delete_pull_request($project, $commits_url);
            next;
        }

        my $owner = $url[4];

        my $no_delete = 0;
        my $commits   = $gt->fetch_all_commits($commits_url, \$no_delete);

        if (!$commits) {
            if (!$no_delete) {
                delete_pull_request($project, $commits_url);
            }
            else {
                $log->info("This request will be tried again");

                # Wait for sometime since no_delete will be set only for timeout or internet issue
                sleep 10;
            }
            next;
        }

        my $table_data = get_commits_data($commits);

        if (add_commits($table_data, $project, $owner, $pr_link)) {
            delete_pull_request($project, $commits_url);
        }
    }

    return 1;
}

# ============================================================================ #

sub get_commits_data {
    my ($commits, $after_commit) = @_;

    my @commits_data;
    my $start_after = 0;
    my $i           = 0;
    foreach my $commit (@{$commits}) {

        if ($after_commit and $after_commit eq $commit->{sha}) {
            $start_after = $i;
        }

        push(@commits_data, {id => $commit->{sha}, message => $commit->{commit}->{message}});
        $i++;
    }

    if ($start_after) {
        @commits_data = splice(@commits_data, $start_after);
    }

    return \@commits_data;
}

# ============================================================================ #

sub pool_gh_pending_prs {
    $log->info("Pooling for latest changes from github...");
    my $res_json = $gt->get_repositories();

    foreach my $rep (@{$res_json}) {
        my $last_pushed = str2time($rep->{pushed_at});
        my $last_updated = str2time($rep->{updated_at});
        if($last_updated > $last_pooled_at || $last_pushed > $last_pooled_at) {
            $log->info("Pooling for repo $rep->{name}");
            add_pending_prs($rep->{name});
        }
    }

    $last_pooled_at = time - 10;
}

# ============================================================================ #

sub add_pending_prs {
    my $repo = shift;
    my $res_json = $gt->get_pull_requests($repo);

    foreach my $pr (@{$res_json}) {

        my $last_updated = str2time($pr->{updated_at});
        if($last_updated < $last_pooled_at) {
            next;
        }

        my $pr_last_updated;
        if($pr->{updated_at}) {
            $pr_last_updated = str2time($pr->{updated_at});
        }
        else {
            $pr_last_updated = str2time($pr->{created_at});
        }

        my $status_url = $pr->{statuses_url};
        my $statuses_json = $gt->get_api_response($status_url);

        my $status_last_updated = 0;
        my $status = '';
        foreach my $st (@{$statuses_json}) {
            if($st->{context} eq 'ci/chk-youtrack') {
                $status_last_updated = str2time($st->{updated_at});
                $status = $st->{state};
                last;
            }
        }

        if($status ne 'success' and $status_last_updated < $pr_last_updated) {
            $log->info("Adding PR for check from pooling method: $pr->{url}, Last state: $status");
            add_pull_request($repo, $pr->{commits_url}, $pr->{html_url});
        }
    }

    add_pending_commits($repo);
}

# ============================================================================ #

sub add_pending_commits {
    my $repo = shift;

    $log->info("Refreshing latest commits for $repo ...");

    my $res_json = $gt->get_repo_branches($repo);

    foreach my $branch (@{$res_json}) {

        my $name = $branch->{name};
        my $ref = "refs/heads/$name";
        my $sha = $branch->{commit}{sha};
        my $url = $branch->{commit}{url};
        #print "Updating commit status: $ref,$sha\n";

        update_repo_state({
                project => $repo,
                ref => $ref,
                latest_commit_id => $sha,
                last_updated => DateTime->now,
                remote_url => $url,
            });
    }
}

# ============================================================================ #

sub post_github_status {
    my ($commit, $status, $link, $yt_id) = @_;

    my $commit_hash = $commit->{commit_id};
    return if($commit_hash eq 'NONE');

    # Use checks API if the token belongs to github app
    # and DISABLE_CHECK_API env is not set
    my $api_success;
    if($gt->private_key_file and !$ENV{DISABLE_CHECK_API}) {
        $api_success = post_github_check(@_);
    }
    else {
        $api_success = $gt->post_github_status(@_);
    }

    if($api_success and $status ne 'pending') {
        delete_commit($commit_hash);
    }
}

# ============================================================================ #

sub check_all_commits {
    my $commits = get_commits();

    if (!@{$commits}) {
        return;
    }

    my %commit_hash;
    my %pr_hash;
    foreach my $commit (@{$commits}) {
        if ($commit->{commit_id} =~ /^PRT\|/) {
            my (undef, $base_branch, $id) = split('\|', $commit->{commit_id});
            $commit->{commit_id} = $id;
            $commit->{base_branch} = $base_branch;
            $pr_hash{$id} = $commit;
        }
        else {
            $commit_hash{$commit->{commit_id}} = $commit;
        }
    }

	# Process and delete stale PR title entries
	# It does not push status to github but adds comments
	# in youtrack if needed
    if(!%commit_hash and %pr_hash) {
        foreach my $cid (keys %pr_hash) {
            my $h = {};
            check_pr_title($cid, \%pr_hash, $h);
        }
    }

    if(!%commit_hash){
        return;
    }

    foreach my $cid (keys %commit_hash) {
        my $commit = $commit_hash{$cid};

        my $yt_id = $yt_obj->get_ticket_id($commit->{message});

        my $pr_link = $commit->{git_link};
        if (!$yt_id) {

            if($commit->{message} =~ /^Merge /) {
                $log->error("Message: \"$commit->{message}\" - check skipped");
                $commit->{desc} = 'Check skipped for merge commit';
                post_github_status($commit, 'success');
                next;
            }
            $log->error("Message: \"$commit->{message}\" does not have a matching youtrack Id");
            $commit->{desc} = 'Youtrack ticket not mentioned in the commit message';
            post_github_status($commit, 'error');
            next;
        }

        #$commit->{desc} = "Checking youtrack for issue id $yt_id";
        #post_github_status($commit, 'pending', undef, $yt_id);
        my $ticket = $yt_obj->get_ticket($yt_id);

        if (!$ticket) {
            $commit->{desc} = "Unable to find youtrack issue id $yt_id, Please verify!";
            $log->error("Valid YouTrack ticket not found with Id: $yt_id");
            post_github_status($commit, 'error');
            next;
        }

        my $ticket_url = $ticket->{Link};
        if ($ticket_url eq 'WAIT') {
            # YouTrack not available or network issue, sleep and try again later
            return;
        }

        $commit->{desc} = $yt_id . ': ' .$ticket->{summary};
        my $st = check_pr_title($cid, \%pr_hash, $commit);

        return if(!$st);

        post_github_status($commit, $st, $ticket_url, $yt_id);
        $yt_obj->add_pr_link_to_comment($yt_id, $pr_link);
    }
}

# ============================================================================ #

sub check_pr_title {
    my ($cid, $pr_hash, $head_commit) = @_;

    return 'success' if(!exists $pr_hash->{$cid});

    my $commit = $pr_hash->{$cid};
    my $commit_hash = "PRT|$commit->{base_branch}|$cid";

    my $yt_id = $yt_obj->get_ticket_id($commit->{message});

    my $pr_link = $commit->{git_link};
    if (!$yt_id) {
        $log->error("PR Title: \"$commit->{message}\" does not have a youtrack Id");
        $head_commit->{desc} = 'Youtrack ticket not mentioned in the PR title';
        delete_commit($commit_hash);
        return 'error';
    }

    my $br_check = $ENV{PR_BRANCH_YT_CHECK};
    if($br_check) {
        my ($bb_reg, $yt_reg) = split('=', $br_check);

        if($commit->{base_branch} =~ /$bb_reg/i and $yt_id !~ /$yt_reg/i) {
            $log->error("PR Title: \"$commit->{message}\" does not have a $yt_reg youtrack Id");
            $head_commit->{desc} = "PR title should have $yt_reg ticket for $bb_reg branch";
            delete_commit($commit_hash);
            return 'error';
        }
    }

    my $ticket = $yt_obj->get_ticket($yt_id);

    if (!$ticket) {
        $head_commit->{desc} = "Unable to find youtrack issue id $yt_id, Please verify!";
        $log->error("Valid YouTrack ticket not found with Id: $yt_id");
        delete_commit($commit_hash);
        return 'error';
    }

    my $ticket_url = $ticket->{Link};

    return if($ticket_url eq 'WAIT');

    $head_commit->{desc} = $yt_id . ': ' .$ticket->{summary};

    $yt_obj->add_pr_link_to_comment($yt_id, $pr_link);
    delete_commit($commit_hash);

    return 'success';
}

# ============================================================================ #

sub post_github_check {
    my ($commit, $result, $link, $yt_id) = @_;

    my $title = $commit->{desc};
    my $desc = 'If you think there is something went wrong with this check, ';
    $desc .= 'Please re-run this check or contact admin if the issue persist';
    my $status = 'completed';
    my $conclusion = 'success';

    if($status eq 'completed') {
        $desc = 'If multiple tickets mentioned in the message, only the first ticket will be considered';
    }

    if($link) {
        $desc = "Youtrack: $link\n\n" . $desc;
    }

    if ($result eq 'error') {
        $conclusion = 'failure';
    }
    elsif ($result eq 'pending') {
        $status = 'in_progress';
    }

    return $gt->post_github_check($commit, $title, $desc, $status, $conclusion, $link);
}

# ============================================================================ #

sub update_alive {
    my ($self) = @_; 
    my $dbh = get_db_conn();

    my $time = time;
    my $sql = qq/INSERT INTO SpoolerState(name, updated_epoch) VALUES('spooler', $time) ON CONFLICT(name) DO UPDATE SET updated_epoch=$time/;
    my $sth = $dbh->prepare($sql);
    $sth->execute();
    return 1;
}

# ============================================================================ #

my $event_loop = Mojo::IOLoop->singleton;

# Pool github for changes every 5 minutes
$event_loop->recurring(300 => sub {
        pool_gh_pending_prs();
    });

$event_loop->recurring( 10 => sub {
        my $loop = shift;
        $loop->next_tick(sub { check_all_commits(); });
        check_db_pull_requests();
    });

$event_loop->recurring( 15 => sub {
        check_all_commits();
    });

$event_loop->recurring( 25 => sub {
        update_alive();
    });

$push_emitter->on('init' => sub {
        pool_gh_pending_prs();
        check_db_pull_requests();
        check_all_commits();
    });

create_table_if_not_exist(get_db_conn());

$push_emitter->emit('init');

# ============================================================================ #

app->start();
