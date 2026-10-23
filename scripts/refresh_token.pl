#!/usr/bin/env perl

# Refresh the github app installation token shared via the token file.
#
# Usage: refresh_token.pl [force]
# Set SHOW_TOKEN=1 to print the read only token, it is masked otherwise.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../";
use Github;

my $force = $ARGV[0] // 0;

my $gt = Github->new(
    private_key_file => $ENV{GITHUB_APP_KEY_FILE},
    private_key      => $ENV{GITHUB_APP_KEY},
    github_app_id    => $ENV{GITHUB_APP_ID},
    access_token_url => $ENV{GITHUB_TOKEN_URL},
    force_update     => $force,
);

die "Failed to get github access token\n" if (!$gt->get_access_token);
print "ok\n";

my $ro_token = $gt->get_read_only_access_token;
die "Failed to get read only access token\n" if (!$ro_token);

print "Readonly token: " . ($ENV{SHOW_TOKEN} ? $ro_token : substr($ro_token, 0, 4) . '****') . "\n";
