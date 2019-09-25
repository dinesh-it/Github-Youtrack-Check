#!/usr/bin/env perl

use Mojolicious::Lite;
use Digest::SHA qw(hmac_sha1_hex);
use DBI;

$| = 1;

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
    elsif ($req_event_type ne 'push' && $req_event_type ne 'pull_request') {
        $c->app->log->warn(
            "Consider disabling web hook for event type $req_event_type, only push/pull_request type is required");
        return $c->rendered(200);
    }

    my $params    = $c->req->json;
    my $repo      = $params->{repository};
    my $repo_name = $repo->{name};

    if ($req_event_type eq 'push') {

        # Store commit details
        my $owner   = $repo->{owner}->{name};
        my $commits = $params->{commits};
        foreach my $commit (@{$commits}) {
            add_commit($repo_name, $owner, $commit);
        }
    }
    else {
        # Store pull request details
        my $pr_action = $params->{action};

        if ($pr_action !~ /^(opened|reopened|synchronize)$/) {
            return $c->rendered(200);
        }

        my $commits_url  = $params->{pull_request}->{commits_url};
        my $after_commit = $params->{after};
        add_pull_request($repo_name, $commits_url, $after_commit);
    }

    return $c->rendered(200);
};

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
}
create_table_if_not_exist(get_db_conn());

# ============================================================================ #

app->start();
