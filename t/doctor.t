use strict;
use warnings;
use Test::More;
use Mojo::File qw(path tempdir);
use Mojo::UserAgent;
use POSIX qw(strftime);
use Mojo::JSON qw(decode_json);
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

# JSON output: exactly one JSON document on stdout
sub doctor_json {
    my $cmd  = join(' ', map {"'$_'"} '--json', @_);
    my $keep = join(' ', map {"$_='$ENV{$_}'"} grep { defined $ENV{$_} } qw(PATH HOME PERL5LIB));

    # stdout only, logs go to stderr
    my $out  = `env -i $keep $^X $FindBin::Bin/../scripts/ci-doctor.pl --env-file $tmp/env $cmd 2>/dev/null`;
    my $rc   = $? >> 8;
    my $data = eval { decode_json($out) };
    ok($data, "valid JSON for @_") or diag($out);
    return ($rc, booleans($data // {}));
}

# JSON true / false as 1 / 0 for comparisons
sub booleans {
    my ($d) = @_;
    return [map { booleans($_) } @{$d}] if (ref($d) eq 'ARRAY');
    return {map { $_ => booleans($d->{$_}) } keys %{$d}} if (ref($d) eq 'HASH');
    return $d ? 1 : 0 if (ref($d));
    return $d;
}

# ---------------------------------------------------------------------------- #
my ($rc, $out) = doctor('check-ticket', 'OPS-1: fix login');
is($rc, 0, 'check-ticket passes');
like($out, qr/Ticket id: OPS-1.*SUCCESS\s+OPS-1: Fix login/s, 'shows ticket and summary');

($rc, $out) = doctor('check-ticket', '--base', 'PRODUCTION', 'OPS-1 deploy');
is($rc, 1, 'PR title against production without CLUSTER ticket fails');
like($out, qr/PR title should have CLUSTER-\* ticket/, 'shows the rule');

($rc, $out) = doctor('check-ticket', 'no ticket');
is($rc, 1, 'missing ticket fails');

my $json;
($rc, $json) = doctor_json('check-ticket', '--base', 'PRODUCTION', 'CLUSTER-9 deploy');
is($rc, 0, 'json: exit code');
is_deeply([@{$json}{qw(command ok ticket_id type base)}], ['check-ticket', 1, 'CLUSTER-9', 'pr_title', 'PRODUCTION'], 'json: fields');
is($json->{result}{state}, 'success', 'json: result');

($rc, $json) = doctor_json('check-ticket', 'no ticket');
is_deeply([$rc, $json->{ok}, $json->{result}{state}], [1, 0, 'error'], 'json: failure');

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

($rc, $json) = doctor_json('check-pr', 'exceleron/RepoA#5');
is($json->{ok}, 0, 'json: check-pr not ok');
is($json->{title}{state}, 'error', 'json: title result');
is_deeply([map { [$_->{sha}, $_->{head}, $_->{result}{state}] } @{$json->{commits}}],
    [[$sha->('e'), 0, 'success'], [$sha->('f'), 1, 'error']], 'json: commit results');

($rc, $out) = doctor('check-pr', '--queue', 'exceleron/RepoA#5');
like($out, qr/Queued/, 'queued for re-check');

($rc, $out) = doctor('queue');
like($out, qr{PR https://github.com/exceleron/RepoA/pull/5}, 'queue lists the PR');
($rc, $json) = doctor_json('queue');
is($json->{entries}[0]{type}, 'pull_request', 'json: queue entry');
my $row_id = $json->{entries}[0]{row_id};
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

($rc, $json) = doctor_json('deliveries', '--failed');
is_deeply([$rc, $json->{undelivered}, $json->{deliveries}[0]{guid}, $json->{deliveries}[0]{status_code}], [1, 1, 'g-fail', 502],
    'json: undelivered deliveries, exit 1');

my @jwt_calls = grep { $_->{path} =~ m{/app/hook/deliveries} } @{$ua->get("$mock/_calls")->result->json};
ok((@jwt_calls and !grep { ($_->{auth} // '') !~ /^Bearer eyJ/ } @jwt_calls), 'delivery API called with the app JWT');

# ---------------------------------------------------------------------------- #
mock_state(branches => {RepoA => [{name => 'main', commit => {sha => $sha->('a')}}]});
($rc, $out) = doctor('sync', 'RepoA');
like($out, qr/main\s+a{40}.*1 branch\(es\) updated/s, 'sync updates branch state');

($rc, $out) = doctor('status', '--url', "$mock/_calls");
like($out, qr/Probe\s+200 ok/, 'status probe');
like($out, qr/Failed\s+1 \(gave up 0\)\n\s+g-fail\s+push/, 'status shows pending redelivery');

($rc, $json) = doctor_json('status', '--url', "$mock/_calls");
is($json->{ok}, 1, 'json: status ok');
is($json->{probe}{code}, 200, 'json: probe');
is($json->{redelivery}{failed_count}, 1, 'json: failed redeliveries');
is($json->{redelivery}{failed}[0]{guid}, 'g-fail', 'json: failed delivery');
ok(exists $json->{queue}{oldest_secs}, 'json: queue');
is_deeply([scalar(@{$json->{hook_ips}{github}}), $json->{hook_ips}{not_allowed}], [5, []], 'json: github hook IPv4 ranges allowed');

# A new github hook range not in the allowed ones fails the status
mock_state(hooks => ['192.30.252.0/22', '192.30.253.0/24', '9.234.200.0/28', '2606:50c0::/32']);
($rc, $out) = doctor('status', '--url', "$mock/_calls");
is($rc, 1, 'status fails for a hook range not allowed');
like($out, qr/Allowed\s+2 of 3.*\n\s+NOT ALLOWED\s+9\.234\.200\.0\/28/, 'status shows the range not allowed');

($rc, $json) = doctor_json('status', '--url', "$mock/_calls");
is_deeply([$rc, $json->{ok}, $json->{hook_ips}{not_allowed}], [1, 0, ['9.234.200.0/28']], 'json: range not allowed');

mock_state(fail => {'GET /gh/meta' => {code => 500, count => 1}});
($rc, $json) = doctor_json('status', '--url', "$mock/_calls");
is($json->{ok}, 1, 'json: meta API failure does not fail the status');
like($json->{hook_ips}{error}, qr/Could not get the web hook IP ranges/, 'json: meta API failure reported');

($rc, $json) = doctor_json('status', '--url', 'http://127.0.0.1:9/ghyt-ci');
is_deeply([$rc, $json->{ok}, $json->{probe}{ok}], [1, 0, 0], 'json: probe down, exit 1');

($rc, $json) = doctor_json('check-pr', 'exceleron/RepoA#404');
is_deeply([$rc, $json->{ok}], [1, 0], 'json: error as JSON');
like($json->{error}, qr/not found/, 'json: error message');

done_testing;
