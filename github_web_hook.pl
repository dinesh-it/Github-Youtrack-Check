#!/usr/bin/env perl

use Mojolicious::Lite;
use Digest::SHA qw(hmac_sha1_hex);
use DBI;

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
    elsif ($req_event_type ne 'push') {
        $c->app->log->warn("Consider disabling web hook for event type $req_event_type, only push type is required");
        return $c->rendered(200);
    }

    my $params    = $c->req->json;
    my $repo      = $params->{repository};
    my $repo_name = $repo->{name};
    my $owner     = $repo->{owner}->{name};
    my $commits   = $params->{commits};

    # Check if we have required data
    if (!$repo || !$owner || !$commits || ref $commits ne 'ARRAY') {
        my $req_code = $c->req->headers->header('X-GitHub-Delivery');
        $c->app->log->error("Required params missing for this request: $req_code", $repo_name, $owner);
        return $c->rendered(400);
    }

    # Store commit details
    foreach my $commit (@{$commits}) {
        add_commit($repo_name, $owner, $commit);
    }

    return $c->rendered(200);
};

# ============================================================================ #

sub add_commit {
    my ($repo_name, $owner, $commit) = @_;
    my $dbh = get_db_conn();
    my $sql = qq/INSERT INTO GitPushEvent (project, owner, commit_id, message, created_epoch) VALUES(?,?,?,?,?)/;
    my $sth = $dbh->prepare($sql);
    return $sth->execute($repo_name, $owner, $commit->{id}, $commit->{message}, time);
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
			project TEXT NOT NULL,
			owner TEXT NOT NULL,
			commit_id TEXT NOT NULL,
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
