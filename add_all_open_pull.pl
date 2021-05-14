#!/usr/bin/env perl

use strict;
use warnings;
use DBI;
use LWP::UserAgent;
use URI::Builder;
use JSON::XS;

use FindBin;
use lib $FindBin::Bin;
use GithubToken;

# Check of required ENV's available
if (!$ENV{GITHUB_TOKEN}) {
    die "GITHUB_TOKEN ENV required\n";
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

my $owner   = $ARGV[0];
my $project = $ARGV[1];

if (!$owner || !$project) {
    die "Missing required params, pass owner project as params to this script\n";
}

my $all_open_prs = fetch_all_open_pulls($owner, $project);

die "Something went wrong!\n" if(!$all_open_prs);

foreach my $pr (@{$all_open_prs}) {
    print "Adding pull request:" . $pr->{url} . "\n";
    add_pull_request($project, $pr->{commits_url}, $pr->{html_url});
}

# ============================================================================ #

sub fetch_all_open_pulls {
    my ($owner, $repo) = @_;

    my $gh_token = $gt ? $gt->get_access_token : $ENV{GITHUB_TOKEN};

    my $ua = LWP::UserAgent->new();
    $ua->default_header('Authorization' => "Bearer $gh_token");
    my $page_url = "https://api.github.com/repos/$owner/$project/pulls";

    my @all_open_pr;
    while ($page_url) {

        my $gh = URI::Builder->new(uri => $page_url);
        $gh->query_param(per_page => 100);
        $gh->query_param(state => 'open');

        my $gh_url = $gh->as_string;

        my $req = HTTP::Request->new(GET => $gh_url);
        $req->content_type('application/json');

        my $res      = $ua->request($req);
        my $res_code = $res->code;

        if (!$res->is_success) {
            print "Error: $res_code, for URL: $gh_url\n";
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
        push(@all_open_pr, @{$resp_ref});
    }

    return \@all_open_pr;
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

