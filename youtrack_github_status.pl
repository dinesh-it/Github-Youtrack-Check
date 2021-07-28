#!/usr/bin/env perl

use strict;
use warnings;
use DBI;
use LWP::UserAgent;
use URI::Builder;
use JSON::XS;
use HTTP::Date;
use DateTime;

use FindBin;
use lib $FindBin::Bin;
use GithubToken;

# To make sure we get systemd logs immediately
$| = 1;

# Check of required ENV's available
foreach my $var (qw/YOUTRACK_TOKEN YOUTRACK_HOST/) {
    if (!$ENV{$var}) {
        die "$var ENV required\n";
    }
}

if(!$ENV{GITHUB_APP_KEY_FILE} and !$ENV{GITHUB_TOKEN}) {
    die "Either GITHUB_APP_KEY_FILE or GITHUB_TOKEN env required\n";
}

my $gt;
if($ENV{GITHUB_APP_KEY_FILE}) {
    $gt = GithubToken->new(
        private_key_file => $ENV{GITHUB_APP_KEY_FILE},
    );

    if(!$gt->get_access_token) {
        die "Failed to get github app access token\n";
    }
    print "Using github app access token\n";
}

my $verified_tickets = {};
my $comments_added   = {};
my $sleep_time       = 5;
my $match_key_last_tried;
my $youtrack_match_key = get_youtrack_match_key();

while (1) {
    sleep($sleep_time);
    $verified_tickets = {};
    check_all_commits();
}

# ============================================================================ #

sub get_db_conn {
    my $driver   = "SQLite";
    my $database = $ENV{GITHUB_WEB_HOOK_DB} ||= "/tmp/github_web_hook.db";
    my $userid   = $ENV{GITHUB_WEB_HOOK_DB_USER} //= "";
    my $password = $ENV{GITHUB_WEB_HOOK_DB_PWD} //= "";
    my $dsn      = "DBI:$driver:dbname=$database";
    my $dbh      = DBI->connect($dsn, $userid, $password, {RaiseError => 1}) or die $DBI::errstr;
    return $dbh;
}

# ============================================================================ #

sub get_commits {
    my $dbh    = get_db_conn();
    my $sql    = qq/SELECT * FROM GitPushEvent WHERE event_type = 'push' ORDER BY created_epoch asc/;
    my $result = $dbh->selectall_arrayref($sql, {Slice => {}});
    return $result;
}

# ============================================================================ #

sub delete_commit {
    my $commit_id = shift;
    my $dbh       = get_db_conn();
    my $sql       = qq/DELETE FROM GitPushEvent WHERE commit_id = ?/;
    $dbh->do($sql, undef, $commit_id);
}

# ============================================================================ #

sub get_youtrack_id {
    my $message = shift;

    if ($message =~ /$youtrack_match_key/i) {
        return uc($1);
    }

    # Probably new project added so lets update our list and try one more time
    if($message =~ /[A-Z0-9]-\d+/) {
        $youtrack_match_key = get_youtrack_match_key();

        if ($message =~ /$youtrack_match_key/i) {
            return uc($1);
        }
    }

    return;
}

# ============================================================================ #

sub get_youtrack_ticket {
    my $ticket_id = shift;

    return if (!$ticket_id);

    if (exists $verified_tickets->{$ticket_id}) {
        return $verified_tickets->{$ticket_id};
    }

    my $yt_token = $ENV{YOUTRACK_TOKEN};
    my $yt_host  = $ENV{YOUTRACK_HOST};

    my $yt = URI::Builder->new(uri => $yt_host);

    my $ua = LWP::UserAgent->new();
    $ua->default_header('Authorization' => "Bearer $yt_token");
    $ua->default_header('Accept'        => 'application/json');
    $ua->default_header('Content-Type'  => 'application/json');

    my $ticket_fields = 'fields=numberInProject,summary';

    $yt->path_segments("youtrack", "api", "issues", $ticket_id);

    my $url = $yt->as_string . "?$ticket_fields";

    my $ticket = $ua->get($url);

    if (!$ticket->is_success) {
        my $status_code = $ticket->code;
        print STDERR "YouTrack request Error: $status_code :" . $ticket->status_line . "\n";
        print STDERR "Failed URL: $url\n";
        die "Please check the token\n" if ($status_code == 401);

        if($status_code == 502) {
            die "Received 502, lets die and see if it works after the service restart\n";
        }

        if ($status_code == 408 || $status_code == 503 || $ticket->status_line =~ /Can't connect to/i || $ticket->status_line =~ /Time-out/i) {

            my $retry_after = $ticket->header("Retry-After");
            if ($retry_after) {
                print STDERR "Received Retry-After header value: $retry_after\n";
                if ($retry_after =~ /^\d+$/) {
                    $sleep_time = $retry_after;
                }
                else {
                    $sleep_time = str2time($retry_after) - time;
                }
            }
            else {
                # Wait exponentially till 60 minutes
                $sleep_time = 1 if (!$sleep_time);
                $sleep_time = $sleep_time * 2;
                $sleep_time = 3600 if ($sleep_time > 3600);
            }
            print "Setting sleep time to $sleep_time seconds\n";
            return { Link => "WAIT" }; 
        }

        $verified_tickets->{$ticket_id} = undef;
        return;
    }

    $yt->path_segments('youtrack', 'issue', $ticket_id);
    $verified_tickets->{$ticket_id} = decode_json($ticket->decoded_content);
    $verified_tickets->{$ticket_id}->{Link} = $yt->as_string;

    return $verified_tickets->{$ticket_id};
}

# ============================================================================ #

sub github_status {
    my ($commit, $status, $link, $yt_id) = @_;

    my $commit_hash = $commit->{commit_id};
    return if($commit_hash eq 'NONE');

    if($gt and !$ENV{DISABLE_CHECK_API}) {
        github_check(@_);
        return;
    }

    my $gh_token = $ENV{GITHUB_TOKEN};

    my $ua = LWP::UserAgent->new();
    $ua->default_header('Authorization' => "Bearer $gh_token");

    my $resp_body = {
        "context"     => "ci/chk-youtrack",
        "description" => $commit->{desc},
        "state"       => $status,
    };

    if(length($resp_body->{description}) > 96) {
        $resp_body->{description} = substr( $resp_body->{description}, 0, 90 ) . '...';
    }

    if ($link) {
        $resp_body->{target_url} = $link;
    }

    my $gh_owner    = $commit->{owner};
    my $gh_repo     = $commit->{project};

    #my $gh_url = 'https://api.github.com/repos/:owner/:repo/statuses/:sha';
    my $gh = URI::Builder->new(uri => 'https://api.github.com');

    $gh->path_segments("repos", $gh_owner, $gh_repo, "statuses", $commit_hash);

    my $gh_url = $gh->as_string;

    my $req = HTTP::Request->new(POST => $gh_url);
    $req->content_type('application/json');
    $req->content(encode_json($resp_body));

    my $res = $ua->request($req);

    my $res_code = $res->code;

    if ($res->is_success) {
        delete_commit($commit_hash) if ($status ne 'pending');
    }
    else {
        print STDERR "Error updating status for: $gh_url\n";
        print STDERR $res->decoded_content . "\n";

        # Re-try only if the request timed out or internet issue
        if ($res_code != 408 and $res->status_line !~ /Can't connect to/i) {
            delete_commit($commit_hash);
            print "This status update will not be re-tried\n";
        }
    }
}

# ============================================================================ #

sub check_all_commits {
    my $commits = get_commits();

    if (!@{$commits}) {
        $sleep_time++;
        $sleep_time = 10 if ($sleep_time > 10);
        return;
    }

    my %commit_hash;
    my %pr_hash;
    foreach my $commit (@{$commits}) {
        if ($commit->{commit_id} =~ /^PRT\|/) {
            my (undef, $base_branch, $id) = split('\|', $commit->{commit_id});
            $commit->{commit_id} = $id;
            $commit->{base_branch} = $base_branch;
            $pr_hash{$id} = $commit;
        }
        else {
            $commit_hash{$commit->{commit_id}} = $commit;
        }
    }

	# Process and delete stale PR title entries
	# It does not push status to github but adds comments
	# in youtrack if needed
    if(!%commit_hash and %pr_hash) {
        foreach my $cid (keys %pr_hash) {
            my $h = {};
            check_pr_title($cid, \%pr_hash, $h);
        }
    }

    if(!%commit_hash){
        $sleep_time++;
        $sleep_time = 10 if ($sleep_time > 10);
        return;
    }

    foreach my $cid (keys %commit_hash) {
        my $commit = $commit_hash{$cid};

        my $yt_id = get_youtrack_id($commit->{message});

        my $pr_link = $commit->{git_link};
        if (!$yt_id) {
            print STDERR "Message: \"$commit->{message}\" does not have a matching youtrack Id\n";
            $commit->{desc} = 'Youtrack ticket not mentioned in the commit message';
            github_status($commit, 'error');
            next;
        }

        $commit->{desc} = "Checking youtrack for issue id $yt_id";
        github_status($commit, 'pending', undef, $yt_id);
        my $ticket = get_youtrack_ticket($yt_id);

        if (!$ticket) {
            $commit->{desc} = "Unable to find youtrack issue id $yt_id, Please verify!";
            print STDERR "Valid YouTrack ticket not found with Id: $yt_id\n";
            github_status($commit, 'error');
            next;
        }

        my $ticket_url = $ticket->{Link};
        if ($ticket_url eq 'WAIT') {
            # YouTrack not available or network issue, sleep and try again later
            return;
        }

        $commit->{desc} = $yt_id . ': ' .$ticket->{summary};
        my $st = check_pr_title($cid, \%pr_hash, $commit);

        return if(!$st);

        github_status($commit, $st, $ticket_url, $yt_id);
        add_yt_comment($yt_id, $pr_link);
    }

    $sleep_time = 0;
}

# ============================================================================ #

sub check_pr_title {
    my ($cid, $pr_hash, $head_commit) = @_;

    return 'success' if(!exists $pr_hash->{$cid});

    my $commit = $pr_hash->{$cid};
    my $commit_hash = "PRT|$commit->{base_branch}|$cid";

    my $yt_id = get_youtrack_id($commit->{message});

    my $pr_link = $commit->{git_link};
    if (!$yt_id) {
        print STDERR "PR Title: \"$commit->{message}\" does not have a youtrack Id\n";
        $head_commit->{desc} = 'Youtrack ticket not mentioned in the PR title';
        delete_commit($commit_hash);
        return 'error';
    }

    my $br_check = $ENV{PR_BRANCH_YT_CHECK};
    if($br_check) {
        my ($bb_reg, $yt_reg) = split('=', $br_check);

        if($commit->{base_branch} =~ /$bb_reg/i and $yt_id !~ /$yt_reg/i) {
            print STDERR "PR Title: \"$commit->{message}\" does not have a $yt_reg youtrack Id\n";
            $head_commit->{desc} = "PR title should have $yt_reg ticket for $bb_reg branch";
            delete_commit($commit_hash);
            return 'error';
        }
    }

    my $ticket = get_youtrack_ticket($yt_id);

    if (!$ticket) {
        $head_commit->{desc} = "Unable to find youtrack issue id $yt_id, Please verify!";
        print STDERR "Valid YouTrack ticket not found with Id: $yt_id\n";
        delete_commit($commit_hash);
        return 'error';
    }

    my $ticket_url = $ticket->{Link};

    return if($ticket_url eq 'WAIT');

    $head_commit->{desc} = $yt_id . ': ' .$ticket->{summary};

    add_yt_comment($yt_id, $pr_link);
    delete_commit($commit_hash);

    return 'success';
}

# ============================================================================ #

sub add_yt_comment {
    my ($ticket_id, $pr_link) = @_;

    return if(!$pr_link);

    return if($comments_added->{"$ticket_id-$pr_link"});

    my $yt_token = $ENV{YOUTRACK_TOKEN};
    my $yt_host  = $ENV{YOUTRACK_HOST};

    my $yt = URI::Builder->new(uri => $yt_host);

    my $ua = LWP::UserAgent->new();
    $ua->default_header('Authorization' => "Bearer $yt_token");
    $ua->default_header('Accept'        => 'application/json');
    $ua->default_header('Content-Type'  => 'application/json');

    my $ticket_fields = 'fields=id,author,text';

    my $comments = get_yt_comments($ticket_id);
    my @ci_comments;

    foreach my $c (@{$comments}) {
        next if($c->{deleted});

        if($c->{author}->{login} eq 'ci') {
            push (@ci_comments, $c);
        }
        elsif($c->{text} =~ /$pr_link/g) {
            #print "PR mentioned by user on $ticket_id\n";
            $comments_added->{"$ticket_id-$pr_link"} = 1;
            return;
        }
    }

    my $comment = $ci_comments[-1];
    my $comment_text = 'Pull Request(s) - Github commit mentions';
    my @path_seg = ("youtrack", "api", "issues", $ticket_id, "comments");
    my $comment_id;
    my $update_required = 1;
    if ($comment && $comment->{id}) {
        $comment_id = $comment->{id};
        $comment_text = $comment->{text};
        $update_required = 0 if($comment_text =~ /$pr_link/g);
        push(@path_seg, $comment_id);
    }

    if(!$update_required) {
        #print "PR already mentioned on $ticket_id\n";
        $comments_added->{"$ticket_id-$pr_link"} = 1;
        return;
    }

    $comment_text .= "\n$pr_link";

    $yt->path_segments(@path_seg);

    my $url = $yt->as_string . "?$ticket_fields";

    my $body = {
        "text" => $comment_text
    };

    my $ticket = $ua->post($url, fields => 'id,author,text', Content => encode_json($body) );

    if (!$ticket->is_success) {
        print "Failed! " . $ticket->status_line  . "\n";
    }
    else {
        #print "Youtrack comment added/updated successfully on ticket $ticket_id\n";
        $comments_added->{"$ticket_id-$pr_link"} = 1;
    }
}

# ============================================================================ #

sub get_yt_comments {
    my $ticket_id = shift;

    my $yt_token = $ENV{YOUTRACK_TOKEN};
    my $yt_host  = $ENV{YOUTRACK_HOST};

    my $yt = URI::Builder->new(uri => $yt_host);

    my $ua = LWP::UserAgent->new();
    $ua->default_header('Authorization' => "Bearer $yt_token");
    $ua->default_header('Accept'        => 'application/json');
    $ua->default_header('Content-Type'  => 'application/json');

    my $ticket_fields = 'fields=id,author(login),text,deleted';

    $yt->path_segments("youtrack", "api", "issues", $ticket_id, "comments");

    my $url = $yt->as_string . "?$ticket_fields";

    my $ticket = $ua->get($url);

    if (!$ticket->is_success) {
        print "Failed! " . $ticket->status_line  . "\n";
        return;
    }

    return decode_json($ticket->decoded_content);
}

# ============================================================================ #

sub github_check {
    my ($commit, $result, $link, $yt_id) = @_;

    my $gh_token = $gt->get_access_token;

    my $title = $commit->{desc};
    my $desc = 'If you think there is something went wrong with this check, ';
    $desc .= 'Please re-run this check or contact admin if the issue persist';
    my $status = 'completed';
    my $conclusion = 'success';

    if($status eq 'completed') {
        $desc = 'If multiple tickets mentioned in the message, only the first ticket will be considered';
    }

    if($link) {
        $desc = "Youtrack: $link\n\n" . $desc;
    }

    if ($result eq 'error') {
        $conclusion = 'failure';
    }
    elsif ($result eq 'pending') {
        $status = 'in_progress';
    }

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

    my $ua = LWP::UserAgent->new();
    $ua->default_header('Authorization' => "Bearer $gh_token");
    $ua->default_header('Content-Type' => 'application/json');

    # https://api.github.com/repos/dinesh-it/APIAutomation/check-runs
    my $gh = URI::Builder->new(uri => 'https://api.github.com');
    $gh->path_segments("repos", $gh_owner, $gh_repo, "check-runs");
    my $gh_url = $gh->as_string;

    my $json_body = encode_json($body);
    my $res = $ua->post($gh_url, Content => $json_body);
    my $res_code = $res->code;

    if ($res->is_success) {
        delete_commit($commit_hash) if ($result ne 'pending');
    }
    else {
        print STDERR "Error updating status for: $gh_url\n";
        print STDERR $res->decoded_content . "\n";

        # Re-try only if the request timed out or internet issue
        if ($res_code != 408 and $res->status_line !~ /Can't connect to/i) {
            delete_commit($commit_hash);
            print "This check update will not be re-tried\n";
        }
    }
}

# ============================================================================ #

sub get_youtrack_match_key {

    # Avoid traying again and again in a loop - try again only after 5 mins
    if($match_key_last_tried and $match_key_last_tried > (time - (60 * 5))) {
        return $youtrack_match_key;
    }

    $match_key_last_tried = time;

    print "Getting projects list from youtrack\n";
    my $yt_token = $ENV{YOUTRACK_TOKEN};
    my $yt_host  = $ENV{YOUTRACK_HOST};

    my $yt = URI::Builder->new(uri => $yt_host);

    my $ua = LWP::UserAgent->new();
    $ua->default_header('Authorization' => "Bearer $yt_token");
    $ua->default_header('Accept'        => 'application/json');
    $ua->default_header('Content-Type'  => 'application/json');

    $yt->path_segments("youtrack", "api", "admin", 'projects');

    my $res = $ua->get($yt->as_string . '?fields=shortName');

    if(!$res->is_success) {
        print "ERROR: Status - " . $res->status_line . "\n";
        die "Failed to get project ID's\n";
    }

    my $projects = decode_json($res->decoded_content);

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
    print "Ticket match key: $reg_ex\n";

    return $reg_ex;
}
