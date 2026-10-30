#!/usr/bin/env perl

# ci-doctor - inspect and fix the youtrack CI check service from the terminal
#
# Run it on the service host as the service user with the service env, eg:
#   sudo -u github-webhook-listener bash -lc 'scripts/ci-doctor.pl status'
# The first readable env file of --env-file, the salt deployment one
# (/etc/pams/service/github-webhook-listener/env), local/.env and .env of the
# checkout is loaded for any ENV not already set.
#
# --json prints one JSON document on stdout for monitoring tools, logs go to
# stderr. Exit code: 0 ok, 1 problem found / failed, 2 usage error.

use strict;
use warnings;
use Getopt::Long qw(GetOptionsFromArray);
use HTTP::Date qw(str2time);
use JSON::XS;
use LWP::UserAgent;
use Mojo::Log;
use POSIX qw(strftime);
use List::Util qw(min);

use FindBin;
use lib "$FindBin::Bin/../lib";
use Github;
use Youtrack;
use Store;
use Checker;
use Redelivery;

$| = 1;

my @DEFAULT_ENV_FILES = ('/etc/pams/service/github-webhook-listener/env', "$FindBin::Bin/../local/.env", "$FindBin::Bin/../.env");

# GitHub web hook IP ranges allowed to reach the service, same as the micro-ci
# security group (tf-aws-network app-vpc/securitygroups.tf), GITHUB_HOOK_CIDRS overrides
my @DEFAULT_HOOK_CIDRS = qw(140.82.112.0/20 185.199.108.0/22 192.30.252.0/22 143.55.64.0/20
  9.234.106.48/28 9.234.98.160/28 9.234.98.176/28);

# Each command returns a hash with an 'ok' flag, printed as text or JSON
my %commands = (
    'status'       => [\&cmd_status,       \&text_status],
    'check-ticket' => [\&cmd_check_ticket, \&text_check_ticket],
    'check-pr'     => [\&cmd_check_pr,     \&text_check_pr],
    'deliveries'   => [\&cmd_deliveries,   \&text_deliveries],
    'redeliver'    => [\&cmd_redeliver,    \&text_redeliver],
    'queue'        => [\&cmd_queue,        \&text_queue],
    'sync'         => [\&cmd_sync,         \&text_sync],
);

my %objects;
my @args = @ARGV;
my %global;
Getopt::Long::Configure('pass_through', 'require_order');
GetOptionsFromArray(\@args, \%global, 'env-file=s', 'json', 'debug', 'help|h') or usage();
Getopt::Long::Configure('no_pass_through');

my $command = shift(@args) // '';
usage() if ($global{help} or !$commands{$command});

my $log = Mojo::Log->new(level => $global{debug} ? 'debug' : 'warn');

my $result = eval {
    load_env($global{'env-file'});
    warn_if_not_db_owner();
    $commands{$command}[0]->(@args);
};

if (!$result) {
    my $error = $@ || "Command failed\n";
    chomp($error);
    if ($global{json}) {
        print JSON::XS->new->canonical->encode({ok => JSON::XS::false, command => $command, error => $error}) . "\n";
    }
    else {
        print STDERR "ERROR: $error\n";
    }
    exit 1;
}

$result->{command} = $command;
$result->{ok}      = $result->{ok} ? JSON::XS::true : JSON::XS::false;

if ($global{json}) {
    print JSON::XS->new->canonical->encode($result) . "\n";
}
else {
    $commands{$command}[1]->($result);
}

exit($result->{ok} ? 0 : 1);

# ============================================================================ #

sub usage {
    print STDERR <<'EOF';
Usage: ci-doctor.pl [--env-file FILE] [--json] [--debug] <command> [options]

  status                          Service health, queue and web hook redelivery state
  check-ticket "<text>" [--base BRANCH]
                                  Check a commit message or PR title (--base: PR base branch)
  check-pr OWNER/REPO#NUMBER [--queue]
                                  Show what the check posts for each commit of a pull request,
                                  --queue to re-check it for real (picked up by the service)
  deliveries [--failed] [--since 6h]
                                  GitHub App web hook deliveries, --failed: not delivered yet
  redeliver <DELIVERY_ID>         Ask github to deliver a web hook delivery again
  redeliver --failed              Run the automatic redelivery of failed deliveries now
  queue                           Pending pull requests / commits in the check queue
  queue drop <ROW_ID>             Remove an entry from the queue
  sync REPO [BRANCH]              Refresh branch state from github for git sync clients
                                  (clients pick it up on their next re-sync)

  --json                          Print one JSON document (for monitoring tools)
  Exit code: 0 ok, 1 problem found or failed, 2 usage error
EOF
    exit 2;
}

# ============================================================================ #

# Load KEY=VALUE lines of a systemd style env file, existing ENV wins
sub load_env {
    my ($file) = @_;

    ($file) = grep { -r $_ } @DEFAULT_ENV_FILES if (!$file);
    return if (!$file);

    open(my $fh, '<', $file) or die "Can't read env file $file: $!\n";
    while (my $line = <$fh>) {
        chomp($line);
        next if ($line =~ /^\s*(#|$)/);
        my ($key, $value) = ($line =~ /^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$/) or next;
        $value =~ s/^"(.*)"$/$1/ or $value =~ s/^'(.*)'$/$1/;
        $ENV{$key} //= $value;
    }
    close($fh);
}

# ============================================================================ #

# Queue changes and token refreshes must run as the service user
sub warn_if_not_db_owner {
    my @st = stat(Store::db_file());
    if (@st and $st[4] != $>) {
        print STDERR "WARNING: not running as the owner of " . Store::db_file()
          . ", run ci-doctor as the service user (eg: sudo -u github-webhook-listener)\n";
    }
}

# ============================================================================ #

sub github {
    return $objects{github}
      //= Github->new(private_key_file => $ENV{GITHUB_APP_KEY_FILE}, private_key => $ENV{GITHUB_APP_KEY}, logger => $log);
}

sub youtrack {
    return $objects{youtrack} //= Youtrack->new(logger => $log);
}

sub checker {
    return $objects{checker}
      //= Checker->new(youtrack => youtrack(), logger => $log, pr_branch_check => $ENV{PR_BRANCH_YT_CHECK});
}

# ============================================================================ #

sub bool { return $_[0] ? JSON::XS::true : JSON::XS::false }

sub age_secs {
    my ($epoch) = @_;
    return $epoch ? time - $epoch : undef;
}

sub age {
    my ($secs) = @_;
    return 'never'                     if (!defined $secs);
    return "${secs}s ago"              if ($secs < 120);
    return int($secs / 60) . "m ago"   if ($secs < 7200);
    return int($secs / 3600) . "h ago" if ($secs < 172800);
    return int($secs / 86400) . "d ago";
}

sub iso {
    my ($epoch) = @_;
    return $epoch ? strftime('%Y-%m-%dT%H:%M:%SZ', gmtime($epoch)) : undef;
}

sub duration {
    my ($text) = @_;
    my ($n, $unit) = ($text =~ /^(\d+)([smhd]?)$/) or die "Invalid duration '$text', eg: 30m, 6h, 2d\n";
    return $n * {s => 1, m => 60, h => 3600, d => 86400, '' => 1}->{$unit};
}

# Check result as data: {state: success|error|wait, desc, link}
sub result_data {
    my ($result) = @_;
    return {state => 'wait', desc => 'YouTrack not reachable, the service retries later'} if (!ref($result));
    return {state => $result->{state}, desc => $result->{desc}, link => $result->{link}};
}

sub result_line {
    my ($label, $result) = @_;
    printf("  %-12s %-8s %s\n", $label, uc($result->{state}), $result->{desc} // '');
    printf("  %-12s          %s\n", '', $result->{link}) if ($result->{link});
}

# ============================================================================ #
# status
# ============================================================================ #

sub cmd_status {
    my (@args) = @_;
    my %opt = (url => 'http://localhost/ghyt-ci');
    GetOptionsFromArray(\@args, \%opt, 'url=s') or usage();

    my $res   = LWP::UserAgent->new(timeout => 5)->get($opt{url});
    my $probe = eval { decode_json($res->decoded_content) };
    $probe = {} if (ref($probe) ne 'HASH');

    my $prs     = Store::get_pull_requests();
    my $commits = Store::get_commits();
    my @titles  = grep { ($_->{commit_id} // '') =~ /^PRT\|/ } @{$commits};
    my ($oldest) = sort { $a <=> $b } map { $_->{created_epoch} } @{$prs}, @{$commits};

    my $max_attempts = $ENV{REDELIVERY_MAX_ATTEMPTS} || 10;
    my @failed       = map {
        {
            guid               => $_->{guid},
            delivery_id        => $_->{delivery_id},
            event              => $_->{event},
            status_code        => $_->{status_code},
            attempts           => $_->{attempts},
            gave_up            => bool($_->{attempts} >= $max_attempts),
            next_attempt       => iso($_->{next_attempt_epoch}),
            failing_since      => iso($_->{first_failed_epoch}),
            failing_since_secs => age_secs($_->{first_failed_epoch}),
        }
    } @{Store::redelivery_list()};

    my @check_failures = map {
        {
            project    => $_->{project},
            commit_id  => $_->{commit_id},
            state      => $_->{state},
            error      => $_->{error},
            at         => iso($_->{created_epoch}),
        }
    } @{Store::list_check_failures(time - 24 * 3600)};

    my $hook_ips = hook_ips_check();

    return {
        ok    => ($res->is_success and !@{$hook_ips->{not_allowed}}),
        hook_ips => $hook_ips,
        check_failures_24h => {count => scalar(@check_failures), failures => [@check_failures[0 .. min(19, $#check_failures)]]},
        probe => {
            url        => $opt{url},
            code       => $res->code,
            ok         => bool($res->is_success),
            status     => $probe->{spooler_state},
        },
        spooler  => {last_run => iso(Store::last_alive()), age_secs => age_secs(Store::last_alive())},
        database => Store::db_file(),
        queue    => {
            pull_requests => scalar(@{$prs}),
            commits       => @{$commits} - @titles,
            pr_titles     => scalar(@titles),
            oldest_secs   => age_secs($oldest),
        },
        redelivery => {
            last_scan      => iso(Store::get_state_epoch('redelivery_scan')),
            last_scan_secs => age_secs(Store::get_state_epoch('redelivery_scan')),
            failed_count   => scalar(@failed),
            gave_up_count  => scalar(grep { $_->{gave_up} } @failed),
            failed         => \@failed,
        },
    };
}

sub text_status {
    my ($r) = @_;
    print "Service\n";
    printf("  Probe        %s %s\n", $r->{probe}{code}, $r->{probe}{ok} ? 'ok' : 'FAILED');
    printf("  Spooler      last run %s\n", age($r->{spooler}{age_secs}));
    printf("  Database     %s\n", $r->{database});

    my $q = $r->{queue};
    print "\nQueue\n";
    printf("  Pull requests %d, commits %d, PR titles %d, oldest %s\n",
        $q->{pull_requests}, $q->{commits}, $q->{pr_titles}, defined $q->{oldest_secs} ? age($q->{oldest_secs}) : '-');

    my $cf = $r->{check_failures_24h};
    print "\nStatus posts rejected by github (24h)\n";
    printf("  Count        %d\n", $cf->{count});
    printf("    %s %-24s %s %s: %s\n", $_->{at}, $_->{project}, substr($_->{commit_id}, 0, 10), $_->{state} // '', $_->{error} // '')
      for (@{$cf->{failures}});

    my $hi = $r->{hook_ips};
    print "\nGitHub web hook IPs\n";
    if ($hi->{error}) {
        printf("  Check        %s\n", $hi->{error});
    }
    else {
        printf("  Allowed      %d of %d github IPv4 hook range(s)\n", @{$hi->{github}} - @{$hi->{not_allowed}}, scalar(@{$hi->{github}}));
        printf("  NOT ALLOWED  %s - deliveries from it time out, allow it in the micro-ci security group and GITHUB_HOOK_CIDRS\n", $_)
          for (@{$hi->{not_allowed}});
    }

    my $rd = $r->{redelivery};
    print "\nWeb hook redelivery\n";
    printf("  Last scan    %s\n", age($rd->{last_scan_secs}));
    printf("  Failed       %d (gave up %d)\n", $rd->{failed_count}, $rd->{gave_up_count});
    foreach my $f (@{$rd->{failed}}) {
        printf("    %-20s %-14s status %-4s attempts %d%s, next %s, failing since %s\n",
            $f->{guid}, $f->{event} // '', $f->{status_code} // 0, $f->{attempts}, $f->{gave_up} ? ' (gave up)' : '',
            $f->{next_attempt}, age($f->{failing_since_secs}));
    }
}

# GitHub's current web hook IPv4 ranges (meta API) not covered by the allowed ones
sub hook_ips_check {
    my @allowed = $ENV{GITHUB_HOOK_CIDRS} ? split(/[\s,]+/, $ENV{GITHUB_HOOK_CIDRS}) : @DEFAULT_HOOK_CIDRS;
    my $result  = {allowed => \@allowed, github => [], not_allowed => []};

    my ($meta, $res) = github()->get_api_response(github()->api_path('meta'));
    if (ref($meta) ne 'HASH' or ref($meta->{hooks}) ne 'ARRAY') {
        $result->{error} = 'Could not get the web hook IP ranges from github: ' . ($res ? $res->status_line : 'no response');
        return $result;
    }

    # IPv6 ranges are skipped, the security group allows IPv4 only
    my @nets = grep {defined} map { cidr_range($_) } @allowed;
    foreach my $cidr (@{$meta->{hooks}}) {
        my $range = cidr_range($cidr) or next;
        push(@{$result->{github}}, $cidr);
        push(@{$result->{not_allowed}}, $cidr) if (!grep { $_->[0] <= $range->[0] and $range->[1] <= $_->[1] } @nets);
    }
    return $result;
}

# IPv4 CIDR as [first, last] address numbers, undef for anything else
sub cidr_range {
    my ($cidr) = @_;
    my (@octets) = (($cidr // '') =~ m{^(\d+)\.(\d+)\.(\d+)\.(\d+)/(\d+)$}) or return;
    my $bits = pop(@octets);
    return if ($bits > 32 or grep { $_ > 255 } @octets);
    my $size  = 2**(32 - $bits);
    my $first = 0;
    $first = $first * 256 + $_ for (@octets);
    $first -= $first % $size;
    return [$first, $first + $size - 1];
}

# ============================================================================ #
# check-ticket
# ============================================================================ #

sub cmd_check_ticket {
    my (@args) = @_;
    my %opt;
    GetOptionsFromArray(\@args, \%opt, 'base=s') or usage();
    my $text = join(' ', @args);
    usage() if ($text eq '');

    my $result = defined $opt{base}
      ? checker()->evaluate_title({message => $text, base_branch => $opt{base}})
      : checker()->evaluate_commit({message => $text});

    my $data = result_data($result);
    return {
        ok        => $data->{state} eq 'success',
        text      => $text,
        type      => defined $opt{base} ? 'pr_title' : 'commit',
        base      => $opt{base},
        ticket_id => scalar(youtrack()->get_ticket_id($text)),
        result    => $data,
    };
}

sub text_check_ticket {
    my ($r) = @_;
    printf("Ticket id: %s\n", $r->{ticket_id} // 'none found');
    result_line($r->{type} eq 'pr_title' ? 'PR title' : 'Commit', $r->{result});
}

# ============================================================================ #
# check-pr
# ============================================================================ #

sub cmd_check_pr {
    my (@args) = @_;
    my %opt;
    GetOptionsFromArray(\@args, \%opt, 'queue') or usage();

    my ($owner, $repo, $number) = (($args[0] // '') =~ m{^([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)#(\d+)$})
      or usage();

    my $gt = github();
    my ($pr) = $gt->get_api_response($gt->api_path('repos', $owner, $repo, 'pulls', $number));
    die "Pull request $owner/$repo#$number not found\n" if (ref($pr) ne 'HASH');

    my $commits_url = $gt->api_path('repos', $owner, $repo, 'pulls', $number, 'commits');
    my $commits     = $gt->fetch_all_commits($commits_url) or die "Failed to get the pull request commits\n";

    my $head_sha = $pr->{head}{sha};
    my $base     = $pr->{base}{ref};
    if (!grep { $_->{sha} eq $head_sha } @{$commits}) {
        my ($head) = $gt->get_commit($owner, $repo, $head_sha);
        push(@{$commits}, $head) if (ref($head) eq 'HASH');
    }

    my $title = {message => $pr->{title}, base_branch => $base, git_link => $pr->{html_url}};
    my $ok    = 1;
    my @rows;

    foreach my $commit (@{$commits}) {
        my $message = $commit->{commit}{message} // '';
        my $is_head = $commit->{sha} eq $head_sha;
        my $result  = result_data(checker()->evaluate_commit({message => $message}, $is_head ? [$title] : undef));

        $ok = 0 if ($result->{state} ne 'success');
        push(@rows, {sha => $commit->{sha}, head => bool($is_head), message => (split(/\n/, $message))[0] // '', result => $result});
    }

    my ($state, $epoch) = $gt->get_check_state($owner, $repo, $head_sha, ($gt->is_app and !$ENV{DISABLE_CHECK_API}));

    if ($opt{queue}) {
        Store::init_schema();
        Store::add_pull_request($repo, $commits_url, $pr->{html_url}, $head_sha);
    }

    return {
        ok          => $ok,
        pull_request => {url => $pr->{html_url}, title => $pr->{title}, base => $base, state => $pr->{state}, head => $head_sha},
        title       => result_data(checker()->evaluate_title($title)),
        commits     => \@rows,
        posted      => {state => $state || undef, updated => iso($epoch)},
        queued      => bool($opt{queue}),
    };
}

sub text_check_pr {
    my ($r) = @_;
    my $pr = $r->{pull_request};
    print "$pr->{url}\n  Title: $pr->{title}\n  Base: $pr->{base}, State: $pr->{state}, Head: $pr->{head}\n\n";

    result_line('PR title', $r->{title});
    foreach my $c (@{$r->{commits}}) {
        printf("\n  %s%s  %s\n", substr($c->{sha}, 0, 10), $c->{head} ? ' (head)' : '', $c->{message});
        result_line('Result', $c->{result});
    }

    printf("\nPosted on head commit: %s (%s)\n", $r->{posted}{state} // 'nothing', $r->{posted}{updated} // '-');
    print "Queued, the service re-checks it within a few seconds\n" if ($r->{queued});
}

# ============================================================================ #
# deliveries / redeliver
# ============================================================================ #

sub cmd_deliveries {
    my (@args) = @_;
    my %opt = (since => '6h');
    GetOptionsFromArray(\@args, \%opt, 'failed', 'since=s') or usage();

    my $deliveries = github()->get_hook_deliveries(time - duration($opt{since}))
      or die "Failed to get web hook deliveries (needs github app authentication)\n";

    my %delivered = map { $_->{guid} => 1 } grep { Redelivery::is_success($_) } @{$deliveries};

    my @list;
    foreach my $d (@{$deliveries}) {
        my $resolved = (Redelivery::is_success($d) or $delivered{$d->{guid}}) ? 1 : 0;
        next if ($opt{failed} and $resolved);
        push(@list, {
            id           => $d->{id},
            guid         => $d->{guid},
            delivered_at => $d->{delivered_at},
            event        => $d->{event},
            action       => $d->{action},
            status_code  => $d->{status_code},
            redelivery   => bool($d->{redelivery}),
            delivered    => bool($resolved),
        });
    }

    my $undelivered = grep { !$_->{delivered} } @list;
    return {ok => !$undelivered, since => $opt{since}, count => scalar(@list), undelivered => $undelivered, deliveries => \@list};
}

sub text_deliveries {
    my ($r) = @_;
    foreach my $d (@{$r->{deliveries}}) {
        printf("%-12s %s  %-28s %-4s %s%s\n",
            $d->{id}, $d->{delivered_at} // '', join('.', grep {$_} $d->{event}, $d->{action}),
            $d->{status_code} // 0, $d->{guid}, $d->{redelivery} ? ' (redelivery)' : '');
    }
    print "$r->{count} delivery(s), $r->{undelivered} not delivered\n";
}

sub cmd_redeliver {
    my (@args) = @_;
    my %opt;
    GetOptionsFromArray(\@args, \%opt, 'failed') or usage();

    if ($opt{failed}) {
        Store::init_schema();
        my $count = Redelivery->new(github => github(), logger => Mojo::Log->new(level => 'info'))->run;
        return {ok => 1, redelivered => $count};
    }

    my $id = $args[0] // usage();
    my $res = github()->redeliver_hook($id);
    return {ok => $res->is_success, delivery_id => $id, redelivered => $res->is_success ? 1 : 0,
        ($res->is_success ? () : (error => $res->status_line))};
}

sub text_redeliver {
    my ($r) = @_;
    if (defined $r->{delivery_id}) {
        print $r->{ok} ? "Delivery $r->{delivery_id} redelivered\n" : "Redelivery failed: $r->{error}\n";
        return;
    }
    print "$r->{redelivered} delivery(s) redelivered\n";
}

# ============================================================================ #
# queue
# ============================================================================ #

sub cmd_queue {
    my ($action, $row_id) = @_;

    if (($action // '') eq 'drop') {
        usage() if (($row_id // '') !~ /^\d+$/);
        my $rows = Store::delete_queue_row($row_id);
        return {ok => $rows > 0, action => 'drop', row_id => $row_id + 0, removed => bool($rows > 0)};
    }

    usage() if (defined $action);

    my @entries;
    foreach my $row (@{Store::get_pull_requests()}, @{Store::get_commits()}) {
        my %entry = (row_id => $row->{row_id}, project => $row->{project}, age_secs => age_secs($row->{created_epoch}));

        if ($row->{event_type} eq 'pull_request') {
            @entry{qw(type pull_request head)} = ('pull_request', $row->{git_link}, $row->{commit_id});
        }
        elsif (($row->{commit_id} // '') =~ /^PRT\|(.*)\|(\w+)$/) {
            @entry{qw(type base head title pull_request)} = ('pr_title', $1, $2, $row->{message}, $row->{git_link});
        }
        else {
            @entry{qw(type sha message pull_request)} =
              ('commit', $row->{commit_id}, (split(/\n/, $row->{message} // ''))[0], $row->{git_link});
        }
        push(@entries, \%entry);
    }

    return {ok => 1, count => scalar(@entries), entries => \@entries};
}

sub text_queue {
    my ($r) = @_;
    if (($r->{action} // '') eq 'drop') {
        print $r->{removed} ? "Removed queue entry $r->{row_id}\n" : "No queue entry $r->{row_id}\n";
        return;
    }

    foreach my $e (@{$r->{entries}}) {
        my $what = $e->{type} eq 'pull_request' ? "PR $e->{pull_request}"
          : $e->{type} eq 'pr_title' ? "PR title ($e->{base}) $e->{title}"
          :                            "commit $e->{sha} $e->{message}";
        printf("%-6s %-24s %-8s %s\n", $e->{row_id}, $e->{project}, age($e->{age_secs}), $what);
    }
    print "$r->{count} entry(s)\n";
}

# ============================================================================ #
# sync
# ============================================================================ #

sub cmd_sync {
    my ($repo, $branch) = @_;
    usage() if (($repo // '') !~ /^[A-Za-z0-9_.-]+$/);

    my $gt       = github();
    my $branches = $gt->get_repo_branches($repo) or die "Failed to get branches of $repo\n";
    my $git_url  = ($ENV{GITHUB_GIT_URL} || 'https://github.com') =~ s{/+$}{}r;

    Store::init_schema();
    my @updated;
    foreach my $b (@{$branches}) {
        next if (defined $branch and $b->{name} ne $branch);
        Store::update_repo_state(
            {
                project          => $repo,
                ref              => "refs/heads/$b->{name}",
                latest_commit_id => $b->{commit}{sha},
                last_updated     => time,
                remote_url       => "$git_url/" . $gt->org . "/$repo.git",
            }
        );
        push(@updated, {branch => $b->{name}, sha => $b->{commit}{sha}});
    }

    return {ok => scalar(@updated) > 0, repo => $repo, branches => \@updated};
}

sub text_sync {
    my ($r) = @_;
    printf("%-30s %s\n", $_->{branch}, $_->{sha}) for (@{$r->{branches}});
    printf("%d branch(es) updated, git sync clients fetch them on their next re-sync\n", scalar(@{$r->{branches}}));
}
