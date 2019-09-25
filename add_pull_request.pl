#!/usr/bin/env perl

use strict;
use warnings;
use DBI;

my $owner   = $ARGV[0];
my $project = $ARGV[1];
my $pr_num  = $ARGV[2];

if (!$owner || !$project || !$pr_num) {
    die "Missing required params, pass owner project pull_request_number as params to this script\n";
}

my $c_url = "https://api.github.com/repos/$owner/$project/pulls/$pr_num/commits";

add_pull_request($project, $c_url);

print "Added project: $project with commits URL: $c_url\n";

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

