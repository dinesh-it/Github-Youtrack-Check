#!/usr/bin/env perl

use strict;
use warnings;
use DBI;
use LWP::UserAgent;
use URI::Builder;
use JSON::XS;

# Check of required ENV's available
foreach my $var (qw/YOUTRACK_MATCH_KEY YOUTRACK_TOKEN YOUTRACK_HOST GITHUB_TOKEN/) {
    if (!$ENV{$var}) {
        die "$var ENV required\n";
    }
}

my $sleep_time = 0;
while (1) {
    sleep($sleep_time);
    if (!check_all_commits()) {
        $sleep_time += 1;
        $sleep_time = 10 if ($sleep_time > 10);
        next;
    }
    $sleep_time = 0;
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

sub get_commits {
    my $dbh    = get_db_conn();
    my $sql    = qq/SELECT * FROM GitPushEvent ORDER BY created_epoch asc/;
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

sub get_youtrack_id {
    my $message = shift;

    my $matchkey = $ENV{YOUTRACK_MATCH_KEY};
    if ($message =~ /$matchkey/i) {
        return uc($1);
    }

    return;
}

# ============================================================================ #

sub get_youtrack_ticket {
    my $ticket_id = shift;

    return if (!$ticket_id);
    my $yt_token = $ENV{YOUTRACK_TOKEN};
    my $yt_host  = $ENV{YOUTRACK_HOST};

    my $yt = URI::Builder->new(uri => $yt_host);

    my $ua = LWP::UserAgent->new();
    $ua->default_header('Authorization' => "Bearer $yt_token");
    $ua->default_header('Accept'        => 'application/json');
    $ua->default_header('Content-Type'  => 'application/json');

    my $ticket_fields = 'fields=numberInProject,project(shortName)';

    $yt->path_segments("youtrack", "api", "issues", $ticket_id);

    my $url = $yt->as_string . "?$ticket_fields";

    my $ticket = $ua->get($url);

    return if (!$ticket->is_success);

    $yt->path_segments('youtrack', 'issue', $ticket_id);

    return $yt->as_string;
}

# ============================================================================ #

sub github_status {
    my ($commit, $status, $link) = @_;

    my $gh_token = $ENV{GITHUB_TOKEN};

    my $ua = LWP::UserAgent->new();
    $ua->default_header('Authorization' => "Bearer $gh_token");

    my $resp_body = {
        "context"     => "ci/chk-youtrack",
        "description" => 'Commit message should have valid Youtrack ticket',
        "state"       => $status,
    };

    $resp_body->{target_url} = $link if ($link);

    my $commit_hash = $commit->{commit_id};
    my $gh_owner    = $commit->{owner};
    my $gh_repo     = $commit->{project};

    #my $gh_url = 'https://api.github.com/repos/:owner/:repo/statuses/:sha';
    my $gh = URI::Builder->new(uri => 'https://api.github.com');

    $gh->path_segments("repos", $gh_owner, $gh_repo, "statuses", $commit_hash);

    my $gh_url = $gh->as_string;

    my $req = HTTP::Request->new(POST => $gh_url);
    $req->content_type('application/json');
    $req->content(encode_json($resp_body));

    my $res = $ua->request($req);

    my $res_code = $res->code;

    if ($res->is_success) {
        delete_commit($commit_hash);
    }
    else {
        print "Error updating status for: $gh_url\n";
        print $res->decoded_content . "\n";

        # Re-try only if the request timed out
        if ($res_code != 408) {
            delete_commit($commit_hash);
            print "This status update will not be re-tried\n";
        }
    }
}

# ============================================================================ #

sub check_all_commits {
    my $commits = get_commits();
    foreach my $commit (@{$commits}) {
        my $yt_id = get_youtrack_id($commit->{message});
        if (!$yt_id) {
            github_status($commit, 'error');
            next;
        }
        my $ticket_url = get_youtrack_ticket($yt_id);
        if (!$ticket_url) {
            github_status($commit, 'error');
            next;
        }
        else {
            github_status($commit, 'success', $ticket_url);
        }
    }
}

# ============================================================================ #
