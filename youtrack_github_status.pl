#!/usr/bin/env perl

use strict;
use warnings;
use DBI;
use LWP::UserAgent;
use URI::Builder;
use JSON::XS;
use HTTP::Date;

# To make sure we get systemd logs immediately
$| = 1;

# Check of required ENV's available
foreach my $var (qw/YOUTRACK_MATCH_KEY YOUTRACK_TOKEN YOUTRACK_HOST GITHUB_TOKEN/) {
    if (!$ENV{$var}) {
        die "$var ENV required\n";
    }
}

my $verified_tickets = {};
my $sleep_time       = 5;

while (1) {
    sleep($sleep_time);
    $verified_tickets = {};
    check_all_commits();
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

    if (exists $verified_tickets->{$ticket_id}) {
        return $verified_tickets->{$ticket_id};
    }

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

    if (!$ticket->is_success) {
        my $status_code = $ticket->code;
        print STDERR "YouTrack request Error: $status_code :" . $ticket->status_line . "\n";
        die "Please check the token\n" if ($status_code == 401);

        if ($status_code == 408 || $status_code == 503 || $ticket->status_line =~ /Can't connect to/i) {

            my $retry_after = $ticket->header("Retry-After");
            if ($retry_after) {
                print STDERR "Received Retry-After header value: $retry_after\n";
                if ($retry_after =~ /^\d+$/) {
                    $sleep_time = $retry_after;
                }
                else {
                    $sleep_time = str2time($retry_after) - time;
                }
            }
            else {
                # Wait exponentially till 60 minutes
                $sleep_time = 1 if (!$sleep_time);
                $sleep_time = $sleep_time * 2;
                $sleep_time = 3600 if ($sleep_time > 3600);
            }
            print "Setting sleep time to $sleep_time seconds\n";
            return "WAIT";
        }

        $verified_tickets->{$ticket_id} = undef;
        return;
    }

    $yt->path_segments('youtrack', 'issue', $ticket_id);
    $verified_tickets->{$ticket_id} = $yt->as_string;

    return $yt->as_string;
}

# ============================================================================ #

sub github_status {
    my ($commit, $status, $link, $yt_id) = @_;

    my $gh_token = $ENV{GITHUB_TOKEN};

    my $ua = LWP::UserAgent->new();
    $ua->default_header('Authorization' => "Bearer $gh_token");

    my $status_icon = ':white_check_mark: ';
    my $desc = 'Commit message mentions a valid Youtrack ticket';
    if ($status eq 'error') {
        $desc = 'No valid YouTrack ticket - Commit message does not mention a valid Youtrack ticket';
        $status_icon = ':x: ';
    }
    elsif ($status eq 'pending') {
        $desc = "Waiting for youtrack - Commit message mentions a ticket";
        $status_icon = ':warning: ';
    }

    if ($yt_id) {
        $desc = $yt_id . ' - ' . $desc;
    }

    $desc = $status_icon . $desc;

    my $resp_body = {
        "context"     => "ci/chk-youtrack",
        "description" => $desc,
        "state"       => $status,
    };

    if ($link) {
        $resp_body->{target_url} = $link;
    }

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
        delete_commit($commit_hash) if ($status ne 'pending');
    }
    else {
        print STDERR "Error updating status for: $gh_url\n";
        print STDERR $res->decoded_content . "\n";

        # Re-try only if the request timed out or internet issue
        if ($res_code != 408 and $res->status_line !~ /Can't connect to/i) {
            delete_commit($commit_hash);
            print "This status update will not be re-tried\n";
        }
    }
}

# ============================================================================ #

sub check_all_commits {
    my $commits = get_commits();

    if (!@{$commits}) {
        $sleep_time++;
        $sleep_time = 10 if ($sleep_time > 10);
        return;
    }

    foreach my $commit (@{$commits}) {
        my $yt_id = get_youtrack_id($commit->{message});
        if (!$yt_id) {
            print STDERR "Message: \"$commit->{message}\" does not have a matching youtrack Id\n";
            github_status($commit, 'error');
            next;
        }
        my $ticket_url = get_youtrack_ticket($yt_id);

        if (!$ticket_url) {
            print STDERR "Valid YouTrack ticket not found with Id: $yt_id\n";
            github_status($commit, 'error');
            next;
        }
        elsif ($ticket_url eq 'WAIT') {
            github_status($commit, 'pending', $ticket_url, $yt_id);

            # YouTrack not available or network issue, sleep and try again later
            return;
        }
        else {
            github_status($commit, 'success', $ticket_url, $yt_id);
        }
    }

    $sleep_time = 0;
}

# ============================================================================ #
