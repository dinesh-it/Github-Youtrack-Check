package Github;

# Get access token from Github for the give app id using the provided private_key
# This access token is valid for 1 hour, so it gets renewed before 5 minutes
# and gives a new active token

use Moose;
use JSON::WebToken;
use LWP::UserAgent;
use JSON::XS;
use HTTP::Date;
use Fcntl qw(:flock);
use URI::Builder;
use Data::Dumper;

has 'private_key_file' => ( is => 'ro', required => 1 );
has 'private_key' => (is => 'rw');
has 'github_app_id' => ( is => 'rw' );
has 'token_file' => ( is => 'rw', default => '/tmp/github_app_access.token' );
has 'access_token_url' => ( is => 'rw' );
has 'access_token' => ( is => 'rw' );
has 'expire_epoch' => ( is => 'rw' );
has 'force_update' => ( is => 'rw' );
has 'token_last_modified' => ( is => 'rw' );
has 'read_only_token' => ( is => 'rw' );
has 'read_only_token_expiry' => ( is => 'rw' );

# ============================================================================ #

has 'logger' => ( is => 'rw', default => sub {
        require 'Log::Handler';
        my $log = Log::Handler->new(
            screen => {
                log_to   => "STDOUT",
                maxlevel => "debug",
                minlevel => "debug",
                message_layout => "%T [%L] %m",
            }
        );

        return $log;
    });

# ============================================================================ #

has 'ua' => (
    is => 'rw',
    default => sub {
        my $self = shift;
        my $gh_token = $self->get_access_token;
        my $ua = LWP::UserAgent->new;
        $ua->default_header('Authorization' => "Bearer $gh_token");
        $ua->default_header('Accept'        => 'application/json');
        $ua->default_header('Content-Type'  => 'application/json');
        return $ua;

    },
    lazy => 1,
);

# ============================================================================ #

sub get_access_token {
    my $self = shift;

    if($ENV{GITHUB_TOKEN}) {
        return $ENV{GITHUB_TOKEN};
    }

    # Get from text file
    $self->read_file;
    if($self->access_token) {
        my $validity = time + (2 * 60);
        if($self->expire_epoch and $self->expire_epoch > $validity) {
            return $self->access_token;
        }
        else {
            $self->logger->info("Token expired, trying to get new token");
        }
    }

    my $get_token_url = $self->_get_key('access_token_url');

    my $ua = LWP::UserAgent->new();
    $ua->default_header('Authorization' => "Bearer " . $self->get_jwt_token);
    $ua->default_header('Content-Type' => "application/json");

    $self->logger->info("Getting access_token via $get_token_url");
    my $res = $ua->post($get_token_url);

    if (!$res->is_success) {
        my $res_code = $res->code;
        $self->log->error("$res_code, for URL: $get_token_url");
        return;
    }

    my $json_resp = decode_json($res->decoded_content);

    $self->access_token($json_resp->{token});
    $self->expire_epoch(str2time($json_resp->{expires_at}));

    $self->write_file;

    return $self->access_token;
}

# ============================================================================ #

# Fetch all commits in the given URL like a PULL Request URL
# The second argument no_delete is a scalar reference which will be
# set if the is a comunication failure with github
sub fetch_all_commits {
    my ($self, $page_url, $no_delete) = @_;

    my $ua = $self->ua;

    $self->logger->info("Fetching all commits from: $page_url");

    my @all_commits;
    while ($page_url) {

        my $gh = URI::Builder->new(uri => $page_url);
        $gh->query_param(per_page => 100);

        my $res      = $ua->get($gh->as_string);
        my $res_code = $res->code;

        if (!$res->is_success) {
            $self->logger->error("$res_code, for URL: $page_url");
            if ($res_code == 408 || $res->status_line =~ /Can't connect to api.github.com/i) {
                $$no_delete = 1;
            }
            return;
        }

        my $links_hdr = $res->header('Link');

        $page_url = undef;
        if ($links_hdr) {
            my $last_page;
            my @links = split(',', $links_hdr);
            foreach my $link (@links) {
                if ($link =~ /rel=.next/) {
                    ($page_url) = ($link =~ /<(.+?)>/);
                }
            }
        }

        my $resp_body = $res->decoded_content;
        my $resp_ref  = decode_json($resp_body);
        push(@all_commits, @{$resp_ref});
    }

    my $count = scalar(@all_commits);
    $self->logger->debug("Found $count commit(s)");

    return \@all_commits;
}

# ============================================================================ #

sub get_api_response {
    my ($self, $page_url) = @_;
    my $ua = $self->ua;

    $self->logger->debug("Calling API: $page_url");

    my $res = $ua->get($page_url);

    if (!$res->is_success) {
        $self->logger->error($res->status_line . " for URL: $page_url");
        $self->logger->error(Dumper($res->decoded_content));
        return;
    }

    return decode_json($res->decoded_content);
}

# ============================================================================ #

# Get Repositories and its status limited to 100 responses in one page
sub get_repositories {
    my ($self) = @_; 

    my $page_url = 'https://api.github.com/orgs/exceleron/repos?per_page=100';

    return $self->get_api_response($page_url);
}

# ============================================================================ #

# Get Pull requests for the given repo and its status limited to 100 responses in one page
sub get_pull_requests {
    my ($self, $repo) = @_; 

    my $page_url = "https://api.github.com/repos/exceleron/$repo/pulls?per_page=100";

    return $self->get_api_response($page_url);
}

# ============================================================================ #

sub get_repo_branches {
    my ($self, $repo) = @_;

    my $page_url = "https://api.github.com/repos/exceleron/$repo/branches";

    return $self->get_api_response($page_url);
}

# ============================================================================ #

sub post_github_status {
    my ($self, $commit, $status, $link) = @_;

    my $ua = $self->ua;

    my $resp_body = {
        "context"     => "ci/chk-youtrack",
        "description" => $commit->{desc},
        "state"       => $status,
    };

    # Description has limit on number of characters
    if(length($resp_body->{description}) > 96) {
        $resp_body->{description} = substr( $resp_body->{description}, 0, 90 ) . '...';
    }

    if ($link) {
        $resp_body->{target_url} = $link;
    }

    my $commit_hash = $commit->{commit_id};
    my $gh_owner = $commit->{owner};
    my $gh_repo = $commit->{project};

    #my $gh_url = 'https://api.github.com/repos/:owner/:repo/statuses/:sha';
    my $gh = URI::Builder->new(uri => 'https://api.github.com');

    $gh->path_segments("repos", $gh_owner, $gh_repo, "statuses", $commit_hash);

    my $gh_url = $gh->as_string;

    $self->logger->info("Posting GH Status for: $gh_url");

    my $req = HTTP::Request->new(POST => $gh_url);
    $req->content_type('application/json');
    $req->content(encode_json($resp_body));

    my $res = $ua->request($req);

    my $res_code = $res->code;

    if (!$res->is_success) {
        $self->log->error("Error updating status for: $gh_url");
        $self->log->error($res->decoded_content);

        # Re-try only if the request timed out or internet issue
        if ($res_code != 408 and $res->status_line !~ /Can't connect to/i) {
            $self->logger->info("This status update will not be re-tried");
            return 1;
        }
        return 0;
    }

    return 1;
}

# ============================================================================ #

sub post_github_check {
    my ($self, $commit, $title, $desc, $status, $conclusion, $link) = @_;

    my $commit_hash = $commit->{commit_id};
    my $gh_owner    = $commit->{owner};
    my $gh_repo     = $commit->{project};

    my $body = {
        name => 'ci/chk-youtrack',
        head_sha => $commit_hash,
        status => $status,
        output => {
            title => $title,
            summary => $desc,
        },
    };

    $body->{details_url} = $link if($link);

    if($status eq 'in_progress') {
        my $now = DateTime->now;
        $body->{started_at} = $now . 'Z';
    }

    if($status eq 'completed') {
        my $now = DateTime->now;
        $body->{conclusion} = $conclusion;
        $body->{completed_at} = $now . 'Z';
    }

    my $ua = $self->ua;

    # https://api.github.com/repos/dinesh-it/APIAutomation/check-runs
    my $gh = URI::Builder->new(uri => 'https://api.github.com');
    $gh->path_segments("repos", $gh_owner, $gh_repo, "check-runs");
    my $gh_url = $gh->as_string;

    $self->logger->info("Posting GH Checks for: $gh_url");

    my $json_body = encode_json($body);
    my $res = $ua->post($gh_url, Content => $json_body);
    my $res_code = $res->code;

    if (!$res->is_success) {
        $self->log->error("Error updating status for: $gh_url");
        $self->log->error($res->decoded_content);

        # Re-try only if the request timed out or internet issue
        if ($res_code != 408 and $res->status_line !~ /Can't connect to/i) {
            $self->logger->info("This check update will not be re-tried");
            return 1;
        }
        return 0;
    }

    return 1;
}

# ============================================================================ #

sub get_read_only_access_token {
    my $self = shift;

    # Get other details from text file
    $self->read_file;

    my $get_token_url = $self->_get_key('access_token_url');

    my $ua = LWP::UserAgent->new();
    $ua->default_header('Authorization' => "Bearer " . $self->get_jwt_token);
    $ua->default_header('Content-Type' => "application/json");

    my $body = {
        permissions => {
            contents => 'read'
        }
    };

    $self->logger->info("Getting content read only access_token via $get_token_url");
    my $res = $ua->post($get_token_url, Content => encode_json($body) );

    if (!$res->is_success) {
        my $res_code = $res->code;
        $self->log->error("$res_code, for URL: $get_token_url");
        return undef;
    }

    my $json_resp = decode_json($res->decoded_content);

    $self->read_only_token($json_resp->{token});
    $self->logger->info("NEW RO TOKEN: " . $self->read_only_token);
    $self->read_only_token_expiry(str2time($json_resp->{expires_at}));

    return $self->read_only_token;
}

# ============================================================================ #

sub get_jwt_token {
    my $self = shift;

    my $jwt = JSON::WebToken->encode({
            iss => $self->_get_key('github_app_id'),
            exp => time + (5 * 60),
            iat => time - 60,
        }, $self->get_private_key, "RS256");

    return $jwt;
}

# ============================================================================ #

sub get_private_key {
    my $self = shift;

    return $self->private_key if(defined $self->private_key);

    my $key_file = $self->_get_key('private_key_file');

    unless(-f $key_file) {
        die "ERROR: private_key_file $key_file not found\n";
    }

    $self->logger->info("Reading secret from file $key_file");

    open my $F, '<', $key_file or die "ERROR: Failed to open key file: $!";
    local $/ = undef;
    my $secret = <$F>;
    close $F;
    return $secret;
}

# ============================================================================ #
# ============================================================================ #

sub read_file {
    my $self = shift;

    return if($self->force_update);

    if(!-f $self->token_file) {
        $self->github_app_id($ENV{GITHUB_APP_ID});
        $self->access_token_url($ENV{GITHUB_TOKEN_URL});
        return;
    }

    return unless(-f $self->token_file);

    my $last_modified = (stat $self->token_file)[9];
    if($self->token_last_modified and $self->token_last_modified eq $last_modified) {
        return;
    }

    $self->logger->info("Reading access_token from " . $self->token_file);

    open(my $fh, "<", $self->token_file) or die "ERROR: Can't open token file: $!";
    my $data = <$fh>;
    close $fh;

    my @data = split(',', $data);
    $self->access_token_url($data[0]);
    $self->access_token($data[1]);
    $self->github_app_id($data[2]);
    chomp($data[3]);
    $self->expire_epoch($data[3]);
    $self->token_last_modified((stat $self->token_file)[9]);
}

# ============================================================================ #

sub write_file {
    my $self = shift;
    my $token = shift;

    $self->logger->info("Writing access_token to " . $self->token_file);

    open(my $fh, ">", $self->token_file) or die "ERROR: Can't open token file: $!";

    flock($fh, LOCK_EX) or die "ERROR: Cannot lock file - $!\n";
    print $fh $self->access_token_url . ',' . $self->access_token . ',' . $self->github_app_id . ',' . $self->expire_epoch . "\n";
    flock($fh, LOCK_UN) or die "ERROR: Cannot unlock file - $!\n";

    chmod oct('0600'), $self->token_file;
}

# ============================================================================ #

sub _get_key {
    my ($self, $key) = @_;

    unless($self->$key) {
        die "ERROR: Missing $key in Github constructor\n";
    }

    return $self->$key;
}

# ============================================================================ #
# ============================================================================ #

1;
