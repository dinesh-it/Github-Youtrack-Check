#!/usr/bin/env perl

use Mojolicious::Lite;
use Digest::SHA qw(hmac_sha1_hex);
use Mojo::EventEmitter;
use Crypt::Lite;
use DBI;

use FindBin;
use lib $FindBin::Bin;
use GithubToken;


$| = 1;
my $push_emitter = Mojo::EventEmitter->new;
my $crypt        = Crypt::Lite->new(debug => 0, encoding => 'hex8');
my $gt           = GithubToken->new(private_key_file => $ENV{GITHUB_APP_KEY_FILE}) if($ENV{GITHUB_APP_KEY_FILE});

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

        $gt = GithubToken->new(
            private_key_file => $ENV{GITHUB_APP_KEY_FILE},
            github_app_id => $app_id,
            access_token_url => $at_url,
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
            print STDERR "ERROR: $error\n";
        }
    );

    $c->on(
        message => sub {
            my ($ws, $msg) = @_;
            my $ip = $ws->tx->remote_address;
            if ($msg eq 'give-latest') {
                $c->log->info("Received $msg from $ip");
                my $stats = get_all_repo_state();
                my $ghat = $gt->get_read_only_access_token if($gt);
                foreach my $s (@{$stats}) {
                    $s->{token} = $ghat;
                    send_stat($s, $c);
                }
            }
            else {
                $c->log->error("Un-recognised message received: $msg from $ip");
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
            $c->log->info($msg);
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
        $c->log->debug("Encrypting: $ev_str");
        $ev_str = $crypt->encrypt($ev_str, $ENV{GH_WEBSOCKET_SECRET});
    }
    $c->log->info("Sending: $ev_str");
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

sub get_db_conn {
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
            or print STDERR "Failed to insert GitRepoState record:" . $dbh->errstr;
    }
    else {
        $sql =
        qq/UPDATE GitRepoState SET latest_commit_id = ?, last_updated = ?, remote_url = ?, updated_epoch = ? WHERE project = ? AND ref = ?/;
        my $sth = $dbh->prepare($sql);
        $sth->execute($last_commit, $last_update, $remote_url, $now, $project, $ref)
            or print STDERR "Failed to update GitRepoState record:" . $dbh->errstr;
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
}

create_table_if_not_exist(get_db_conn());

# ============================================================================ #

app->start();
