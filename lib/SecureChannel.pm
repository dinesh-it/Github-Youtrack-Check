package SecureChannel;

# Authenticated encryption and challenge-response handshake for the git-sync
# websocket, built only on core Digest::SHA, MIME::Base64 and /dev/urandom.
#
#  - Three independent keys are derived from the shared secret with
#    HMAC-SHA256 and distinct labels (encrypt, mac, auth)
#  - Encryption: HMAC-SHA256 in counter mode as keystream, keyed with the
#    encrypt key and a fresh random 16 byte nonce per message
#  - Encrypt-then-MAC: HMAC-SHA256 over version, nonce and ciphertext, the tag
#    is verified in constant time before anything is decrypted
#
# Wire format: v1.<nonce>.<ciphertext>.<tag> (base64url without padding)

use strict;
use warnings;
use Carp qw(croak);
use Digest::SHA qw(hmac_sha256 hmac_sha256_hex);
use MIME::Base64 qw(encode_base64url decode_base64url);

use constant VERSION           => 'v1';
use constant MIN_SECRET_LENGTH => 32;
use constant NONCE_BYTES       => 16;
use constant TAG_BYTES         => 32;
use constant MAX_MESSAGE_BYTES => 1024 * 1024;

# ============================================================================ #

sub new {
    my ($class, %args) = @_;

    my $secret = $args{secret};
    croak "SecureChannel secret is required\n" if (!defined $secret or !length $secret);

    if (length($secret) < MIN_SECRET_LENGTH) {
        croak "SecureChannel secret must be at least " . MIN_SECRET_LENGTH
          . " characters, generate one with: openssl rand -hex 32\n";
    }

    utf8::encode($secret) if (utf8::is_utf8($secret));

    return bless {
        enc_key  => hmac_sha256('ghyt-ws-v1|encrypt', $secret),
        mac_key  => hmac_sha256('ghyt-ws-v1|mac',     $secret),
        auth_key => hmac_sha256('ghyt-ws-v1|auth',    $secret),
    }, $class;
}

# ============================================================================ #

# Encrypt and authenticate the given byte string
sub seal {
    my ($self, $plaintext) = @_;

    croak "plaintext must be a byte string\n" if (!defined $plaintext or $plaintext =~ /[^\x00-\xFF]/);
    croak "plaintext too large\n" if (length($plaintext) > MAX_MESSAGE_BYTES);
    utf8::downgrade($plaintext);

    my $nonce      = random_bytes(NONCE_BYTES);
    my $ciphertext = $self->_xor_keystream($nonce, $plaintext);
    my $tag        = hmac_sha256(VERSION . $nonce . $ciphertext, $self->{mac_key});

    return join('.', VERSION, map { encode_base64url($_) } ($nonce, $ciphertext, $tag));
}

# ============================================================================ #

# Verify and decrypt a sealed message, returns undef if it is not genuine
sub unseal {
    my ($self, $message) = @_;

    return if (!defined $message or length($message) > 2 * MAX_MESSAGE_BYTES);

    my @parts = split(/\./, $message, -1);
    return if (@parts != 4 or $parts[0] ne VERSION);
    return if (grep { !/\A[A-Za-z0-9_-]*\z/ } @parts[1 .. 3]);

    my ($nonce, $ciphertext, $tag) = map { decode_base64url($_) } @parts[1 .. 3];
    return if (length($nonce) != NONCE_BYTES or length($tag) != TAG_BYTES);

    my $expected = hmac_sha256(VERSION . $nonce . $ciphertext, $self->{mac_key});
    return if (!constant_time_eq($tag, $expected));

    return $self->_xor_keystream($nonce, $ciphertext);
}

# ============================================================================ #

# Handshake: server sends a random challenge, client proves it knows the
# secret by answering with HMAC(auth_key, challenge + context)
sub new_challenge {
    return unpack('H*', random_bytes(32));
}

sub auth_response {
    my ($self, $challenge, $context) = @_;
    $context //= '';
    utf8::encode($context) if (utf8::is_utf8($context));
    return hmac_sha256_hex("ghyt-ws-v1|auth|$challenge|$context", $self->{auth_key});
}

sub verify_auth_response {
    my ($self, $challenge, $context, $response) = @_;
    return 0 if (!defined $challenge or !defined $response or $response !~ /\A[0-9a-f]{64}\z/);
    return constant_time_eq($self->auth_response($challenge, $context), $response);
}

# ============================================================================ #

sub _xor_keystream {
    my ($self, $nonce, $data) = @_;

    my $length  = length($data);
    my $stream  = '';
    my $counter = 0;
    while (length($stream) < $length) {
        $stream .= hmac_sha256($nonce . pack('N', $counter++), $self->{enc_key});
    }

    return $data ^ substr($stream, 0, $length);
}

# ============================================================================ #

sub constant_time_eq {
    my ($x, $y) = @_;
    return 0 if (!defined $x or !defined $y or length($x) != length($y));

    my $diff = 0;
    $diff |= ord(substr($x, $_, 1)) ^ ord(substr($y, $_, 1)) for (0 .. length($x) - 1);
    return $diff == 0;
}

# ============================================================================ #

sub random_bytes {
    my ($count) = @_;

    open(my $fh, '<:raw', '/dev/urandom') or croak "Cannot open /dev/urandom: $!\n";
    my $buf = '';
    while (length($buf) < $count) {
        my $read = sysread($fh, $buf, $count - length($buf), length($buf));
        croak "Cannot read /dev/urandom: $!\n" if (!$read);
    }
    close($fh);

    return $buf;
}

# ============================================================================ #

1;
