package GithubToken;

# Get access token from Github for the give app id using the provided private_key
# This access token is valid for 1 hour, so it gets renewed before 5 minutes
# and gives a new active token

use Moose;
use JSON::WebToken;
use LWP::UserAgent;
use JSON::XS;
use HTTP::Date;
use Fcntl qw(:flock);

has 'private_key_file' => ( is => 'ro', required => 1 );
has 'private_key' => (is => 'rw');
has 'github_app_id' => ( is => 'rw' );
has 'token_file' => ( is => 'rw', default => './github_app_access.token' );
has 'access_token_url' => ( is => 'rw' );
has 'access_token' => ( is => 'rw' );
has 'expire_epoch' => ( is => 'rw' );
has 'force_update' => ( is => 'rw' );
has 'token_last_modified' => ( is => 'rw' );

sub get_access_token {
    my $self = shift;

    $self->access_token_url('https://api.github.com/app/installations/16753352/access_tokens');

    # Get from text file
    $self->read_file;
    if(!$self->force_update and $self->access_token) {

        my $validity = time - (5 * 60);
        if($self->expire_epoch and $self->expire_epoch > $validity) {
            return $self->access_token;
        }
        else {
            print STDERR "Token getting expired, trying to get new token\n";
        }
    }

    my $get_token_url = $self->access_token_url;

    if(!$get_token_url and !$self->github_app_id) {
        die "No access_token_url or github_app_id to fetch access_token\n";
    }

    my $ua = LWP::UserAgent->new();
    $ua->default_header('Authorization' => "Bearer " . $self->get_jwt_token);
    $ua->default_header('Content-Type' => "application/json");

    my $res = $ua->post($get_token_url);

    if (!$res->is_success) {
        my $res_code = $res->code;
        print STDERR "Error: $res_code, for URL: $get_token_url\n";
        return undef;
    }

    my $json_resp = decode_json($res->decoded_content);

    $self->access_token($json_resp->{token});
    $self->expire_epoch(str2time($json_resp->{expires_at}));

    $self->write_file;

    return $self->access_token;
}

sub get_jwt_token {
    my $self = shift;

    my $jwt = JSON::WebToken->encode({
            iss => $self->github_app_id,
            exp => time + (5 * 60),
            iat => time - 60,
        }, $self->get_private_key, "RS256");

    return $jwt;
}

sub get_private_key {
    my $self = shift;

    return $self->private_key if(defined $self->private_key);

    my $key_file = $self->private_key_file;
    open my $F, '<', $key_file or die "Failed to open key file: $!";
    local $/ = undef;
    my $secret = <$F>;
    close $F;
    return $secret;
}

sub read_file {
    my $self = shift;

   return unless(-f $self->token_file);

   my $last_modified = (stat $self->token_file)[9];
   if($self->token_last_modified and $self->token_last_modified eq $last_modified) {
       return;
   }

    open(my $fh, "<", $self->token_file) or die "Can't open token file: $!";
    my $data = <$fh>;
    close $fh;

    my @data = split(',', $data);
    $self->access_token_url($data[0]);
    $self->access_token($data[1]);
    $self->github_app_id($data[2]);
    chomp($data[3]);
    $self->expire_epoch($data[3]);
}

sub write_file {
    my $self = shift;
    my $token = shift;

    open(my $fh, ">", $self->token_file) or die "Can't open token file: $!";

    flock($fh, LOCK_EX) or die "Cannot lock file - $!\n";
    print $fh $self->access_token_url . ',' . $self->access_token . ',' . $self->github_app_id . ',' . $self->expire_epoch . "\n";
    flock($fh, LOCK_UN) or die "Cannot unlock file - $!\n";
}

1;
