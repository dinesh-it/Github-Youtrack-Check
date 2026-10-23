#!/usr/bin/env perl

# Queue all open pull requests of a repository for check.
#
# Usage: add_all_open_pull.pl <owner> <repo>

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../";
use Github;
use Store;

if (!$ENV{GITHUB_TOKEN} and !$ENV{GITHUB_APP_KEY_FILE} and !$ENV{GITHUB_APP_KEY}) {
    die "GITHUB_TOKEN or GITHUB_APP_KEY_FILE or GITHUB_APP_KEY ENV required\n";
}

my ($owner, $project) = @ARGV;

if (!$owner || !$project) {
    die "Missing required params, pass owner project as params to this script\n";
}

die "Invalid owner or project name\n" if ("$owner/$project" !~ m{^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$});

my $gt = Github->new(private_key_file => $ENV{GITHUB_APP_KEY_FILE}, private_key => $ENV{GITHUB_APP_KEY});

die "Failed to get github access token\n" if (!$gt->get_access_token);
print "Using github app access token for github API\n" if ($gt->is_app);

my $all_open_prs = $gt->get_pull_requests($project, $owner);

die "Something went wrong!\n" if (!$all_open_prs);

Store::init_schema();

foreach my $pr (@{$all_open_prs}) {
    print "Adding pull request: $pr->{html_url}\n";
    Store::add_pull_request($project, $gt->api_path('repos', $owner, $project, 'pulls', $pr->{number}, 'commits'),
        $pr->{html_url});
}
