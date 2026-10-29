use strict;
use warnings;
use Test::More;
use Mojo::File qw(path tempdir);
use Mojo::JSON qw(encode_json);
use Mojo::UserAgent;
use Mojo::IOLoop::Server;
use Digest::SHA qw(hmac_sha256_hex);
use Crypt::OpenSSL::RSA;

use FindBin;
use lib "$FindBin::Bin/../lib", "$FindBin::Bin/lib";
use MockApi;

plan skip_all => 'git is required' if (system('git --version >/dev/null 2>&1') != 0);
plan skip_all => 'Config::Any is required for the git sync client' if (!eval { require Config::Any; 1 });

my ($mock, $mock_pid) = MockApi::start();
my @pids = ($mock_pid);
END { kill('TERM', $_) for (grep {$_} @pids) }

my $tmp = tempdir;
path("$tmp/app.pem")->spurt(Crypt::OpenSSL::RSA->generate_key(2048)->get_private_key_string);

my $hook_secret = 'hook-secret';
my $ws_secret   = 'z' x 64;
my $port        = Mojo::IOLoop::Server->generate_port;

sub git {
    my $out = `git @_ 2>&1`;
    die "git @_ failed: $out" if ($?);
    chomp($out);
    return $out;
}

# Upstream repository with one commit on main
git("init -q --bare $tmp/upstream.git");
git("init -q -b main $tmp/work");
git("-C $tmp/work -c user.name=t -c user.email=t\@t commit -q --allow-empty -m 'OPS-1: init'");
git("-C $tmp/work push -q $tmp/upstream.git main");
my $sha = git("-C $tmp/work rev-parse HEAD");

git("init -q --bare $tmp/local.git");
git("init -q --bare $tmp/localb.git");

# Server
my %server_env = (
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
    DISABLE_CHECK_API   => 1,
    HTTP_TIMEOUT        => 5,
);

sub spawn {
    my ($env, $log, @cmd) = @_;
    my $pid = fork() // die "fork failed: $!";
    if (!$pid) {
        delete $ENV{GITHUB_TOKEN};
        @ENV{keys %{$env}} = values %{$env};
        open(STDOUT, '>', $log) or die;
        open(STDERR, '>&', \*STDOUT);
        exec(@cmd) or exit 127;
    }
    push(@pids, $pid);
    return $pid;
}

spawn(\%server_env, "$tmp/server.log", $^X, "$FindBin::Bin/../github_web_hook.pl", 'daemon', '-l', "http://127.0.0.1:$port");

my $ua = Mojo::UserAgent->new;
my $up = 0;
for (1 .. 100) {
    my $res = eval { $ua->get("http://127.0.0.1:$port/ghyt-ci")->result };
    if ($res and $res->code == 200) { $up = 1; last }
    select(undef, undef, undef, 0.1);
}
ok($up, 'server started') or diag(slurp("$tmp/server.log"));

# Client
path("$tmp/client.pl")->spurt(<<"EOF");
{
    server_url => 'ws://127.0.0.1:$port/githubpush',
    allowed_remote_hosts => ['example.invalid'],
    ping_interval => 1,
    resync_interval => 2,
    fileserver_update_command => ['sh', '-c', 'touch $tmp/fs.updated'],
    repo => {
        RepoA => {
            local_path => '$tmp/local.git',
            remote_url => '$tmp/upstream.git',
            salt_fileserver_update => 1,
            'refs/heads/main' => { force_fetch => 1 },
        },
        RepoB => {
            local_path => '$tmp/localb.git',
            salt_fileserver_update => 1,
            'refs/heads/main' => {},
        },
    },
}
EOF

spawn({EX_GITHOOK_CONFIG_FILE => "$tmp/client.pl", GH_WEBSOCKET_SECRET => $ws_secret},
    "$tmp/client.log", $^X, "$FindBin::Bin/../git-sync-client/update_git_repo.pl");

sub slurp { my $f = path(shift); return -e $f ? $f->slurp : '' }

sub wait_for {
    my ($cond) = @_;
    for (1 .. 150) { return 1 if ($cond->()); select(undef, undef, undef, 0.1) }
    return 0;
}

ok(wait_for(sub { slurp("$tmp/client.log") =~ /Connected!/ }), 'client authenticated')
  or diag(slurp("$tmp/client.log"));

sub hook {
    my ($payload) = @_;
    my $body = encode_json($payload);
    return $ua->post(
        "http://127.0.0.1:$port/check_youtrack" => {
            'X-GitHub-Event'      => 'push',
            'X-Hub-Signature-256' => 'sha256=' . hmac_sha256_hex($body, $hook_secret)
        } => $body
    )->result;
}

my $owner = {login => 'exceleron', name => 'exceleron'};
is(hook({ref => 'refs/heads/main', after => $sha, repository => {name => 'RepoA', owner => $owner}, commits => []})->code,
    200, 'push event accepted');

ok(
    wait_for(sub { my $s = `git -C $tmp/local.git rev-parse --verify --quiet refs/heads/main 2>/dev/null`; chomp $s; $s eq $sha }),
    'client fetched the pushed commit'
) or diag(slurp("$tmp/client.log"));

ok(wait_for(sub { -e "$tmp/fs.updated" }), 'salt fileserver update ran after the fetch');
unlink("$tmp/fs.updated");

hook({ref => 'refs/heads/main', after => $sha, repository => {name => 'RepoB', owner => $owner}, commits => []});
ok(wait_for(sub { slurp("$tmp/client.log") =~ /Refusing to fetch from unexpected remote URL for RepoB/ }),
    'server provided remote URL is validated');
ok(!-e "$tmp/fs.updated", 'no fileserver update when the fetch did not happen');

ok(wait_for(sub { slurp("$tmp/client.log") =~ /Re-syncing: sending give-latest/ }), 'periodic re-sync');

# Same client re-connecting replaces its old session
spawn({EX_GITHOOK_CONFIG_FILE => "$tmp/client.pl", GH_WEBSOCKET_SECRET => $ws_secret},
    "$tmp/client2.log", $^X, "$FindBin::Bin/../git-sync-client/update_git_repo.pl");
ok(wait_for(sub { slurp("$tmp/client.log") =~ /Connection closed \(4000 Replaced by a new connection\)/ }),
    'older session of the same client is closed');

my $client_log = slurp("$tmp/client.log");
unlike($client_log, qr/ghs_/, 'token never logged by the client');
unlike(slurp("$tmp/server.log"), qr/ghs_/, 'token never logged by the server');

done_testing;
