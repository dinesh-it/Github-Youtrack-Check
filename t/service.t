use strict;
use warnings;
use Test::More;
use Test::Mojo;
use Mojo::File qw(path tempdir);
use Mojo::JSON qw(encode_json decode_json);
use Mojo::UserAgent;
use Digest::SHA qw(hmac_sha256_hex);
use POSIX qw(strftime);
use Crypt::OpenSSL::RSA;

use FindBin;
use lib "$FindBin::Bin/../lib", "$FindBin::Bin/lib";
use MockApi;
use SecureChannel;

my ($mock, $mock_pid) = MockApi::start();
END { kill('TERM', $mock_pid) if ($mock_pid) }

my $tmp = tempdir;
my $key = Crypt::OpenSSL::RSA->generate_key(2048);
path("$tmp/app.pem")->spurt($key->get_private_key_string);

my $hook_secret = 'hook-secret';
my $ws_secret   = 'w' x 64;

%ENV = (
    %ENV,
    GITHUB_API_URL      => "$mock/gh",
    GITHUB_APP_KEY_FILE => "$tmp/app.pem",
    GITHUB_APP_ID       => 1,
    GITHUB_TOKEN_URL    => "$mock/gh/app/installations/7/access_tokens",
    GITHUB_TOKEN_FILE   => "$tmp/token",
    GITHUB_WEB_HOOK_DB  => "$tmp/hook.db",
    GITHUB_SECRET       => $hook_secret,
    GH_WEBSOCKET_SECRET => $ws_secret,
    YOUTRACK_HOST       => $mock,
    YOUTRACK_TOKEN      => 'yt-token',
    PR_BRANCH_YT_CHECK  => 'PRODUCTION*=CLUSTER-*',
    DISABLE_CHECK_API   => 1,
    HTTP_TIMEOUT        => 5,
    LOG_LEVEL           => 'fatal',
);
delete $ENV{GITHUB_TOKEN};

my $ua = Mojo::UserAgent->new;
sub mock_state { $ua->post("$mock/_state" => json => {@_})->result }
sub mock_reset { $ua->post("$mock/_reset")->result }
sub mock_calls { $ua->get("$mock/_calls")->result->json }

sub statuses {
    my %by_sha;
    foreach my $call (@{mock_calls()}) {
        next if ($call->{failed} or $call->{path} !~ m{/statuses/([0-9a-f]+)$});
        push(@{$by_sha{$1}}, $call->{body});
    }
    return \%by_sha;
}

sub final_status {
    my ($sha) = @_;
    my @list = grep { $_->{state} ne 'pending' } @{statuses()->{$sha} // []};
    return $list[-1];
}

my $t = Test::Mojo->new(path("$FindBin::Bin/../github_web_hook.pl"));

# Functions of the lite app live in the Mojo sandbox package
my ($sandbox) = grep { defined &{"Mojo::Server::Sandbox::${_}check_all_commits"} } keys %Mojo::Server::Sandbox::;
ok($sandbox, 'service loaded');
no strict 'refs';
my %fn = map { $_ => \&{"Mojo::Server::Sandbox::${sandbox}$_"} }
  qw(check_all_commits process_pull_requests poll_github);
use strict 'refs';

sub run_spooler { $fn{process_pull_requests}->(); $fn{check_all_commits}->() }

sub hook {
    my ($event, $payload, %opt) = @_;
    my $body = encode_json($payload);
    my $sig  = $opt{signature} // 'sha256=' . hmac_sha256_hex($body, $hook_secret);
    return $t->post_ok('/check_youtrack' => {'X-GitHub-Event' => $event, 'X-Hub-Signature-256' => $sig} => $body);
}

sub sha { my $c = shift; return $c x 40 }

my $repo = {name => 'RepoA', owner => {login => 'exceleron', name => 'exceleron'}, pushed_at => time};

# ---------------------------------------------------------------------------- #
subtest 'probe' => sub {
    $t->get_ok('/ghyt-ci')->status_is(200)->json_is('/status', 'ok')->json_is('/spooler_state', 'ok');
};

# ---------------------------------------------------------------------------- #
subtest 'web hook signature is required' => sub {
    hook('ping', {repository => $repo}, signature => '')->status_is(401);
    hook('ping', {repository => $repo}, signature => 'sha256=' . ('0' x 64))->status_is(401);
    $t->post_ok('/check_youtrack' => {'X-GitHub-Event' => 'ping'} => '{}')->status_is(401);
    hook('ping', {repository => $repo})->status_is(200)->json_is('/msg', 'Configuration Success!');
    hook('watch', {repository => $repo})->status_is(200)->json_is('/status', 'ignored');
};

# ---------------------------------------------------------------------------- #
subtest 'push commits are checked' => sub {
    mock_reset();
    hook(
        'push',
        {
            ref        => 'refs/heads/feature',
            after      => sha('a'),
            repository => $repo,
            commits    => [
                {id => sha('a'), message => 'OPS-1: fix login'},
                {id => sha('b'), message => 'no ticket here'},
                {id => sha('c'), message => "Merge branch 'master' into feature"},
                {id => sha('d'), message => 'ops-404 unknown ticket'},
            ],
        }
    )->status_is(200)->json_is('/status', 'ok');

    $fn{check_all_commits}->();

    is(final_status(sha('a'))->{state}, 'success', 'commit with valid ticket passes');
    is(final_status(sha('a'))->{description}, 'OPS-1: Fix login', 'description has ticket summary');
    like(final_status(sha('a'))->{target_url}, qr{/youtrack/issue/OPS-1$}, 'links to the ticket');
    is(final_status(sha('b'))->{state}, 'error', 'commit without ticket fails');
    is(final_status(sha('c'))->{state}, 'success', 'merge commit skipped');
    is(final_status(sha('d'))->{state}, 'error', 'unknown ticket fails');

    mock_reset();
    $fn{check_all_commits}->();
    is_deeply(statuses(), {}, 'queue is empty after check');
};

# ---------------------------------------------------------------------------- #
# Helper to set up a pull request in the mock
sub setup_pr {
    my (%pr) = @_;
    my $key = "RepoA#$pr{number}";
    mock_state(
        pulls => {
            $key => {
                number   => $pr{number},
                state    => 'open',
                title    => $pr{title},
                html_url => "https://github.com/exceleron/RepoA/pull/$pr{number}",
                head     => {sha => $pr{head}},
                base     => {ref => $pr{base}},
            }
        },
        commits => {$key => [map { {sha => $_->[0], commit => {message => $_->[1]}} } @{$pr{commits}}]},
    );
}

sub pr_event {
    my ($number, $head, $action) = @_;
    return hook(
        'pull_request',
        {
            action       => $action // 'opened',
            repository   => $repo,
            pull_request => {number => $number, html_url => "https://github.com/exceleron/RepoA/pull/$number", head => {sha => $head}},
        }
    );
}

subtest 'PR title check against production branch' => sub {
    mock_reset();
    setup_pr(
        number  => 5,
        title   => 'OPS-2 add report',
        base    => 'PRODUCTION',
        head    => sha('f'),
        commits => [[sha('e'), 'OPS-2: report'], [sha('f'), "Merge branch 'x' into y"]],
    );

    pr_event(5, sha('f'))->status_is(200)->json_is('/status', 'ok');
    run_spooler();

    is(final_status(sha('e'))->{state}, 'success', 'non head commit passes');
    is(final_status(sha('f'))->{state}, 'error', 'merge head commit fails on PR title');
    is(final_status(sha('f'))->{description}, 'PR title should have CLUSTER-* ticket for PRODUCTION* branch', 'title reason');
    is(statuses()->{sha('f')}[0]{state}, 'pending', 'pending posted first');

    my @comments = grep { $_->{path} =~ m{/issues/OPS-2/comments} } @{mock_calls()};
    ok(scalar(@comments), 'PR link commented on the ticket');
    like($comments[0]{body}{text}, qr{pull/5}, 'comment has the PR link');

    mock_reset();
    setup_pr(number => 6, title => 'CLUSTER-9 release', base => 'PRODUCTION', head => sha('1'), commits => [[sha('1'), 'OPS-1: fix']]);
    pr_event(6, sha('1'));
    run_spooler();
    is(final_status(sha('1'))->{state}, 'success', 'valid CLUSTER title passes');
    is(final_status(sha('1'))->{description}, 'CLUSTER-9: Deploy release', 'description from PR title ticket');
};

# ---------------------------------------------------------------------------- #
subtest 'head commit waits for its PR title (race regression)' => sub {
    mock_reset();
    setup_pr(number => 7, title => 'no ticket title', base => 'master', head => sha('2'), commits => [[sha('2'), 'OPS-1: x']]);

    # Push event and PR event arrive, commits get checked before the PR is fetched
    pr_event(7, sha('2'));
    hook('push', {ref => 'refs/heads/br', after => sha('2'), repository => $repo, commits => [{id => sha('2'), message => 'OPS-1: x'}]});

    $fn{check_all_commits}->();
    ok(!final_status(sha('2')), 'head commit not passed while the PR is pending');

    run_spooler();
    is(final_status(sha('2'))->{state}, 'error', 'head commit fails on PR title');
    is(scalar(grep { $_->{state} ne 'pending' } @{statuses()->{sha('2')}}), 1, 'single final status');
};

# ---------------------------------------------------------------------------- #
subtest 'PR fetch retried on github errors, title check kept' => sub {
    mock_reset();
    setup_pr(number => 8, title => 'OPS-1 only', base => 'PRODUCTION', head => sha('3'), commits => [[sha('3'), 'OPS-1: y']]);
    mock_state(fail => {'GET /gh/repos/exceleron/RepoA/pulls/8' => {code => 502, count => 1}});

    pr_event(8, sha('3'));
    run_spooler();
    ok(!final_status(sha('3')), 'nothing posted while github is failing');

    run_spooler();
    is(final_status(sha('3'))->{state}, 'error', 'title check applied after retry');
};

# ---------------------------------------------------------------------------- #
subtest 'head commit missing from the commits list is still title checked' => sub {
    mock_reset();
    setup_pr(number => 10, title => 'OPS-1 bad', base => 'PRODUCTION', head => sha('7'), commits => [[sha('e'), 'OPS-1: old']]);
    mock_state(single_commits => {sha('7') => {sha => sha('7'), commit => {message => 'OPS-1: new head'}}});

    pr_event(10, sha('7'));
    run_spooler();
    is(final_status(sha('7'))->{state}, 'error', 'head commit fetched separately and title failed');
};

# ---------------------------------------------------------------------------- #
subtest 'unverifiable PR fails closed without stalling the repo' => sub {
    mock_reset();

    # Head commit gone (eg: force push) and not in the list
    setup_pr(number => 11, title => 'CLUSTER-9 ok', base => 'PRODUCTION', head => sha('8'), commits => [[sha('e'), 'OPS-1: old']]);
    pr_event(11, sha('8'));
    hook('push', {ref => 'refs/heads/other', after => sha('9'), repository => $repo, commits => [{id => sha('9'), message => 'OPS-1: other'}]});

    run_spooler();
    is(final_status(sha('8'))->{state}, 'error', 'head commit marked failed');
    is(final_status(sha('9'))->{state}, 'success', 'other commits of the repo are not stalled');

    # PR deleted / no access - head sha from the web hook is failed
    mock_reset();
    pr_event(12, sha('a'));
    run_spooler();
    is(final_status(sha('a'))->{state}, 'error', 'head from web hook marked failed when PR is not available');
};

# ---------------------------------------------------------------------------- #
subtest 'status post retried on 5xx' => sub {
    mock_reset();
    mock_state(fail => {'POST /gh/repos/exceleron/RepoA/statuses/' . sha('4') => {code => 503, count => 1}});
    hook('push', {ref => 'refs/heads/br', after => sha('4'), repository => $repo, commits => [{id => sha('4'), message => 'OPS-1: z'}]});

    $fn{check_all_commits}->();
    ok(!final_status(sha('4')), 'first attempt failed');

    $fn{check_all_commits}->();
    is(final_status(sha('4'))->{state}, 'success', 'posted on retry');
};

# ---------------------------------------------------------------------------- #
subtest 'youtrack outage does not fail commits' => sub {
    mock_reset();
    mock_state(fail => {'GET /youtrack/api/issues/OPS-3' => {code => 500, count => 1}});
    hook('push', {ref => 'refs/heads/br', after => sha('5'), repository => $repo, commits => [{id => sha('5'), message => 'OPS-3 thing'}]});

    $fn{check_all_commits}->();
    ok(!final_status(sha('5')), 'not failed while youtrack is down');

    $fn{check_all_commits}->();
    is(final_status(sha('5'))->{state}, 'success', 'passes once youtrack is back');
};

# ---------------------------------------------------------------------------- #
subtest 'polling re-checks PR title (bypass regression)' => sub {
    mock_reset();
    my $now = time;
    my $iso = sub { strftime('%Y-%m-%dT%H:%M:%SZ', gmtime(shift)) };

    setup_pr(number => 9, title => 'OPS-1 not cluster', base => 'PRODUCTION', head => sha('6'), commits => [[sha('6'), 'OPS-1: w']]);
    mock_state(
        repos      => [{name => 'RepoA', owner => {login => 'exceleron'}, pushed_at => $iso->($now), updated_at => $iso->($now - 9999)}],
        pull_lists => {
            RepoA => [
                {number => 9, html_url => 'https://github.com/exceleron/RepoA/pull/9', updated_at => $iso->($now), head => {sha => sha('6')}}
            ]
        },

        # Head commit was marked success earlier, before the PR got a comment
        statuses => {sha('6') => [{context => 'ci/chk-youtrack', state => 'success', updated_at => $iso->($now - 60)}]},
    );

    $fn{poll_github}->();
    run_spooler();

    is(final_status(sha('6'))->{state}, 'error', 'success without title check is corrected');
};

# ---------------------------------------------------------------------------- #
subtest 'installation event failures keep the working token' => sub {
    hook('installation', {action => 'deleted', installation => {app_id => 1}})->status_is(200)->json_is('/status', 'ignored');
    hook('installation', {action => 'created', installation => {app_id => 1, account => {login => 'someone-else'}, access_tokens_url => "$mock/gh/app/installations/99/access_tokens"}})
      ->status_is(200)->json_is('/msg', 'Installation account not served');
    hook('installation', {action => 'created', installation => {app_id => 1, account => {login => 'exceleron'}, access_tokens_url => 'https://evil.example/app/installations/1/access_tokens'}})
      ->status_is(500);

    mock_reset();
    hook('push', {ref => 'refs/heads/br', after => sha('7'), repository => $repo, commits => [{id => sha('7'), message => 'OPS-1'}]});
    $fn{check_all_commits}->();
    is(final_status(sha('7'))->{state}, 'success', 'service still posts with the old installation');
};

# ---------------------------------------------------------------------------- #
subtest 'late or redelivered pushes never move a ref back' => sub {
    my $now   = time;
    my $state = sub { (Store::get_repo_state('RepoA', 'refs/heads/PRODUCTION') // {})->{latest_commit_id} // 'none' };
    my $push  = sub {
        my ($after, $at, %extra) = @_;
        hook('push', {ref => 'refs/heads/PRODUCTION', after => $after, repository => {%{$repo}, pushed_at => $at}, commits => [], %extra});
    };
    my $run_timers = sub { Mojo::IOLoop->timer(0.6 => sub { Mojo::IOLoop->stop }); Mojo::IOLoop->start };

    mock_reset();
    mock_state(refs => {'RepoA:refs/heads/PRODUCTION' => sha('b')});

    $push->(sha('b'), $now);
    is($state->(), sha('b'), 'newer push stored');

    # Service was down, push A (older) is redelivered after B is known
    $push->(sha('a'), $now - 600)->status_is(200);
    $run_timers->();
    is($state->(), sha('b'), 'older push does not move the ref back');

    # Old delete redelivered after the branch was re-created
    $push->('0' x 40, $now - 300, deleted => 1)->json_is('/msg', 'Older delete ignored');
    $run_timers->();
    is($state->(), sha('b'), 'older delete ignored');

    # Same second, different sha - resolved from github
    mock_state(refs => {'RepoA:refs/heads/PRODUCTION' => sha('c')});
    $push->(sha('d'), $now);
    $run_timers->();
    is($state->(), sha('c'), 'ambiguous push resolved from the github ref');

    $push->(sha('e'), $now + 5);
    is($state->(), sha('e'), 'later push stored');

    # Branch deleted on github, delete event lost - resolve finds no ref
    mock_state(refs => {});
    $push->(sha('a'), $now - 900);
    $run_timers->();
    is($state->(), 'none', 'state removed when the ref does not exist on github');
};

# ---------------------------------------------------------------------------- #
subtest 'git sync websocket' => sub {
    my $sc = SecureChannel->new(secret => $ws_secret);

    hook('push', {ref => 'refs/heads/main', after => sha('8'), repository => $repo, commits => []});
    hook('push', {ref => 'refs/heads/main', after => sha('9'), repository => {%{$repo}, name => 'RepoB'}, commits => []});

    # Wrong secret
    $t->websocket_ok('/githubpush')->message_ok->json_message_is('/type' => 'challenge');
    my $challenge = decode_json($t->message->[1])->{challenge};
    my $bad       = SecureChannel->new(secret => 'x' x 64);
    $t->send_ok({json => {type => 'auth', repos => ['RepoA'], response => $bad->auth_response($challenge, 'RepoA')}})
      ->finished_ok(4003);

    # Requests before authentication are refused
    $t->websocket_ok('/githubpush')->message_ok->send_ok('give-latest')->finished_ok(4003);

    # Authenticated client gets sealed state for subscribed repos only
    $t->websocket_ok('/githubpush')->message_ok;
    $challenge = decode_json($t->message->[1])->{challenge};
    $t->send_ok({json => {type => 'auth', repos => ['RepoA'], response => $sc->auth_response($challenge, 'RepoA')}})
      ->message_ok->json_message_is('/type' => 'ready')->send_ok('give-latest');

    # One message per known ref of RepoA, find the main branch
    my ($msg, @projects);
    for (1 .. 4) {
        $t->message_ok;
        my $raw = $t->message->[1];
        unlike($raw, qr/ghs_/, 'token not visible on the wire');
        my $data = decode_json($sc->unseal($raw) // 'null');
        push(@projects, $data->{project});
        if ($data->{ref} eq 'refs/heads/main') { $msg = $data; last }
    }
    is_deeply([sort { $a cmp $b } keys %{{map { $_ => 1 } @projects}}], ['RepoA'], 'only subscribed repo received');
    is($msg->{project}, 'RepoA', 'state for subscribed repo');
    is($msg->{sha}, sha('8'), 'latest sha');
    is($msg->{token}, 'ghs_ro_RepoA', 'read only token scoped to the repo');
    is($msg->{remote_url}, 'https://github.com/exceleron/RepoA.git', 'clone URL without credentials');

    $t->finish_ok;

    # Branch delete removes the state
    hook('push', {ref => 'refs/heads/main', after => '0' x 40, deleted => 1, repository => {%{$repo}, pushed_at => time + 10}, commits => []})
      ->json_is('/msg', 'Ref deleted');
};

done_testing;
