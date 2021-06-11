#!/usr/bin/env perl
#
use strict;
use warnings;

use FindBin;
use lib $FindBin::Bin;
use GithubToken;

my $force = $ARGV[0] // 0;

my $gt = GithubToken->new(
        private_key_file => $ENV{GITHUB_APP_KEY_FILE},
        github_app_id => '114097',
        access_token_url => 'https://api.github.com/app/installations/17060698/access_tokens',
        force_update => $force,
        );

if($gt->get_access_token) {
print "ok\n"
}

print "Readonly token: " . $gt->get_read_only_access_token . "\n";
