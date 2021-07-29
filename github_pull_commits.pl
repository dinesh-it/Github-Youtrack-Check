#!/usr/bin/env perl

use strict;
use warnings;
use DBI;
use LWP::UserAgent;
use URI::Builder;
use JSON::XS;
use Data::Dumper;
use HTTP::Date;
use Mojo::IOLoop;

use FindBin;
use lib $FindBin::Bin;
use GithubToken;

# To make sure we get systemd logs immediately
$| = 1;

# Check of required ENV's available
if (!$ENV{GITHUB_TOKEN} and !$ENV{GITHUB_APP_KEY_FILE}) {
    die "GITHUB_TOKEN or GITHUB_APP_KEY_FILE ENV required\n";
}

my $gt;
if($ENV{GITHUB_APP_KEY_FILE}) {
    $gt = GithubToken->new(
        private_key_file => $ENV{GITHUB_APP_KEY_FILE},
    );

    if(!$gt->get_access_token) {
        die "Failed to get github app access token\n";
    }
    print "Using github app access token for github API\n";
}

# Pool for changes from last 3 minutes
our $last_pooled_at = time - 180;

# ============================================================================ #

my $global_dbh;
sub get_db_conn {
    return $global_dbh if($global_dbh);
    my $driver   = "SQLite";
    my $database = $ENV{GITHUB_WEB_HOOK_DB} ||= "/tmp/github_web_hook.db";
    my $userid   = $ENV{GITHUB_WEB_HOOK_DB_USER} //= "";
    my $password = $ENV{GITHUB_WEB_HOOK_DB_PWD} //= "";
    my $dsn      = "DBI:$driver:dbname=$database";
    $global_dbh  = DBI->connect($dsn, $userid, $password, {RaiseError => 1}) or die $DBI::errstr;
    return $global_dbh;
}

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
            print "Project name not matched in the URL, something wen't wrong\n";
            print "Project: $project is not $url[6], URL: $commits_url\n";
            delete_pull_request($project, $commits_url);
            next;
        }

        my $owner = $url[4];

        my $no_delete = 0;
        my $commits   = fetch_all_commits($commits_url, \$no_delete);

        if (!$commits) {
            if (!$no_delete) {
                delete_pull_request($project, $commits_url);
            }
            else {
                print "This request will be tried again\n";

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
    }

    if ($count != @{$data}) {
        return 0;
    }

    return 1;
}

# ============================================================================ #

sub fetch_all_commits {
    my ($page_url, $no_delete) = @_;

    my $gh_token = $gt ? $gt->get_access_token : $ENV{GITHUB_TOKEN};

    my $ua = LWP::UserAgent->new();
    $ua->default_header('Authorization' => "Bearer $gh_token");

    my @all_commits;
    while ($page_url) {

        my $gh = URI::Builder->new(uri => $page_url);
        $gh->query_param(per_page => 100);

        my $gh_url = $gh->as_string;

        my $req = HTTP::Request->new(GET => $gh_url);
        $req->content_type('application/json');

        my $res      = $ua->request($req);
        my $res_code = $res->code;

        if (!$res->is_success) {
            print "Error: $res_code, for URL: $gh_url\n";
            if ($res_code == 408 || $res->status_line =~ /Can't connect to api.github.com/i) {
                $$no_delete = 1;
            }
            return;
        }

        my $links_hdr = $res->header('Link');

        $page_url = undef;
        if ($links_hdr) {
            my $last_page;
            my @links = split(',', $links_hdr);
            foreach my $link (@links) {
                if ($link =~ /rel=.next/) {
                    ($page_url) = ($link =~ /<(.+?)>/);
                }
            }
        }

        my $resp_body = $res->decoded_content;
        my $resp_ref  = decode_json($resp_body);
        push(@all_commits, @{$resp_ref});
    }

    return \@all_commits;
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
    my $gh_token = $gt ? $gt->get_access_token : $ENV{GITHUB_TOKEN};

    my $ua = LWP::UserAgent->new();
    $ua->default_header('Authorization' => "Bearer $gh_token");

    my $page_url = 'https://api.github.com/orgs/exceleron/repos?per_page=100';

    $last_pooled_at = time - 10;
    my $res      = $ua->get($page_url);
    my $res_code = $res->code;

    my $res_json = decode_json($res->decoded_content);

    if (!$res->is_success) {
        print "Error: " . $res->status_line . " for URL: $page_url\n";
        print Dumper($res_json);
        return;
    }

    foreach my $rep (@{$res_json}) {
        my $last_pushed = str2time($rep->{pushed_at});
        my $last_updated = str2time($rep->{updated_at});
        if($last_updated > $last_pooled_at || $last_pushed > $last_pooled_at) {
            print "Pooling for repo $rep->{name}\n";
            add_pending_prs($rep->{name});
        }
    }
}

# ============================================================================ #

sub add_pending_prs {
    my $repo = shift;
    my $gh_token = $gt ? $gt->get_access_token : $ENV{GITHUB_TOKEN};

    my $ua = LWP::UserAgent->new();
    $ua->default_header('Authorization' => "Bearer $gh_token");

    my $page_url = "https://api.github.com/repos/exceleron/$repo/pulls?per_page=100";

    my $res      = $ua->get($page_url);
    my $res_code = $res->code;

    if (!$res->is_success) {
        print "Error: $res_code, for URL: $page_url\n";
        print Dumper($res->decoded_content);
        return;
    }

    my $res_json = decode_json($res->decoded_content);

    foreach my $pr (@{$res_json}) {
        my $status_url = $pr->{statuses_url};
        my $statuses_res = $ua->get($status_url);

        my $pr_last_updated;
        if($pr->{updated_at}) {
            $pr_last_updated = str2time($pr->{updated_at});
        }
        else {
            $pr_last_updated = str2time($pr->{created_at});
        }

        if(!$statuses_res->is_success) {
            print "Failed to get status for PR $pr->{url}\n";
            next;
        }

        my $statuses_json = decode_json($statuses_res->decoded_content);
        #print Dumper($statuses_json);

        my $status_last_updated = 0;
        my $status = '';
        foreach my $st (@{$statuses_json}) {
            if($st->{context} eq 'ci/chk-youtrack') {
                $status_last_updated = str2time($st->{updated_at});
                $status = $st->{state};
                next;
            }
        }

        if($status ne 'success' and $status_last_updated < $pr_last_updated) {
            print "Adding PR for check from pooling method: $pr->{url}, Last state: $status\n";
            add_pull_request($repo, $pr->{commits_url}, $pr->{html_url});
        }
    }
}

# ============================================================================ #

sub add_pull_request {
    my ($repo_name, $commits_url, $pr_link) = @_; 
    my $dbh = get_db_conn();
    my $sql = qq/INSERT INTO GitPushEvent (event_type, project, commit_id, message, git_link, created_epoch) VALUES(?,?,?,?,?,?)/;
    my $sth = $dbh->prepare($sql);
    return $sth->execute('pull_request', $repo_name, undef, $commits_url, $pr_link, time);
}

# ============================================================================ #

check_db_pull_requests();

# Pool github for changes every 3 minutes
Mojo::IOLoop->recurring(180 => sub {
        pool_gh_pending_prs();
    });

Mojo::IOLoop->recurring( 10 => sub {
        check_db_pull_requests();
    });

Mojo::IOLoop->start unless Mojo::IOLoop->is_running;

# ============================================================================ #


