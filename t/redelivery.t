use strict;
use warnings;
use Test::More;
use Mojo::File qw(path tempdir);
use Mojo::UserAgent;
use Mojo::Log;
use POSIX qw(strftime);
use Crypt::OpenSSL::RSA;

use FindBin;
use lib "$FindBin::Bin/../lib", "$FindBin::Bin/lib";
use MockApi;

my ($mock, $mock_pid) = MockApi::start();
END { kill('TERM', $mock_pid) if ($mock_pid) }

my $tmp = tempdir;
path("$tmp/app.pem")->spurt(Crypt::OpenSSL::RSA->generate_key(2048)->get_private_key_string);

delete $ENV{GITHUB_TOKEN};
%ENV = (
    %ENV,
    GITHUB_API_URL     => "$mock/gh",
    GITHUB_APP_ID      => 1,
    GITHUB_TOKEN_URL   => "$mock/gh/app/installations/7/access_tokens",
    GITHUB_TOKEN_FILE  => "$tmp/token",
    GITHUB_WEB_HOOK_DB => "$tmp/hook.db",
    HTTP_TIMEOUT       => 5,
);

require Github;
require Store;
require Redelivery;

Store::init_schema();

my $ua = Mojo::UserAgent->new;
sub mock_state { $ua->post("$mock/_state" => json => {@_})->result }
sub mock_reset { $ua->post("$mock/_reset")->result }

sub redelivered {
    return [map { m{/deliveries/(\d+)/attempts$} ? $1 : () }
          map { $_->{failed} ? () : $_->{path} } @{$ua->get("$mock/_calls")->result->json}];
}

sub delivery {
    my ($id, $guid, $code, $ago) = @_;
    return {id => $id, guid => $guid, status_code => $code, event => 'push', action => undef,
        delivered_at => strftime('%Y-%m-%dT%H:%M:%SZ', gmtime(time - ($ago // 60)))};
}

sub row {
    my ($guid) = @_;
    my ($row) = grep { $_->{guid} eq $guid } @{Store::redelivery_list()};
    return $row;
}

sub make_due { Store::dbh()->do(q/UPDATE WebhookRedelivery SET next_attempt_epoch = 0/) }

my $gt = Github->new(private_key_file => "$tmp/app.pem", logger => Mojo::Log->new(level => 'fatal'));
my $rd = Redelivery->new(github => $gt, logger => Mojo::Log->new(level => 'fatal'), max_attempts => 3);

# ---------------------------------------------------------------------------- #
subtest 'failed deliveries are redelivered, delivered ones are not' => sub {
    mock_reset();
    mock_state(
        deliveries => [
            delivery(1, 'A', 502), delivery(2, 'B', 200),
            delivery(3, 'C', 0),   delivery(4, 'C', 200),    # timed out, redelivered fine later
            delivery(5, 'D', 401),
            delivery(6, 'OLD', 500, 9 * 3600),               # before the first scan window
        ]
    );

    is($rd->run, 2, 'two redeliveries');
    is_deeply([sort @{redelivered()}], [1, 5], 'only failed and not yet delivered guids');
    is(row('A')->{attempts}, 1, 'attempt counted');
    ok(row('A')->{next_attempt_epoch} > time + 200, 'next attempt with backoff');
    ok(!row('C'), 'guid with a later success is not pending');
    ok(!row('OLD'), 'deliveries before the scan window are ignored');

    mock_reset();
    is($rd->run, 0, 'nothing due on the next run');
    is_deeply(redelivered(), [], 'no duplicate redelivery');
};

# ---------------------------------------------------------------------------- #
subtest 'redelivery keeps going until delivered' => sub {
    mock_reset();
    mock_state(deliveries => [delivery(7, 'A', 503, 5)]);    # the redelivery failed again
    make_due();

    $rd->run;
    is_deeply([sort @{redelivered()}], [5, 7], 'latest failed delivery of the guid is redelivered');
    is(row('A')->{attempts}, 2, 'attempts keep counting');

    mock_reset();
    mock_state(deliveries => [delivery(8, 'A', 200, 1)]);
    make_due();
    $rd->run;
    ok(!row('A'), 'cleared once delivered');
};

# ---------------------------------------------------------------------------- #
subtest 'max attempts and github rejections' => sub {
    mock_reset();
    make_due();
    $rd->run;
    is(row('D')->{attempts}, 3, 'reached max attempts');

    mock_reset();
    make_due();
    $rd->run;
    is_deeply(redelivered(), [], 'no more attempts after max');

    Store::redelivery_succeeded('D');
    mock_reset();
    mock_state(
        deliveries => [delivery(9, 'E', 500, 1)],
        fail       => {'POST /gh/app/hook/deliveries/9/attempts' => {code => 422, count => 1}},
    );
    $rd->run;
    ok(!row('E'), 'dropped when github rejects the redelivery');

    mock_reset();
    mock_state(
        deliveries => [delivery(10, 'F', 500, 1)],
        fail       => {'POST /gh/app/hook/deliveries/10/attempts' => {code => 503, count => 1}},
    );
    $rd->run;
    is(row('F')->{attempts}, 0, 'kept for retry when github is failing');
    $rd->run;
    is(row('F')->{attempts}, 1, 'redelivered on the next run');
};

done_testing;
