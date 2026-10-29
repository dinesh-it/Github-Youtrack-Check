#!/usr/bin/env perl

# Force check a pull request without waiting for the github web hook.
# The running service picks it up from the queue, fetches the PR title and
# commits and posts the result.
#
# Usage: add_pull_request.pl <owner> <repo> <pull_request_number>

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../lib";
use Store;

my ($owner, $project, $pr_num) = @ARGV;

if (!$owner || !$project || !$pr_num) {
    die "Missing required params, pass owner project pull_request_number as params to this script\n";
}

die "Invalid owner or project name\n" if ("$owner/$project" !~ m{^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$});
die "Invalid pull request number\n"  if ($pr_num !~ /^\d+$/);

my $api   = ($ENV{GITHUB_API_URL} || 'https://api.github.com') =~ s{/+$}{}r;
my $web   = ($ENV{GITHUB_GIT_URL} || 'https://github.com') =~ s{/+$}{}r;
my $c_url = "$api/repos/$owner/$project/pulls/$pr_num/commits";

Store::init_schema();
Store::add_pull_request($project, $c_url, "$web/$owner/$project/pull/$pr_num");

print "Added project: $project with commits URL: $c_url\n";
