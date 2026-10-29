use strict;
use warnings;
use Test::More;
use Mojo::File qw(path tempdir);
use Mojo::UserAgent;
use POSIX qw(strftime);
use Crypt::OpenSSL::RSA;

use FindBin;
use lib "$FindBin::Bin/../lib", "$FindBin::Bin/lib";
use MockApi;

my ($mock, $mock_pid) = MockApi::start();
END { kill('TERM', $mock_pid) if ($mock_pid) }

my $tmp = tempdir;
path("$tmp/app.pem")->spurt(Crypt::OpenSSL::RSA->generate_key(2048)->get_private_key_string);

# Same format as the service env file
path("$tmp/env")->spurt(<<"EOF");
# service env
GITHUB_API_URL=$mock/gh
GITHUB_APP_KEY_FILE=$tmp/app.pem
GITHUB_APP_ID=1
GITHUB_TOKEN_URL=$mock/gh/app/installations/7/access_tokens
GITHUB_TOKEN_FILE=$tmp/token
GITHUB_WEB_HOOK_DB=$tmp/hook.db
YOUTRACK_HOST=$mock
YOUTRACK_TOKEN=yt-token
PR_BRANCH_YT_CHECK='PRODUCTION*=CLUSTER-*'
DISABLE_CHECK_API=1
HTTP_TIMEOUT=5
EOF

my $ua = Mojo::UserAgent->new;
sub mock_state { $ua->post("$mock/_state" => json => {@_})->result }

sub doctor {
    my $cmd = join(' ', map {"'$_'"} @_);
    # Clean environment, so nothing from the calling shell (eg: a real
    # YOUTRACK_HOST / YOUTRACK_TOKEN) can point the script at a real service
    my $keep = join(' ', map {"$_='$ENV{$_}'"} grep { defined $ENV{$_} } qw(PATH HOME PERL5LIB));
    my $out  = `env -i $keep $^X $FindBin::Bin/../scripts/ci-doctor.pl --env-file $tmp/env $cmd 2>&1`;
    return ($? >> 8, $out);
}

my $sha = sub { $_[0] x 40 };

# ---------------------------------------------------------------------------- #
my ($rc, $out) = doctor('check-ticket', 'OPS-1: fix login');
is($rc, 0, 'check-ticket passes');
like($out, qr/Ticket id: OPS-1.*SUCCESS\s+OPS-1: Fix login/s, 'shows ticket and summary');

($rc, $out) = doctor('check-ticket', '--base', 'PRODUCTION', 'OPS-1 deploy');
is($rc, 1, 'PR title against production without CLUSTER ticket fails');
like($out, qr/PR title should have CLUSTER-\* ticket/, 'shows the rule');

($rc, $out) = doctor('check-ticket', 'no ticket');
is($rc, 1, 'missing ticket fails');

# ---------------------------------------------------------------------------- #
mock_state(
    pulls => {
        'RepoA#5' => {
            number => 5, state => 'open', title => 'OPS-2 report', html_url => 'https://github.com/exceleron/RepoA/pull/5',
            head => {sha => $sha->('f')}, base => {ref => 'PRODUCTION'}
        }
    },
    commits => {'RepoA#5' => [{sha => $sha->('e'), commit => {message => 'OPS-1: a'}}, {sha => $sha->('f'), commit => {message => 'OPS-2: b'}}]},
);

($rc, $out) = doctor('check-pr', 'exceleron/RepoA#5');
is($rc, 1, 'check-pr reports the failing PR');
like($out, qr/PR title\s+ERROR\s+PR title should have CLUSTER/, 'title failure shown');
like($out, qr/eeeeeeeeee.*\n\s+Result\s+SUCCESS/, 'non head commit passes');
like($out, qr/ffffffffff \(head\).*\n\s+Result\s+ERROR/, 'head commit fails on the title');

($rc, $out) = doctor('check-pr', '--queue', 'exceleron/RepoA#5');
like($out, qr/Queued/, 'queued for re-check');

($rc, $out) = doctor('queue');
like($out, qr{PR https://github.com/exceleron/RepoA/pull/5}, 'queue lists the PR');
my ($row_id) = ($out =~ /^(\d+)\s/m);
($rc, $out) = doctor('queue', 'drop', $row_id);
is($rc, 0, 'queue drop');
($rc, $out) = doctor('queue');
unlike($out, qr/pull\/5/, 'removed from queue');

# ---------------------------------------------------------------------------- #
my $at = strftime('%Y-%m-%dT%H:%M:%SZ', gmtime(time - 60));
mock_state(
    deliveries => [
        {id => 11, guid => 'g-fail', status_code => 502, event => 'push',         delivered_at => $at},
        {id => 12, guid => 'g-ok',   status_code => 200, event => 'pull_request', action => 'opened', delivered_at => $at},
    ]
);

($rc, $out) = doctor('deliveries', '--failed');
like($out, qr/^11\s.*push\s+502\s+g-fail/m, 'failed delivery listed');
unlike($out, qr/g-ok/, 'delivered one filtered');

($rc, $out) = doctor('redeliver', '11');
like($out, qr/Delivery 11 redelivered/, 'manual redelivery');

($rc, $out) = doctor('redeliver', '--failed');
like($out, qr/1 delivery\(s\) redelivered/, 'automatic redelivery run on demand');

my @jwt_calls = grep { $_->{path} =~ m{/app/hook/deliveries} } @{$ua->get("$mock/_calls")->result->json};
ok((@jwt_calls and !grep { ($_->{auth} // '') !~ /^Bearer eyJ/ } @jwt_calls), 'delivery API called with the app JWT');

# ---------------------------------------------------------------------------- #
mock_state(branches => {RepoA => [{name => 'main', commit => {sha => $sha->('a')}}]});
($rc, $out) = doctor('sync', 'RepoA');
like($out, qr/main\s+a{40}.*1 branch\(es\) updated/s, 'sync updates branch state');

($rc, $out) = doctor('status', '--url', "$mock/_calls");
like($out, qr/Probe\s+200 ok/, 'status probe');
like($out, qr/Failed\s+1\n\s+g-fail\s+push/, 'status shows pending redelivery');

done_testing;
