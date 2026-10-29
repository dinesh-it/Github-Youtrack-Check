package Checker;

# YouTrack ticket gate: decides the status of a commit and of the PR titles
# pointing at it. Shared by the service and scripts/ci-doctor.pl.

use strict;
use warnings;

# ============================================================================ #

# Arguments: youtrack (Youtrack object), logger, pr_branch_check
# (PR_BRANCH_YT_CHECK format 'branch_regex=ticket_regex', optional)
sub new {
    my ($class, %args) = @_;

    my $self = bless {youtrack => $args{youtrack}, logger => $args{logger}}, $class;

    # eg: 'PRODUCTION*=CLUSTER-*' - PR title against a branch matching the left
    # regex must have a ticket matching the right regex
    if (my $br_check = $args{pr_branch_check}) {
        my ($branch, $ticket) = split(/=/, $br_check, 2);
        if (!defined $ticket or $branch eq '' or $ticket eq '') {
            die "PR_BRANCH_YT_CHECK must be in 'branch_regex=ticket_regex' format\n";
        }
        $self->{branch_re}   = eval { qr/$branch/i } or die "Invalid PR_BRANCH_YT_CHECK branch regex: $@";
        $self->{ticket_re}   = eval { qr/$ticket/i } or die "Invalid PR_BRANCH_YT_CHECK ticket regex: $@";
        $self->{branch_desc} = $branch;
        $self->{ticket_desc} = $ticket;
    }

    return $self;
}

# ============================================================================ #

# Returns the failure description when a PR against $base_branch must have a
# different kind of ticket than $yt_id, undef when it is fine
sub title_rule_failure {
    my ($self, $base_branch, $yt_id) = @_;

    return if (!$self->{branch_re} or !defined $base_branch);
    return if ($base_branch !~ $self->{branch_re} or $yt_id =~ $self->{ticket_re});

    return "PR title should have $self->{ticket_desc} ticket for $self->{branch_desc} branch";
}

# ============================================================================ #

# Returns 'WAIT' or { state, desc, link, comments => [[ticket, pr_link]] }
sub evaluate_commit {
    my ($self, $commit, $titles) = @_;

    my $message = $commit->{message} // '';
    my $yt_id   = $self->{youtrack}->get_ticket_id($message);
    my $result  = {comments => []};

    if (!$yt_id) {
        if ($message =~ /^Merge /) {
            $self->{logger}->info("Message: \"$message\" - check skipped for merge commit");
            $result->{state} = 'success';
            $result->{desc}  = 'Check skipped for merge commit';
        }
        else {
            $self->{logger}->error("Message: \"$message\" does not have a matching youtrack Id");
            $result->{state} = 'error';
            $result->{desc}  = 'Youtrack ticket not mentioned in the commit message';
        }
    }
    else {
        my $ticket = $self->{youtrack}->get_ticket($yt_id);

        return 'WAIT' if ($ticket and ($ticket->{Link} // '') eq 'WAIT');

        if (!$ticket) {
            $self->{logger}->error("Valid YouTrack ticket not found with Id: $yt_id");
            $result->{state} = 'error';
            $result->{desc}  = "Unable to find youtrack issue id $yt_id, Please verify!";
        }
        else {
            $result->{state} = 'success';
            $result->{desc}  = $yt_id . ': ' . ($ticket->{summary} // '');
            $result->{link}  = $ticket->{Link};
            push(@{$result->{comments}}, [$yt_id, $commit->{git_link}]) if ($commit->{git_link});
        }
    }

    return $result if ($result->{state} ne 'success' or !$titles);

    # Head commit of pull request(s), all PR titles must pass too
    return $self->evaluate_titles($titles, $result);
}

# ============================================================================ #

sub evaluate_titles {
    my ($self, $titles, $result) = @_;

    $result->{comments} //= [];

    foreach my $title (@{$titles}) {
        my $tr = $self->evaluate_title($title);
        return 'WAIT' if ($tr eq 'WAIT');

        if ($tr->{state} ne 'success') {
            return {%{$tr}, comments => $result->{comments}};
        }

        $result->{desc} = $tr->{desc};
        $result->{link} //= $tr->{link};
        push(@{$result->{comments}}, @{$tr->{comments}});
    }

    return $result;
}

# ============================================================================ #

sub evaluate_title {
    my ($self, $title) = @_;

    my $yt_id = $self->{youtrack}->get_ticket_id($title->{message});

    if (!$yt_id) {
        $self->{logger}->error("PR Title: \"$title->{message}\" does not have a youtrack Id");
        return {state => 'error', desc => 'Youtrack ticket not mentioned in the PR title'};
    }

    if (my $rule = $self->title_rule_failure($title->{base_branch}, $yt_id)) {
        $self->{logger}->error("PR Title: \"$title->{message}\" does not have a $self->{ticket_desc} youtrack Id");
        return {state => 'error', desc => $rule};
    }

    my $ticket = $self->{youtrack}->get_ticket($yt_id);
    return 'WAIT' if ($ticket and ($ticket->{Link} // '') eq 'WAIT');

    if (!$ticket) {
        $self->{logger}->error("Valid YouTrack ticket not found with Id: $yt_id");
        return {state => 'error', desc => "Unable to find youtrack issue id $yt_id, Please verify!"};
    }

    return {
        state    => 'success',
        desc     => $yt_id . ': ' . ($ticket->{summary} // ''),
        link     => $ticket->{Link},
        comments => $title->{git_link} ? [[$yt_id, $title->{git_link}]] : [],
    };
}

1;
