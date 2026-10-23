package Youtrack;

use Moose;
use LWP::UserAgent;
use JSON::XS qw/decode_json encode_json/;
use URI;

has api_token => (
    is       => 'rw',
    default  => sub { $ENV{YOUTRACK_TOKEN} },
    required => 1,
);

has api_host => (
    is       => 'rw',
    default  => sub { ($ENV{YOUTRACK_HOST} // '') =~ s{/+$}{}r },
    required => 1,
);

# Login of the user owning YOUTRACK_TOKEN, used to find our own comments
has ci_login => (
    is      => 'rw',
    default => sub { $ENV{YOUTRACK_CI_LOGIN} || 'ci' },
);

has timeout => (
    is      => 'ro',
    default => sub { $ENV{HTTP_TIMEOUT} || 20 },
);

has match_key_last_tried => (
    is      => 'rw',
    default => sub { 0 },
);

has youtrack_match_key => (is => 'rw');

has ticket_cache_ttl => (
    is      => 'ro',
    default => sub { 6 * 3600 },
);

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

has ua => (
    is      => 'rw',
    lazy    => 1,
    default => sub {
        my $self = shift;
        my $ua   = LWP::UserAgent->new(timeout => $self->timeout, agent => 'micro-ci-chk-youtrack/2');
        $ua->default_header('Authorization' => "Bearer " . $self->api_token);
        $ua->default_header('Accept'        => 'application/json');
        $ua->default_header('Content-Type'  => 'application/json');

        # Never send the token outside the youtrack host, including on redirects
        my $base = $self->api_host . '/';
        $ua->add_handler(
            request_prepare => sub {
                my ($req) = @_;
                $req->remove_header('Authorization') if (index($req->uri->as_string, $base) != 0);
                return;
            }
        );

        return $ua;
    },
);

# ============================================================================ #

sub _get_api_path {
    my ($self, @path_parts) = @_;
    my $yt = URI->new($self->api_host);
    $yt->path_segments('youtrack', 'api', @path_parts);
    return $yt->as_string;
}

# ============================================================================ #

sub _is_temporary_failure {
    my ($self, $res) = @_;
    my $code = $res->code;
    return 1 if (($res->header('Client-Warning') // '') eq 'Internal response');
    return 1 if ($code == 408 or $code == 429 or $code >= 500);
    return 0;
}

# ============================================================================ #

# GET a collection page by page, returns array ref or undef on failure
sub _get_collection {
    my ($self, $url, $fields) = @_;

    my $top  = 100;
    my $skip = 0;
    my @all;

    for (1 .. 100) {
        my $uri = URI->new($url);
        $uri->query_form(fields => $fields, '$top' => $top, '$skip' => $skip);

        my $res = $self->ua->get($uri->as_string);
        if (!$res->is_success) {
            $self->logger->error("YouTrack request failed: " . $res->status_line . " for URL: $url");
            return;
        }

        my $page = eval { decode_json($res->decoded_content) };
        return if (ref($page) ne 'ARRAY');

        push(@all, @{$page});
        last if (@{$page} < $top);
        $skip += $top;
    }

    return \@all;
}

# ============================================================================ #

# A simple and Basic stub to create a ticket in youtrack
# Note we have to use get_projects to get the project id
# This method needs $project_id, $summary and $description
# as arguments
sub create_ticket {
    my ($self, $proj_id, $summary, $desc) = @_;
    my $url = $self->_get_api_path('issues') . '?fields=numberInProject';

    my $data = {
        project     => {id => $proj_id},
        summary     => $summary,
        description => $desc,
    };

    my $ticket = $self->ua->post($url, Content => encode_json($data));

    if (!$ticket->is_success) {
        $self->logger->error("Creating ticket " . $ticket->status_line);
        return;
    }

    return decode_json($ticket->decoded_content);
}

# ============================================================================ #

sub get_ticket_link {
    my ($self, $ticket_id) = @_;
    my $yt = URI->new($self->api_host);
    $yt->path_segments('youtrack', 'issue', $ticket_id);
    return $yt->as_string;
}

# ============================================================================ #

sub get_ticket_id {
    my ($self, $message) = @_;

    return if (!defined $message);

    my $youtrack_match_key = $self->get_ticket_match_key;

    if ($youtrack_match_key and $message =~ /$youtrack_match_key/i) {
        return uc($1);
    }

    # Probably new project added so lets update our list and try one more time
    if ($message =~ /[A-Z0-9]-\d+/i) {
        $youtrack_match_key = $self->get_ticket_match_key(1);

        if ($youtrack_match_key and $message =~ /$youtrack_match_key/i) {
            return uc($1);
        }
    }

    return;
}

# ============================================================================ #

sub get_projects {
    my $self = shift;

    $self->logger->info("Getting projects list from youtrack");

    my $projects = $self->_get_collection($self->_get_api_path('admin', 'projects'), 'shortName');
    die "Failed to get youtrack project list\n" if (!$projects);

    return $projects;
}

# ============================================================================ #

sub get_ticket_match_key {
    my ($self, $fetch_new) = @_;

    my $youtrack_match_key = $self->youtrack_match_key;

    if (!$fetch_new and $youtrack_match_key) {
        return $youtrack_match_key;
    }

    # Avoid trying again and again in a loop - try again only after 5 mins
    if ($youtrack_match_key and $self->match_key_last_tried > (time - (60 * 5))) {
        return $youtrack_match_key;
    }

    $self->match_key_last_tried(time);

    my $projects = eval { $self->get_projects() };
    if (!$projects) {
        # Keep using the old list when youtrack is not reachable
        return $youtrack_match_key if ($youtrack_match_key);
        die $@ || "Failed to fetch youtrack projects\n";
    }

    # Build reg ex, longest codes first
    # eg: ((?:CLUSTER|DSP|OPS|P3|MA)-\d+)
    my @proj_codes = sort { length($b) <=> length($a) or $a cmp $b }
      grep { defined and length } map { $_->{shortName} } @{$projects};

    if (!@proj_codes) {
        return $youtrack_match_key if ($youtrack_match_key);
        die "ERROR: Failed to fetch project details, empty list received!\n";
    }

    my $reg_ex = '((?:' . join('|', map { quotemeta } @proj_codes) . ')-\d+)';
    $self->logger->info("Ticket match key: $reg_ex");

    $self->youtrack_match_key($reg_ex);

    return $reg_ex;
}

# ============================================================================ #

my $verified_tickets = {};

# Returns the ticket hash, undef if the ticket does not exist or
# { Link => 'WAIT' } if youtrack is temporarily not available
sub get_ticket {
    my ($self, $ticket_id) = @_;

    return if (!$ticket_id);

    my $cached = $verified_tickets->{$ticket_id};
    if ($cached and $cached->{_cached_at} > time - $self->ticket_cache_ttl) {
        return $cached;
    }

    my $url    = $self->_get_api_path('issues', $ticket_id) . '?fields=idReadable,numberInProject,summary';
    my $ticket = $self->ua->get($url);

    if (!$ticket->is_success) {
        my $status_code = $ticket->code;
        $self->logger->error("YouTrack request Error: " . $ticket->status_line . " Failed URL: $url");
        die "YouTrack token is invalid or expired, please check YOUTRACK_TOKEN\n" if ($status_code == 401);

        if ($self->_is_temporary_failure($ticket)) {
            $self->logger->info("$url will be retried again");
            return {Link => "WAIT"};
        }

        delete $verified_tickets->{$ticket_id};
        return;
    }

    my $data = eval { decode_json($ticket->decoded_content) };
    if (ref($data) ne 'HASH') {
        $self->logger->error("Invalid youtrack response for $url, will be retried");
        return {Link => "WAIT"};
    }

    $data->{Link}       = $self->get_ticket_link($ticket_id);
    $data->{_cached_at} = time;
    $verified_tickets->{$ticket_id} = $data;

    return $data;
}

# ============================================================================ #

my $comments_added = {};

sub add_pr_link_to_comment {
    my ($self, $ticket_id, $pr_link) = @_;

    return if (!$pr_link or !$ticket_id);

    my $cache_key = "$ticket_id-$pr_link";
    return if ($comments_added->{$cache_key});

    my $comments = $self->get_ticket_comments($ticket_id);
    return if (!$comments);

    # Exact link match, so pull/12 is not considered present because of pull/123
    my $link_re = qr/\Q$pr_link\E(?!\d)/;

    my @ci_comments;
    foreach my $c (@{$comments}) {
        next if ($c->{deleted});

        my $login = ($c->{author} // {})->{login} // '';
        if ($login eq $self->ci_login) {
            push(@ci_comments, $c);
        }
        elsif (($c->{text} // '') =~ $link_re) {
            $comments_added->{$cache_key} = 1;
            return;
        }
    }

    my $comment      = $ci_comments[-1];
    my $comment_text = 'Pull Request(s) - Github commit mentions';
    my $comment_id;

    if ($comment && $comment->{id}) {
        $comment_id   = $comment->{id};
        $comment_text = $comment->{text} // $comment_text;

        if ($comment_text =~ $link_re) {
            $comments_added->{$cache_key} = 1;
            return;
        }
    }

    $comment_text .= "\n$pr_link";

    if ($self->add_update_comment($comment_text, $ticket_id, $comment_id)) {
        $comments_added->{$cache_key} = 1;
    }
}

# ============================================================================ #

# Add comment to a ticket. This method will try to update the
# existing comment if third argument comment_id is mentiond
sub add_update_comment {
    my ($self, $comment_text, $ticket_id, $comment_id) = @_;

    my @path_seg = ("issues", $ticket_id, "comments");
    push(@path_seg, $comment_id) if ($comment_id);

    my $url = $self->_get_api_path(@path_seg) . '?fields=id,author,text';

    my $res = $self->ua->post($url, Content => encode_json({text => $comment_text}));

    if (!$res->is_success) {
        $self->logger->error("Failed to add/update comment on $ticket_id: " . $res->status_line);
        return;
    }

    return 1;
}

# ============================================================================ #

# Get youtrack comments for the given ticket id
sub get_ticket_comments {
    my ($self, $ticket_id) = @_;
    return $self->_get_collection($self->_get_api_path('issues', $ticket_id, 'comments'),
        'id,author(login),text,deleted');
}

# ============================================================================ #

__PACKAGE__->meta->make_immutable;

1;
