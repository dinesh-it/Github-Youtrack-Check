use strict;
use warnings;
use Test::More;
use MIME::Base64 qw(encode_base64url decode_base64url);

use FindBin;
use lib "$FindBin::Bin/..";
use SecureChannel;

my $secret = 'a' x 64;
my $sc     = SecureChannel->new(secret => $secret);

# Round trip
my $plain  = qq/{"project":"PAMS-WWW","token":"ghs_secret"}/;
my $sealed = $sc->seal($plain);
like($sealed, qr/^v1\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/, 'sealed message format');
unlike($sealed, qr/ghs_secret/, 'token is not visible in the sealed message');
is($sc->unseal($sealed), $plain, 'round trip');

# Binary data and empty string
my $bin = join('', map { chr } 0 .. 255) x 5;
is($sc->unseal($sc->seal($bin)), $bin, 'binary round trip spanning many keystream blocks');
is($sc->unseal($sc->seal('')), '', 'empty plaintext round trip');

# Fresh nonce per message
isnt($sc->seal($plain), $sc->seal($plain), 'same plaintext gives different ciphertexts');

# Tampering with any part is rejected
my @parts = split(/\./, $sealed);
for my $i (1 .. 3) {
    my $raw = decode_base64url($parts[$i]);
    substr($raw, 0, 1) = chr(ord(substr($raw, 0, 1)) ^ 1);
    my @copy = @parts;
    $copy[$i] = encode_base64url($raw);
    is($sc->unseal(join('.', @copy)), undef, "bit flip in part $i rejected");
}

is($sc->unseal(join('.', 'v2', @parts[1 .. 3])), undef, 'unknown version rejected');
is($sc->unseal(join('.', @parts[0 .. 2])),       undef, 'missing tag rejected');
is($sc->unseal("$sealed.x"),                     undef, 'extra part rejected');
is($sc->unseal('garbage'),                       undef, 'garbage rejected');
is($sc->unseal(undef),                           undef, 'undef rejected');

# Wrong key
my $other = SecureChannel->new(secret => 'b' x 64);
is($other->unseal($sealed), undef, 'wrong key rejected');

# Secret strength
eval { SecureChannel->new(secret => 'short') };
like($@, qr/at least 32 characters/, 'short secret refused');
eval { SecureChannel->new(secret => '') };
like($@, qr/required/, 'empty secret refused');

# Wide characters must be encoded by the caller
eval { $sc->seal("caf\x{e9} \x{263a}") };
like($@, qr/byte string/, 'wide character plaintext refused');

# Handshake
my $challenge = SecureChannel::new_challenge();
like($challenge, qr/^[0-9a-f]{64}$/, 'challenge format');
isnt($challenge, SecureChannel::new_challenge(), 'challenges are random');

my $response = $sc->auth_response($challenge, 'RepoA,RepoB');
ok($sc->verify_auth_response($challenge, 'RepoA,RepoB', $response), 'valid auth response accepted');
ok(!$sc->verify_auth_response($challenge, 'RepoA,RepoC', $response), 'auth bound to the repo list');
ok(!$sc->verify_auth_response(SecureChannel::new_challenge(), 'RepoA,RepoB', $response), 'auth bound to the challenge');
ok(!$other->verify_auth_response($challenge, 'RepoA,RepoB', $response), 'auth with wrong secret rejected');
ok(!$sc->verify_auth_response($challenge, 'RepoA,RepoB', undef), 'missing response rejected');
ok(!$sc->verify_auth_response($challenge, 'RepoA,RepoB', 'zz'), 'malformed response rejected');

# Auth key differs from message keys
isnt($sc->auth_response($challenge, ''), $sc->auth_response($challenge, ' '), 'context separation');

done_testing;
