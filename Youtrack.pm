package Youtrack;

use Moose;
use LWP::UserAgent;
use JSON qw/decode_json encode_json/;
use URI::Builder;

has api_token => (
    is => 'rw',
    default => sub { $ENV{YOUTRACK_TOKEN} },
    required => 1,
);

has api_host => (
    is => 'rw',
    default => sub { $ENV{YOUTRACK_HOST} },
    required => 1,
);

has match_key_last_tried => (
    is => 'rw',
    default => sub { 0 },
);

has youtrack_match_key => (
    is => 'rw',
);

# ============================================================================ #

has 'logger' => ( is => 'rw', default => sub {
        require Log::Handler;
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

has ua => (
    is => 'rw',
    default => sub {
        my $self = shift;
        my $ua = LWP::UserAgent->new();
        $ua->default_header('Authorization' => "Bearer " . $self->api_token);
        $ua->default_header('Accept'        => 'application/json');
        $ua->default_header('Content-Type'  => 'application/json');
        return $ua;
    },
    lazy => 1,
);

# ============================================================================ #

sub _get_api_path {
    my ($self, @path_parts) = @_;
    my $host = $self->api_host;

    my $yt = URI::Builder->new(uri => $host);
    $yt->path_segments('youtrack', 'api', @path_parts);
    $yt->as_string;
}

# ============================================================================ #

# A simple and Basic stub to create a ticket in youtrack
# Note we have to use get_projects to get the project id
# This method needs $project_id, $summary and $description
# as arguments
sub create_ticket {
    my ($self, $proj_id, $summary, $desc) = @_;
    my $url = $self->_get_api_path('issues');
    $url .= '?fields=numberInProject';
    my $ua = $self->ua;

    my $data = {
        project => {
            id => $proj_id,
        },
        summary => $summary,
        description => $desc,
    };

    my $ticket = $ua->post($url, fields => 'numberInProject', Content => encode_json($data) );

    if(!$ticket->is_success) {
        $self->logger->error("Creating ticket " . $ticket->status_line);
        return;
    }

    return decode_json($ticket->decoded_content);
}

# ============================================================================ #

sub get_ticket_link {
    my ($self, $ticket_id) = @_;
    my $host = $self->api_host;

    my $yt = URI::Builder->new(uri => $host);
    $yt->path_segments('youtrack', 'issue', $ticket_id);
    $yt->as_string;
}

# ============================================================================ #

sub get_ticket_id {
    my ($self, $message) = @_;

    my $youtrack_match_key = $self->get_ticket_match_key;

    if ($message =~ /$youtrack_match_key/i) {
        return uc($1);
    }

    # Probably new project added so lets update our list and try one more time
    if($message =~ /[A-Z0-9]-\d+/) {
        $youtrack_match_key = $self->get_ticket_match_key(1);

        if ($message =~ /$youtrack_match_key/i) {
            return uc($1);
        }
    }

    return;
}

# ============================================================================ #

sub get_projects {
    my $self = shift;

    $self->logger->info("Getting projects list from youtrack");

    my $ua = $self->ua;
    my $yt = $self->_get_api_path('admin', 'projects');

    my $res = $ua->get($yt . '?fields=shortName');

    if(!$res->is_success) {
        $self->logger->error("Status - " . $res->status_line);
        die "Failed to get project ID's\n";
    }

    return decode_json($res->decoded_content);
}

# ============================================================================ #

sub get_ticket_match_key {
    my ($self, $fetch_new) = shift;

    my $match_key_last_tried = $self->match_key_last_tried;
    my $youtrack_match_key = $self->youtrack_match_key;

    if(!$fetch_new and $youtrack_match_key) {
        return $youtrack_match_key;
    }

    # Avoid trying again and again in a loop - try again only after 5 mins
    if($match_key_last_tried and $match_key_last_tried > (time - (60 * 5))) {
        return $youtrack_match_key;
    }

    my $projects = $self->get_projects();

    # Build reg ex
    # eg: ((?:P3|P2|MA|DSP|OPS)-\d+)

    my @proj_codes;
    foreach (@{$projects}) {
        push(@proj_codes, $_->{shortName});
    }

    if(!@proj_codes) {
        die "ERROR: Failed to fetch project details, empty list received!\n";
    }

    my $reg_ex = '((?:' . join('|', @proj_codes) . ')-\d+)';
    $self->logger->info("Ticket match key: $reg_ex");

    $self->match_key_last_tried(time);
    $self->youtrack_match_key($reg_ex);

    return $reg_ex;
}

# ============================================================================ #

my $verified_tickets = {};
sub get_ticket {
    my ($self, $ticket_id) = @_;

    return if (!$ticket_id);

    if (exists $verified_tickets->{$ticket_id}) {
        return $verified_tickets->{$ticket_id};
    }

    my $ua = $self->ua;
    my $yt_link = $self->_get_api_path('issues', $ticket_id);
    my $ticket_fields = 'fields=numberInProject,summary';
    my $url = $yt_link . "?$ticket_fields";

    my $ticket = $ua->get($url);

    if (!$ticket->is_success) {
        my $status_code = $ticket->code;
        $self->log->error("YouTrack request Error: $status_code :" . $ticket->status_line);
        $self->log->error("Failed URL: $url");
        die "Please check the token\n" if ($status_code == 401);

        if($status_code == 502) {
            die "Received 502, lets die and see if it works after the service restart\n";
        }

        if ($status_code == 408 || $status_code == 503 || $ticket->status_line =~ /Can't connect to/i || $ticket->status_line =~ /Time-out/i) {
            $self->logger->info("$url will be retried again");
            return { Link => "WAIT" }; 
        }

        delete $verified_tickets->{$ticket_id};
        return;
    }

    my $ticket_link = $self->get_ticket_link($ticket_id);
    $verified_tickets->{$ticket_id} = decode_json($ticket->decoded_content);
    $verified_tickets->{$ticket_id}->{Link} = $ticket_link;

    return $verified_tickets->{$ticket_id};
}

# ============================================================================ #

my $comments_added = {};
sub add_pr_link_to_comment {
    my ($self, $ticket_id, $pr_link) = @_;

    return if(!$pr_link);

    return if($comments_added->{"$ticket_id-$pr_link"});

    my $comments = $self->get_ticket_comments($ticket_id);
    my @ci_comments;

    foreach my $c (@{$comments}) {
        next if($c->{deleted});

        if($c->{author}->{login} eq 'ci') {
            push (@ci_comments, $c);
        }
        elsif($c->{text} =~ /$pr_link/g) {
            #$self->logger->info("PR mentioned by user on $ticket_id");
            $comments_added->{"$ticket_id-$pr_link"} = 1;
            return;
        }
    }

    my $comment = $ci_comments[-1];
    my $comment_text = 'Pull Request(s) - Github commit mentions';
    my $comment_id;
    my $update_required = 1;
    if ($comment && $comment->{id}) {
        $comment_id = $comment->{id};
        $comment_text = $comment->{text};
        $update_required = 0 if($comment_text =~ /$pr_link/g);
    }

    if(!$update_required) {
        #$self->logger->info("PR already mentioned on $ticket_id");
        $comments_added->{"$ticket_id-$pr_link"} = 1;
        return;
    }

    $comment_text .= "\n$pr_link";

    if($self->add_update_comment($comment_text, $ticket_id, $comment_id)) {
        #$self->logger->info("Youtrack comment added/updated successfully on ticket $ticket_id");
        $comments_added->{"$ticket_id-$pr_link"} = 1;
    }
}

# ============================================================================ #

# Add comment to a ticket. This method will try to update the
# existing comment if third argument comment_id is mentiond
sub add_update_comment {
    my ($self, $comment_text, $ticket_id, $comment_id) = @_;

    my $ua = $self->ua;
    my $ticket_fields = 'fields=id,author,text';

    my @path_seg = ("issues", $ticket_id, "comments");
    push(@path_seg, $comment_id) if($comment_id);

    my $yt_link = $self->_get_api_path(@path_seg);

    my $url = $yt_link . "?$ticket_fields";

    my $body = {
        "text" => $comment_text
    };

    my $ticket = $ua->post($url, fields => 'id,author,text', Content => encode_json($body) );

    if (!$ticket->is_success) {
        $self->logger->error("Failed! " . $ticket->status_line);
        return;
    }

    return 1;
}

# ============================================================================ #

# Get youtrack comments for the given ticket id
sub get_ticket_comments {
    my ($self, $ticket_id) = @_;

    my $ua = $self->ua;
    my $yt_link = $self->_get_api_path('issues', $ticket_id, 'comments');
    my $ticket_fields = 'fields=id,author(login),text,deleted';
    my $url = $yt_link . "?$ticket_fields";

    my $ticket = $ua->get($url);

    if (!$ticket->is_success) {
        $self->logger->error("Failed! " . $ticket->status_line);
        return;
    }

    return decode_json($ticket->decoded_content);
}

# ============================================================================ #
# ============================================================================ #

1;

