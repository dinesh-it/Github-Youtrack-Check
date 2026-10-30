package MockApi;

# Mock GitHub (under /gh) and YouTrack (under /youtrack) APIs, served from a
# forked process so the blocking LWP clients of the service can reach it.
# Fixtures are set with POST /_state and recorded calls read with GET /_calls.

use strict;
use warnings;
use Mojolicious::Lite;
use Mojo::Server::Daemon;
use Mojo::IOLoop::Server;
use Mojo::UserAgent;
use POSIX qw(strftime);

my %state;
my @calls;

sub reset_state {
    %state = (
        repos        => [],
        pulls        => {},
        pull_lists   => {},
        commits      => {},
        statuses     => {},
        branches     => {},
        tickets      => {'OPS-1' => 'Fix login', 'OPS-2' => 'Add report', 'OPS-3' => 'Fix sync', 'CLUSTER-9' => 'Deploy release'},
        fail         => {},
        comments     => {},
        deliveries   => [],
        hooks        => ['192.30.252.0/22', '185.199.108.0/22', '140.82.112.0/20', '143.55.64.0/20', '9.234.98.160/28', '2a0a:a440::/29'],
        refs         => {},
    );
    @calls = ();
}
reset_state();

sub iso { strftime('%Y-%m-%dT%H:%M:%SZ', gmtime(shift // time)) }

sub record {
    my ($c, %extra) = @_;
    push(@calls, {method => $c->req->method, path => $c->req->url->path->to_string, body => $c->req->json, %extra});
}

# Respond with a configured failure for "METHOD path" if any (count limited)
sub maybe_fail {
    my ($c) = @_;
    my $key  = $c->req->method . ' ' . $c->req->url->path->to_string;
    my $fail = $state{fail}{$key} or return 0;
    return 0 if ($fail->{count} <= 0);
    $fail->{count}--;
    record($c, failed => $fail->{code});
    $c->render(json => {message => 'mock failure'}, status => $fail->{code});
    return 1;
}

post '/_state' => sub {
    my $c = shift;
    my $data = $c->req->json;
    $state{$_} = $data->{$_} for (keys %{$data});
    $c->render(json => {ok => 1});
};

post '/_reset' => sub { reset_state(); shift->render(json => {ok => 1}) };
get '/_calls'  => sub { shift->render(json => \@calls) };

# --- GitHub ---

post '/gh/app/installations/:id/access_tokens' => sub {
    my $c = shift;
    return if maybe_fail($c);
    record($c, auth => $c->req->headers->authorization);
    my $body  = $c->req->json // {};
    my $token = $body->{repositories} ? 'ghs_ro_' . join('_', @{$body->{repositories}}) : ($body->{permissions} ? 'ghs_ro_all' : 'ghs_full');
    $c->render(json => {token => $token, expires_at => iso(time + 3600)}, status => 201);
};

get '/gh/app/hook/deliveries' => sub {
    my $c = shift;
    return if maybe_fail($c);
    record($c, auth => $c->req->headers->authorization);
    $c->render(json => [sort { $b->{id} <=> $a->{id} } @{$state{deliveries}}]);
};

post '/gh/app/hook/deliveries/:id/attempts' => sub {
    my $c = shift;
    return if maybe_fail($c);
    record($c, auth => $c->req->headers->authorization);
    $c->render(json => {}, status => 202);
};

get '/gh/meta' => sub { my $c = shift; return if maybe_fail($c); $c->render(json => {hooks => $state{hooks}}) };

get '/gh/orgs/:org/repos' => sub { my $c = shift; return if maybe_fail($c); $c->render(json => $state{repos}) };

get '/gh/repos/:o/:r/pulls' => sub {
    my $c = shift;
    return if maybe_fail($c);
    $c->render(json => $state{pull_lists}{$c->param('r')} // []);
};

get '/gh/repos/:o/:r/pulls/:n' => sub {
    my $c = shift;
    return if maybe_fail($c);
    my $pr = $state{pulls}{$c->param('r') . '#' . $c->param('n')};
    return $c->render(json => {message => 'Not Found'}, status => 404) if (!$pr);
    $c->render(json => $pr);
};

get '/gh/repos/:o/:r/pulls/:n/commits' => sub {
    my $c = shift;
    return if maybe_fail($c);
    my $list = $state{commits}{$c->param('r') . '#' . $c->param('n')};
    return $c->render(json => {message => 'Not Found'}, status => 404) if (!$list);
    $c->render(json => $list);
};

get '/gh/repos/:o/:r/git/ref/*ref' => sub {
    my $c   = shift;
    my $sha = $state{refs}{$c->param('r') . ':refs/' . $c->param('ref')};
    return $c->render(json => {message => 'Not Found'}, status => 404) if (!$sha);
    $c->render(json => {ref => 'refs/' . $c->param('ref'), object => {sha => $sha, type => 'commit'}});
};

get '/gh/repos/:o/:r/branches' => sub {
    my $c = shift;
    $c->render(json => $state{branches}{$c->param('r')} // []);
};

get '/gh/repos/:o/:r/commits/:sha' => sub {
    my $c = shift;
    return if maybe_fail($c);
    my $commit = $state{single_commits}{$c->param('sha')};
    return $c->render(json => {message => 'Not Found'}, status => 404) if (!$commit);
    $c->render(json => $commit);
};

get '/gh/repos/:o/:r/commits/:sha/statuses' => sub {
    my $c = shift;
    $c->render(json => $state{statuses}{$c->param('sha')} // []);
};

post '/gh/repos/:o/:r/statuses/:sha' => sub {
    my $c = shift;
    return if maybe_fail($c);
    record($c, auth => $c->req->headers->authorization);
    $c->render(json => {id => 1}, status => 201);
};

post '/gh/repos/:o/:r/check-runs' => sub {
    my $c = shift;
    return if maybe_fail($c);
    record($c);
    $c->render(json => {id => 1}, status => 201);
};

# --- YouTrack ---

get '/youtrack/api/admin/projects' => sub {
    my $c = shift;
    my $skip = $c->param('$skip') // 0;
    my @all  = map { {shortName => $_} } qw(OPS CLUSTER P3 SP);
    $c->render(json => $skip ? [] : \@all);
};

get '/youtrack/api/issues/:id' => sub {
    my $c = shift;
    return if maybe_fail($c);
    my $summary = $state{tickets}{$c->param('id')};
    return $c->render(json => {error => 'Not Found'}, status => 404) if (!defined $summary);
    $c->render(json => {idReadable => $c->param('id'), summary => $summary});
};

get '/youtrack/api/issues/:id/comments' => sub {
    my $c = shift;
    my $skip = $c->param('$skip') // 0;
    $c->render(json => $skip ? [] : ($state{comments}{$c->param('id')} // []));
};

post '/youtrack/api/issues/:id/comments' => sub {
    my $c = shift;
    record($c);
    $c->render(json => {id => '1-1'});
};

post '/youtrack/api/issues/:id/comments/:cid' => sub {
    my $c = shift;
    record($c);
    $c->render(json => {id => $c->param('cid')});
};

# ============================================================================ #

# Start the mock in a child process, returns (base_url, pid)
sub start {

    # Tests must never reach a real service through the caller's environment
    delete @ENV{grep {/^(YOUTRACK_|GITHUB_|GH_)/} keys %ENV};

    my $port = Mojo::IOLoop::Server->generate_port;
    my $pid  = fork() // die "fork failed: $!";

    if (!$pid) {
        app->log->level('fatal');
        my $daemon = Mojo::Server::Daemon->new(app => app, listen => ["http://127.0.0.1:$port"], silent => 1);
        $daemon->run;
        exit 0;
    }

    my $base = "http://127.0.0.1:$port";
    my $ua   = Mojo::UserAgent->new;
    for (1 .. 50) {
        my $res = eval { $ua->get("$base/_calls")->result };
        return ($base, $pid) if ($res and $res->is_success);
        select(undef, undef, undef, 0.1);
    }

    die "Mock API did not start\n";
}

1;
