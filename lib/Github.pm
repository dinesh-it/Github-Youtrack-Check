package Github;

# GitHub API client for the youtrack check service.
#
# Authenticates either with a personal access token (GITHUB_TOKEN env) or as a
# GitHub App installation. Installation access tokens are valid for 1 hour,
# they are renewed 5 minutes before expiry and shared with the helper scripts
# through the token file.

use Moose;
use JSON::WebToken;
use LWP::UserAgent;
use HTTP::Request;
use HTTP::Response;
use HTTP::Date qw(str2time);
use JSON::XS;
use URI;
use POSIX qw(strftime);
use File::Temp;
use File::Basename qw(dirname);
use Encode qw(decode);

use constant CHECK_NAME => 'ci/chk-youtrack';

has 'private_key_file' => (is => 'ro', required => 1);
has 'private_key'      => (is => 'rw');
has 'github_app_id'    => (is => 'rw');
has 'access_token_url' => (is => 'rw');
has 'access_token'     => (is => 'rw');
has 'expire_epoch'     => (is => 'rw');
has 'force_update'     => (is => 'rw');
has 'token_last_modified' => (is => 'rw');

has 'token_file' => (is => 'rw', default => sub { $ENV{GITHUB_TOKEN_FILE} || '/tmp/github_app_access.token' });
has 'api_url'    => (is => 'ro', default => sub { ($ENV{GITHUB_API_URL} || 'https://api.github.com') =~ s{/+$}{}r });
has 'org'        => (is => 'ro', default => sub { $ENV{GITHUB_ORG} || 'exceleron' });
has 'timeout'    => (is => 'ro', default => sub { $ENV{HTTP_TIMEOUT} || 20 });

# Per repository read only tokens handed to git sync clients
has 'read_only_tokens' => (is => 'ro', default => sub { {} });

has '_private_key_cache' => (is => 'rw');

# Why the last status / check post failed permanently (not retried)
has 'last_post_error' => (is => 'rw');

# ============================================================================ #

has 'logger' => (
    is      => 'rw',
    default => sub {
        require Log::Handler;
        return Log::Handler->new(
            screen => {
                log_to         => "STDOUT",
                maxlevel       => "info",
                minlevel       => "emerg",
                message_layout => "%T [%L] %m",
            }
        );
    }
);

# ============================================================================ #

has 'ua' => (
    is      => 'ro',
    lazy    => 1,
    default => sub {
        my $self = shift;
        my $ua   = LWP::UserAgent->new(timeout => $self->timeout, agent => 'micro-ci-chk-youtrack/2');
        my $base = $self->api_url . '/';

        # Never send credentials outside the API host, including on redirects
        $ua->add_handler(
            request_prepare => sub {
                my ($req) = @_;
                $req->remove_header('Authorization') if (index($req->uri->as_string, $base) != 0);
                return;
            }
        );

        return $ua;
    }
);

# ============================================================================ #

# True when authenticating as a github app (not with a personal access token)
sub is_app {
    my $self = shift;
    return 0 if ($ENV{GITHUB_TOKEN});
    return ($self->private_key_file or defined $self->private_key) ? 1 : 0;
}

# ============================================================================ #

sub get_access_token {
    my $self = shift;

    return $ENV{GITHUB_TOKEN} if ($ENV{GITHUB_TOKEN});

    $self->read_file;
    if ($self->access_token) {
        if ($self->expire_epoch and $self->expire_epoch > time + (5 * 60)) {
            return $self->access_token;
        }
        $self->logger->info("Access token expires soon, getting a new token");
    }

    return $self->refresh_app_token;
}

# ============================================================================ #

sub refresh_app_token {
    my $self = shift;

    my $json = $self->_installation_token_request();
    return if (!$json);

    $self->access_token($json->{token});
    $self->expire_epoch(str2time($json->{expires_at}));
    $self->write_file;

    return $self->access_token;
}

# ============================================================================ #

# Content read only token, scoped to the given repository when one is passed.
# Returns undef when using a personal access token or on failure.
sub get_read_only_access_token {
    my ($self, $repo) = @_;

    return if (!$self->is_app);

    my $key    = $repo // '*';
    my $cached = $self->read_only_tokens->{$key};
    if ($cached and $cached->{expires} > time + (10 * 60)) {
        return $cached->{token};
    }

    # Do not hammer github when a repo is not part of the installation
    if ($cached and $cached->{failed_until} and $cached->{failed_until} > time) {
        return;
    }

    my $body = {permissions => {contents => 'read'}};
    $body->{repositories} = [$repo] if (defined $repo);

    my $json = $self->_installation_token_request($body);
    if (!$json) {
        $self->read_only_tokens->{$key} = {expires => 0, failed_until => time + 300};
        return;
    }

    $self->read_only_tokens->{$key} = {token => $json->{token}, expires => str2time($json->{expires_at}) || 0};

    return $json->{token};
}

# ============================================================================ #

sub _installation_token_request {
    my ($self, $body) = @_;

    $self->read_file;
    my $token_url = $self->access_token_url;

    if (!$token_url) {
        $self->logger->error("GitHub app access token URL is not configured (GITHUB_TOKEN_URL)");
        return;
    }

    my $prefix = $self->api_url . '/app/installations/';
    if (index($token_url, $prefix) != 0 or $token_url !~ m{/app/installations/\d+/access_tokens$}) {
        $self->logger->error("Refusing to use unexpected access token URL: $token_url");
        return;
    }

    my $jwt = eval { $self->get_jwt_token };
    if (!$jwt) {
        $self->logger->error("Failed to create github app JWT: $@");
        return;
    }

    my $req = HTTP::Request->new(POST => $token_url);
    $req->header(Authorization          => "Bearer $jwt");
    $req->header(Accept                 => 'application/vnd.github+json');
    $req->header('X-GitHub-Api-Version' => '2022-11-28');
    if ($body) {
        $req->content_type('application/json');
        $req->content(encode_json($body));
    }

    $self->logger->info("Getting access token via $token_url");
    my $res = $self->ua->request($req);

    if (!$res->is_success) {
        $self->logger->error("Access token request failed: " . $res->status_line . " for URL: $token_url");
        return;
    }

    my $json = eval { decode_json($res->decoded_content) };
    if (!$json or !$json->{token}) {
        $self->logger->error("Invalid access token response from $token_url");
        return;
    }

    return $json;
}

# ============================================================================ #
# GitHub App web hook deliveries (authenticated with the app JWT)
# ============================================================================ #

sub _app_request {
    my ($self, $method, $url) = @_;

    if (!$self->is_app) {
        return _error_response(400, 'Web hook deliveries need github app authentication', 0);
    }

    $self->read_file;
    my $jwt = eval { $self->get_jwt_token };
    return _error_response(500, "Failed to create github app JWT: $@", 0) if (!$jwt);

    my $req = HTTP::Request->new($method => $url);
    $req->header(Authorization          => "Bearer $jwt");
    $req->header(Accept                 => 'application/vnd.github+json');
    $req->header('X-GitHub-Api-Version' => '2022-11-28');

    my $res = $self->ua->request($req);
    if (!$res->is_success) {
        my $msg = substr($res->decoded_content // '', 0, 500);
        $self->logger->error("$method $url failed: " . $res->status_line . " $msg");
    }

    return $res;
}

# ============================================================================ #

# Web hook deliveries of the app delivered at or after $since (epoch), newest
# first. Returns array ref or undef on failure, in list context also whether
# the list was cut at $max_pages (older deliveries not returned).
sub get_hook_deliveries {
    my ($self, $since, $max_pages) = @_;

    $max_pages //= 300;
    my $truncated = 0;
    my $url = _with_query($self->api_path('app', 'hook', 'deliveries'), per_page => 100);
    my @all;

    while ($url) {
        if ($max_pages-- <= 0) {
            $truncated = 1;
            last;
        }

        my $res = $self->_app_request(GET => $url);
        return if (!$res->is_success);

        my $page = $self->_decode($res, $url);
        return if (ref($page) ne 'ARRAY');

        my $older = 0;
        foreach my $delivery (@{$page}) {
            my $at = str2time($delivery->{delivered_at} // '') || 0;
            if ($since and $at < $since) {
                $older = 1;
                next;
            }
            push(@all, $delivery);
        }
        last if ($older);

        $url = undef;
        foreach my $link (split(/,/, $res->header('Link') // '')) {
            $url = $1 if ($link =~ /<([^>]+)>\s*;\s*rel="?next"?/);
        }
        $url = undef if ($url and index($url, $self->api_url . '/') != 0);
    }

    return wantarray ? (\@all, $truncated) : \@all;
}

# ============================================================================ #

# Ask github to deliver the given web hook delivery again
sub redeliver_hook {
    my ($self, $delivery_id) = @_;

    return _error_response(400, 'Invalid delivery id', 0) if (($delivery_id // '') !~ /^\d+$/);

    my $url = $self->api_path('app', 'hook', 'deliveries', $delivery_id, 'attempts');
    return $self->_app_request(POST => $url);
}

# ============================================================================ #

sub get_jwt_token {
    my $self = shift;

    return JSON::WebToken->encode(
        {
            iss => $self->_get_key('github_app_id'),
            exp => time + (5 * 60),
            iat => time - 60,
        },
        $self->get_private_key,
        "RS256"
    );
}

# ============================================================================ #

sub get_private_key {
    my $self = shift;

    return $self->private_key if (defined $self->private_key);
    return $self->_private_key_cache if (defined $self->_private_key_cache);

    my $key_file = $self->_get_key('private_key_file');
    die "ERROR: private_key_file $key_file not found\n" if (!-f $key_file);

    $self->logger->info("Reading github app private key from $key_file");

    open(my $fh, '<', $key_file) or die "ERROR: Failed to open key file: $!\n";
    local $/ = undef;
    my $secret = <$fh>;
    close($fh);

    $self->_private_key_cache($secret);
    return $secret;
}

# ============================================================================ #
# API helpers
# ============================================================================ #

# Make an authenticated API request. Only URLs under api_url are allowed so the
# token can never be sent to another host.
sub request {
    my ($self, $method, $url, $body) = @_;

    if (!defined $url or index($url, $self->api_url . '/') != 0) {
        $self->logger->error("Refusing to call non github API URL: " . ($url // 'undef'));
        return _error_response(400, 'Invalid API URL', 0);
    }

    my $token = $self->get_access_token;
    return _error_response(500, 'No github access token available', 1) if (!$token);

    my $req = HTTP::Request->new($method => $url);
    $req->header(Authorization          => "Bearer $token");
    $req->header(Accept                 => 'application/vnd.github+json');
    $req->header('X-GitHub-Api-Version' => '2022-11-28');

    if (defined $body) {
        $req->content_type('application/json');
        $req->content(encode_json($body));
    }

    my $res = $self->ua->request($req);

    if (!$res->is_success) {
        my $msg = substr($res->decoded_content // '', 0, 500);
        $self->logger->error("$method $url failed: " . $res->status_line . " $msg");
    }

    return $res;
}

# ============================================================================ #

sub _error_response {
    my ($code, $msg, $internal) = @_;
    my $res = HTTP::Response->new($code, $msg);
    $res->header('Client-Warning' => 'Internal response') if ($internal);
    return $res;
}

# ============================================================================ #

# Whether a failed response is worth retrying later
sub is_retryable {
    my ($self, $res) = @_;

    return 0 if ($res->is_success);

    my $code = $res->code;
    return 1 if (($res->header('Client-Warning') // '') eq 'Internal response');
    return 1 if ($code == 408 or $code == 429 or $code >= 500);

    if ($code == 403) {
        return 1 if (($res->header('X-RateLimit-Remaining') // '') eq '0');
        return 1 if (($res->decoded_content // '') =~ /rate limit/i);
    }

    return 0;
}

# ============================================================================ #

sub _decode {
    my ($self, $res, $url) = @_;
    my $data = eval { decode_json($res->decoded_content) };
    $self->logger->error("Invalid JSON response from $url") if (!defined $data);
    return $data;
}

# ============================================================================ #

sub _with_query {
    my ($url, %params) = @_;
    my $uri   = URI->new($url);
    my %query = $uri->query_form;
    @query{keys %params} = values %params;
    $uri->query_form(map { $_ => $query{$_} } sort keys %query);
    return $uri->as_string;
}

# ============================================================================ #

sub api_path {
    my ($self, @segments) = @_;
    my $uri = URI->new($self->api_url);
    $uri->path_segments($uri->path_segments, @segments);
    return $uri->as_string;
}

# ============================================================================ #

# Single GET request, returns the decoded JSON or undef.
# In list context also returns the HTTP::Response.
sub get_api_response {
    my ($self, $url) = @_;

    $self->logger->debug("Calling API: $url");

    my $res  = $self->request(GET => $url);
    my $data = $res->is_success ? $self->_decode($res, $url) : undef;

    return wantarray ? ($data, $res) : $data;
}

# ============================================================================ #

# GET all pages of a list API, returns array ref or undef.
# In list context also returns the last HTTP::Response.
sub get_all_pages {
    my ($self, $url, $max_pages) = @_;

    $max_pages //= 50;
    my $page_url = _with_query($url, per_page => 100);
    my @all;
    my $res;

    while ($page_url) {
        if ($max_pages-- <= 0) {
            $self->logger->warn("Stopped after the max number of pages for $url, the list is incomplete");
            last;
        }

        $res = $self->request(GET => $page_url);
        return wantarray ? (undef, $res) : undef if (!$res->is_success);

        my $data = $self->_decode($res, $page_url);
        if (ref($data) ne 'ARRAY') {
            return wantarray ? (undef, $res) : undef;
        }
        push(@all, @{$data});

        $page_url = undef;
        foreach my $link (split(/,/, $res->header('Link') // '')) {
            if ($link =~ /<([^>]+)>\s*;\s*rel="?next"?/) {
                $page_url = $1;
            }
        }
    }

    return wantarray ? (\@all, $res) : \@all;
}

# ============================================================================ #

# Fetch all commits in the given URL like a pull request commits URL.
# The second argument is a scalar reference which will be set if the failure
# is temporary and the request should be tried again.
sub fetch_all_commits {
    my ($self, $page_url, $no_delete) = @_;

    $self->logger->info("Fetching all commits from: $page_url");

    my ($commits, $res) = $self->get_all_pages($page_url);

    if (!$commits) {
        $$no_delete = 1 if ($no_delete and $res and $self->is_retryable($res));
        return;
    }

    $self->logger->debug("Found " . scalar(@{$commits}) . " commit(s)");
    return $commits;
}

# ============================================================================ #

# Current target of a ref (eg: refs/heads/master), 404 when it does not exist
sub get_ref {
    my ($self, $owner, $repo, $ref) = @_;
    (my $short = $ref) =~ s{^refs/}{};
    return $self->get_api_response($self->api_path('repos', $owner, $repo, 'git', 'ref', split(m{/}, $short)));
}

# ============================================================================ #

sub get_commit {
    my ($self, $owner, $repo, $sha) = @_;
    return $self->get_api_response($self->api_path('repos', $owner, $repo, 'commits', $sha));
}

# ============================================================================ #

sub get_repositories {
    my ($self) = @_;
    return $self->get_all_pages($self->api_path('orgs', $self->org, 'repos'));
}

# ============================================================================ #

sub get_pull_requests {
    my ($self, $repo, $owner) = @_;
    my $url = $self->api_path('repos', $owner // $self->org, $repo, 'pulls');
    return $self->get_all_pages(_with_query($url, state => 'open', sort => 'updated', direction => 'desc'));
}

# ============================================================================ #

sub get_repo_branches {
    my ($self, $repo, $owner) = @_;
    return $self->get_all_pages($self->api_path('repos', $owner // $self->org, $repo, 'branches'));
}

# ============================================================================ #

# Latest state of our check on a commit, returns (state, updated_epoch)
sub get_check_state {
    my ($self, $owner, $repo, $sha, $use_checks_api) = @_;

    if ($use_checks_api) {
        my $url  = $self->api_path('repos', $owner, $repo, 'commits', $sha, 'check-runs');
        my $data = $self->get_api_response(_with_query($url, check_name => CHECK_NAME, filter => 'latest'));
        return ('', 0) if (!$data or ref($data->{check_runs}) ne 'ARRAY');

        my ($latest) = sort { _run_epoch($b) <=> _run_epoch($a) } @{$data->{check_runs}};
        return ('', 0) if (!$latest);

        my $state = $latest->{conclusion} // $latest->{status} // '';
        return ($state, _run_epoch($latest));
    }

    my $statuses = $self->get_api_response($self->api_path('repos', $owner, $repo, 'commits', $sha, 'statuses'));
    return ('', 0) if (ref($statuses) ne 'ARRAY');

    # Statuses are returned in reverse chronological order
    foreach my $st (@{$statuses}) {
        next if (($st->{context} // '') ne CHECK_NAME);
        return ($st->{state} // '', str2time($st->{updated_at} // '') || 0);
    }

    return ('', 0);
}

sub _run_epoch {
    my $run = shift;
    return str2time($run->{completed_at} // $run->{started_at} // '') || 0;
}

# ============================================================================ #

# Post commit status, returns 1 when done (posted or permanently failed) and
# 0 when the update should be retried later
sub post_github_status {
    my ($self, $commit, $status, $link) = @_;

    my $desc = $commit->{desc} // '';
    $desc = decode('UTF-8', $desc, Encode::FB_DEFAULT) if (!utf8::is_utf8($desc));
    $desc =~ s/[^\x20-\x7E]+/?/g;
    $desc = substr($desc, 0, 90) . '...' if (length($desc) > 96);

    my $body = {
        context     => CHECK_NAME,
        description => $desc,
        state       => $status,
    };
    $body->{target_url} = $link if ($link);

    my $url = $self->api_path('repos', $commit->{owner}, $commit->{project}, 'statuses', $commit->{commit_id});

    $self->logger->info("Posting GH status '$status' for: $url");

    my $res = $self->request(POST => $url, $body);
    return 1 if ($res->is_success);

    if ($self->is_retryable($res)) {
        $self->logger->info("Status update will be retried");
        return 0;
    }

    $self->logger->error("Status update for $url failed permanently, will not be retried");
    $self->last_post_error($res->status_line . ' ' . substr($res->decoded_content // '', 0, 200));
    return 1;
}

# ============================================================================ #

sub post_github_check {
    my ($self, $commit, $title, $desc, $status, $conclusion, $link) = @_;

    $title = $title // '';
    $title = substr($title, 0, 250) . '...' if (length($title) > 255);

    my $now  = strftime('%Y-%m-%dT%H:%M:%SZ', gmtime);
    my $body = {
        name     => CHECK_NAME,
        head_sha => $commit->{commit_id},
        status   => $status,
        output   => {
            title   => $title,
            summary => $desc,
        },
    };

    $body->{details_url} = $link if ($link);
    $body->{started_at}  = $now  if ($status eq 'in_progress');

    if ($status eq 'completed') {
        $body->{conclusion}   = $conclusion;
        $body->{completed_at} = $now;
    }

    my $url = $self->api_path('repos', $commit->{owner}, $commit->{project}, 'check-runs');

    $self->logger->info("Posting GH check '$status' for: $url ($commit->{commit_id})");

    my $res = $self->request(POST => $url, $body);
    return 1 if ($res->is_success);

    if ($self->is_retryable($res)) {
        $self->logger->info("Check update will be retried");
        return 0;
    }

    $self->logger->error("Check update for $url failed permanently, will not be retried");
    $self->last_post_error($res->status_line . ' ' . substr($res->decoded_content // '', 0, 200));
    return 1;
}

# ============================================================================ #
# Token file shared with the helper scripts
# Format: access_token_url,access_token,github_app_id,expire_epoch
# ============================================================================ #

sub read_file {
    my $self = shift;

    return if ($self->force_update);

    my $file = $self->token_file;

    if (!-e $file) {
        $self->github_app_id($self->github_app_id // $ENV{GITHUB_APP_ID});
        $self->access_token_url($self->access_token_url // $ENV{GITHUB_TOKEN_URL});
        return;
    }

    my @st = lstat($file);
    if (-l _ or !-f _) {
        $self->logger->error("Ignoring token file $file, it is not a regular file");
        return;
    }

    if ($st[4] != $>) {
        $self->logger->error("Ignoring token file $file, it is not owned by the current user");
        return;
    }

    return if ($self->token_last_modified and $self->token_last_modified == $st[9]);

    if ($st[2] & 0077) {
        $self->logger->warn("Token file $file was accessible by other users, fixing permission");
        chmod(0600, $file);
    }

    $self->logger->info("Reading access_token from $file");

    open(my $fh, '<', $file) or do {
        $self->logger->error("Can't open token file $file: $!");
        return;
    };
    my $data = <$fh> // '';
    close($fh);
    chomp($data);

    my ($url, $token, $app_id, $expiry) = split(/,/, $data, -1);
    if (!$url or !$token or !$expiry or $expiry !~ /^\d+$/) {
        $self->logger->error("Ignoring invalid token file $file");
        return;
    }

    $self->access_token_url($url);
    $self->access_token($token);
    $self->github_app_id($app_id) if ($app_id);
    $self->expire_epoch($expiry);
    $self->token_last_modified($st[9]);
}

# ============================================================================ #

sub write_file {
    my $self = shift;

    my $file = $self->token_file;
    $self->logger->info("Writing access_token to $file");

    # Write to a private temp file and rename, so the token is never readable
    # by others and readers never see a partially written file
    my $ok = eval {
        my $tmp = File::Temp->new(DIR => dirname($file), TEMPLATE => '.ghyt-token-XXXXXX', UNLINK => 1);
        chmod(0600, $tmp->filename);
        print {$tmp} join(',',
            $self->access_token_url // '',
            $self->access_token     // '',
            $self->github_app_id    // '',
            $self->expire_epoch     // 0)
          . "\n";
        $tmp->flush;
        close($tmp) or die "close failed: $!\n";
        rename($tmp->filename, $file) or die "rename failed: $!\n";
        $tmp->unlink_on_destroy(0);
        1;
    };

    if (!$ok) {
        $self->logger->error("Failed to write token file $file: $@");
        return;
    }

    $self->token_last_modified((stat $file)[9]);
    return 1;
}

# ============================================================================ #

sub _get_key {
    my ($self, $key) = @_;
    die "ERROR: Missing $key in Github constructor\n" if (!$self->$key);
    return $self->$key;
}

# ============================================================================ #

__PACKAGE__->meta->make_immutable;

1;
