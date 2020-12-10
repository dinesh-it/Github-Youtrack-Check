#!/usr/bin/env perl

use Mojolicious::Lite;
use Digest::SHA qw(hmac_sha1_hex);
use Mojo::IOLoop::EventEmitter;
use Crypt::Lite;
use DBI;

$| = 1;
my $push_emitter = Mojo::IOLoop::EventEmitter->new;
my $crypt        = Crypt::Lite->new(debug => 0, encoding => 'hex8');

post '/check_youtrack' => sub {
    my ($c) = @_;

    # Signature verification
    if ($ENV{GITHUB_SECRET}) {
        my $req_hmac = $c->req->headers->header('X-Hub-Signature');
        my $hmac     = 'sha1=' . hmac_sha1_hex($c->req->body, $ENV{GITHUB_SECRET});
        if ($req_hmac ne $hmac) {
            $c->app->log->error("HMAC compare failed, sent 400", $req_hmac, $hmac);
            return $c->rendered(400);
        }
    }

    # Look only for push event
    my $req_event_type = $c->req->headers->header('X-GitHub-Event');
    if (!$req_event_type) {
        return $c->rendered(400);
    }
    elsif ($req_event_type !~ /^(push|pull_request|ping)$/) {
        $c->app->log->warn(
            "Consider disabling web hook for event type $req_event_type, only push/pull_request type is required");
        return $c->rendered(200);
    }

    my $params    = $c->req->json;
    my $repo      = $params->{repository};
    my $repo_name = $repo->{name};

    if ($req_event_type eq 'ping') {
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
        $c->render(json => { project => $repo->{name}, ref => $params->{ref}, status => 'ok', msg => 'Commit added for check'});
    }
    else {
        # Store pull request details
        my $pr_action = $params->{action};

        if ($pr_action !~ /^(opened|reopened|synchronize)$/) {
            $c->render(json => { project => $repo_name, status => 'ignored', action => $pr_action, msg => "Pull request ignored for action $pr_action" });
            return $c->rendered(200);
        }

        my $commits_url  = $params->{pull_request}->{commits_url};
        my $after_commit = $params->{after};
        add_pull_request($repo_name, $commits_url, $after_commit);
        $c->render(json => { project => $repo_name, status => 'ok', msg => 'Pull request commits added for check', ref => $params->{ref} });
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
                foreach my $s (@{$stats}) {
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
    my $ev_str =
      "$s->{project}|$s->{ref}|$s->{latest_commit_id}|$s->{last_updated}|$s->{remote_url}|$s->{updated_epoch}";
    if ($ENV{GH_WEBSOCKET_SECRET}) {
        $c->log->debug("Encrypting: $ev_str");
        $ev_str = $crypt->encrypt($ev_str, $ENV{GH_WEBSOCKET_SECRET});
    }
    $c->log->info("Sending: $ev_str");
    $c->send("$ev_str");
}

# ============================================================================ #

sub add_commit {
    my ($repo_name, $owner, $commit) = @_;
    my $dbh = get_db_conn();
    my $sql =
      qq/INSERT INTO GitPushEvent (event_type, project, owner, commit_id, message, created_epoch) VALUES(?,?,?,?,?,?)/;
    my $sth = $dbh->prepare($sql);
    return $sth->execute('push', $repo_name, $owner, $commit->{id}, $commit->{message}, time);
}

# ============================================================================ #

sub add_pull_request {
    my ($repo_name, $commits_url, $after_commit) = @_;
    my $dbh = get_db_conn();
    my $sql = qq/INSERT INTO GitPushEvent (event_type, project, commit_id, message, created_epoch) VALUES(?,?,?,?,?)/;
    my $sth = $dbh->prepare($sql);
    return $sth->execute('pull_request', $repo_name, $after_commit, $commits_url, time);
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
