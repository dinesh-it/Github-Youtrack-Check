#!/usr/bin/env perl
#
use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../";
use Github;

my $force = $ARGV[0] // 0;

my $gt = Github->new(
        private_key_file => $ENV{GITHUB_APP_KEY_FILE},
        github_app_id => $ENV{GITHUB_APP_ID},
        access_token_url => $ENV{GITHUB_TOKEN_URL},
        force_update => $force,
        );

if($gt->get_access_token) {
    print "ok\n"
}

print "Readonly token: " . $gt->get_read_only_access_token . "\n";
