#!/usr/bin/env perl

use strict;
use warnings;
use DBI;
use LWP::UserAgent;
use URI::Builder;
use JSON::XS;
use Data::Dumper;
use HTTP::Date;
use Mojo::IOLoop;
use DateTime;

use FindBin;
use lib $FindBin::Bin;
use GithubToken;

# To make sure we get systemd logs immediately
$| = 1;

# Check of required ENV's available
if (!$ENV{GITHUB_TOKEN} and !$ENV{GITHUB_APP_KEY_FILE}) {
    die "GITHUB_TOKEN or GITHUB_APP_KEY_FILE ENV required\n";
}

# Check if required youtrack API ENV's available
foreach my $var (qw/YOUTRACK_TOKEN YOUTRACK_HOST/) {
    if (!$ENV{$var}) {
        die "$var ENV required\n";
    }
}

my $gt;
if($ENV{GITHUB_APP_KEY_FILE}) {
    $gt = GithubToken->new(
        private_key_file => $ENV{GITHUB_APP_KEY_FILE},
    );

    if(!$gt->get_access_token) {
        die "Failed to get github app access token\n";
    }
    print "Using github app access token for github API\n";
}

# Option to specify the seconds before to check for
# If the service is down for an hour we can run this script with 3600
# seconds
my $last_pooled_at = int($ARGV[0]);

# Pool for changes from last 3 minutes
$last_pooled_at = $last_pooled_at || time - 180;

# Cache to avoid multiple pings to youtrac for same query
my $verified_tickets = {};
my $comments_added   = {};

my $sleep_time       = 5;
my $match_key_last_tried;
my $youtrack_match_key = get_youtrack_match_key();

# ============================================================================ #

my $global_dbh;
sub get_db_conn {
    return $global_dbh if($global_dbh);
    my $driver   = "SQLite";
    my $database = $ENV{GITHUB_WEB_HOOK_DB} ||= "/tmp/github_web_hook.db";
    my $userid   = $ENV{GITHUB_WEB_HOOK_DB_USER} //= "";
    my $password = $ENV{GITHUB_WEB_HOOK_DB_PWD} //= "";
    my $dsn      = "DBI:$driver:dbname=$database";
    $global_dbh  = DBI->connect($dsn, $userid, $password, {RaiseError => 1}) or die $DBI::errstr;
    return $global_dbh;
}

# ============================================================================ #

sub add_pull_request {
    my ($repo_name, $commits_url, $pr_link) = @_; 
    my $dbh = get_db_conn();
    my $sql = qq/INSERT INTO GitPushEvent (event_type, project, commit_id, message, git_link, created_epoch) VALUES(?,?,?,?,?,?)/;
    my $sth = $dbh->prepare($sql);
    return $sth->execute('pull_request', $repo_name, undef, $commits_url, $pr_link, time);
}

# ============================================================================ #

sub delete_pull_request {
    my ($project, $message) = @_;
    my $dbh = get_db_conn();
    my $sql = qq/DELETE FROM GitPushEvent WHERE event_type = 'pull_request' AND project = ? AND message = ?/;
    $dbh->do($sql, undef, $project, $message);
}

# ============================================================================ #

sub add_commits {
    my ($data, $project, $owner, $pr_link) = @_;
    my $dbh = get_db_conn();
    my $sql =
      qq/INSERT INTO GitPushEvent (event_type, project, owner, commit_id, message, git_link, created_epoch) VALUES(?,?,?,?,?,?,?)/;
    my $sth   = $dbh->prepare($sql);
    my $count = 0;

    foreach my $commit (@{$data}) {
        $count += $sth->execute('push', $project, $owner, $commit->{id}, $commit->{message}, $pr_link, time);
        post_github_status({
            commit_id => $commit->{id},
            desc => "Commit queued for checking Youtrack ticket",
            owner => $owner,
            project => $project,
        }, 'pending');
    }

    if ($count != @{$data}) {
        return 0;
    }

    return 1;
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

sub check_db_pull_requests {
    my $dbh    = get_db_conn();
    my $sql    = qq/SELECT * FROM GitPushEvent WHERE event_type = 'pull_request' ORDER BY created_epoch asc/;
    my $result = $dbh->selectall_arrayref($sql, {Slice => {}});
    if (!$result or !@{$result}) {
        return 0;
    }

    foreach my $pr (@{$result}) {
        my $commits_url = $pr->{message};
        my $project     = $pr->{project};
        my $pr_link     = $pr->{git_link};

        my @url = split('/', $commits_url);

        if ($project ne $url[5]) {
            print "Project name not matched in the URL, something wen't wrong\n";
            print "Project: $project is not $url[6], URL: $commits_url\n";
            delete_pull_request($project, $commits_url);
            next;
        }

        my $owner = $url[4];

        my $no_delete = 0;
        my $commits   = fetch_all_commits($commits_url, \$no_delete);

        if (!$commits) {
            if (!$no_delete) {
                delete_pull_request($project, $commits_url);
            }
            else {
                print "This request will be tried again\n";

                # Wait for sometime since no_delete will be set only for timeout or internet issue
                sleep 10;
            }
            next;
        }

        my $table_data = get_commits_data($commits);

        if (add_commits($table_data, $project, $owner, $pr_link)) {
            delete_pull_request($project, $commits_url);
        }
    }

    return 1;
}

# ============================================================================ #

sub fetch_all_commits {
    my ($page_url, $no_delete) = @_;

    my $gh_token = $gt ? $gt->get_access_token : $ENV{GITHUB_TOKEN};

    my $ua = LWP::UserAgent->new();
    $ua->default_header('Authorization' => "Bearer $gh_token");

    my @all_commits;
    while ($page_url) {

        my $gh = URI::Builder->new(uri => $page_url);
        $gh->query_param(per_page => 100);

        my $gh_url = $gh->as_string;

        my $req = HTTP::Request->new(GET => $gh_url);
        $req->content_type('application/json');

        my $res      = $ua->request($req);
        my $res_code = $res->code;

        if (!$res->is_success) {
            print "Error: $res_code, for URL: $gh_url\n";
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

    return \@all_commits;
}

# ============================================================================ #

sub get_commits_data {
    my ($commits, $after_commit) = @_;

    my @commits_data;
    my $start_after = 0;
    my $i           = 0;
    foreach my $commit (@{$commits}) {

        if ($after_commit and $after_commit eq $commit->{sha}) {
            $start_after = $i;
        }

        push(@commits_data, {id => $commit->{sha}, message => $commit->{commit}->{message}});
        $i++;
    }

    if ($start_after) {
        @commits_data = splice(@commits_data, $start_after);
    }

    return \@commits_data;
}

# ============================================================================ #

sub pool_gh_pending_prs {
    my $gh_token = $gt ? $gt->get_access_token : $ENV{GITHUB_TOKEN};

    my $ua = LWP::UserAgent->new();
    $ua->default_header('Authorization' => "Bearer $gh_token");

    my $page_url = 'https://api.github.com/orgs/exceleron/repos?per_page=100';

    my $res      = $ua->get($page_url);
    my $res_code = $res->code;

    my $res_json = decode_json($res->decoded_content);

    if (!$res->is_success) {
        print "Error: " . $res->status_line . " for URL: $page_url\n";
        print Dumper($res_json);
        return;
    }

    foreach my $rep (@{$res_json}) {
        my $last_pushed = str2time($rep->{pushed_at});
        my $last_updated = str2time($rep->{updated_at});
        if($last_updated > $last_pooled_at || $last_pushed > $last_pooled_at) {
            print "Pooling for repo $rep->{name}\n";
            add_pending_prs($rep->{name});
        }
    }

    $last_pooled_at = time - 10;
}

# ============================================================================ #

sub add_pending_prs {
    my $repo = shift;
    my $gh_token = $gt ? $gt->get_access_token : $ENV{GITHUB_TOKEN};

    my $ua = LWP::UserAgent->new();
    $ua->default_header('Authorization' => "Bearer $gh_token");

    my $page_url = "https://api.github.com/repos/exceleron/$repo/pulls?per_page=100";

    my $res      = $ua->get($page_url);
    my $res_code = $res->code;

    if (!$res->is_success) {
        print "Error: $res_code, for URL: $page_url\n";
        print Dumper($res->decoded_content);
        return;
    }

    my $res_json = decode_json($res->decoded_content);

    foreach my $pr (@{$res_json}) {

        my $last_updated = str2time($pr->{updated_at});
        if($last_updated < $last_pooled_at) {
            next;
        }

        my $status_url = $pr->{statuses_url};
        my $statuses_res = $ua->get($status_url);

        my $pr_last_updated;
        if($pr->{updated_at}) {
            $pr_last_updated = str2time($pr->{updated_at});
        }
        else {
            $pr_last_updated = str2time($pr->{created_at});
        }

        if(!$statuses_res->is_success) {
            print "Failed to get status for PR $pr->{url}\n";
            next;
        }

        my $statuses_json = decode_json($statuses_res->decoded_content);
        #print Dumper($statuses_json);

        my $status_last_updated = 0;
        my $status = '';
        foreach my $st (@{$statuses_json}) {
            if($st->{context} eq 'ci/chk-youtrack') {
                $status_last_updated = str2time($st->{updated_at});
                $status = $st->{state};
                last;
            }
        }

        if($status ne 'success' and $status_last_updated < $pr_last_updated) {
            print "Adding PR for check from pooling method: $pr->{url}, Last state: $status\n";
            add_pull_request($repo, $pr->{commits_url}, $pr->{html_url});
        }
    }
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
            print "$url will be retried again\n";
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

sub post_github_status {
    my ($commit, $status, $link, $yt_id) = @_;

    my $commit_hash = $commit->{commit_id};
    return if($commit_hash eq 'NONE');

    if($gt and !$ENV{DISABLE_CHECK_API}) {
        post_github_check(@_);
        return;
    }

    my $gh_token = $gt ? $gt->get_access_token : $ENV{GITHUB_TOKEN};

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
        return;
    }

    foreach my $cid (keys %commit_hash) {
        my $commit = $commit_hash{$cid};

        my $yt_id = get_youtrack_id($commit->{message});

        my $pr_link = $commit->{git_link};
        if (!$yt_id) {
            print STDERR "Message: \"$commit->{message}\" does not have a matching youtrack Id\n";
            $commit->{desc} = 'Youtrack ticket not mentioned in the commit message';
            post_github_status($commit, 'error');
            next;
        }

        #$commit->{desc} = "Checking youtrack for issue id $yt_id";
        #post_github_status($commit, 'pending', undef, $yt_id);
        my $ticket = get_youtrack_ticket($yt_id);

        if (!$ticket) {
            $commit->{desc} = "Unable to find youtrack issue id $yt_id, Please verify!";
            print STDERR "Valid YouTrack ticket not found with Id: $yt_id\n";
            post_github_status($commit, 'error');
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

        post_github_status($commit, $st, $ticket_url, $yt_id);
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

sub post_github_check {
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

# ============================================================================ #

# ============================================================================ #

my $event_loop = Mojo::IOLoop->singleton;

# Pool github for changes every 3 minutes
$event_loop->recurring(180 => sub {
        pool_gh_pending_prs();
    });

$event_loop->recurring( 10 => sub {
        my $loop = shift;
        $loop->next_tick(sub { check_all_commits(); });
        check_db_pull_requests();
    });

$event_loop->recurring( 10 => sub {
        check_all_commits();
    });

pool_gh_pending_prs();
check_db_pull_requests();
check_all_commits();

print "Starting recurring timers...\n";
$event_loop->start unless $event_loop->is_running;

# ============================================================================ #

