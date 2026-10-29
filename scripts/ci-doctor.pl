#!/usr/bin/env perl

# ci-doctor - inspect and fix the youtrack CI check service from the terminal
#
# Run it on the service host as the service user with the service env, eg:
#   sudo -u github-webhook-listener scripts/ci-doctor.pl status
# The env file /etc/pams/service/github-webhook-listener/env (or --env-file)
# is loaded for any ENV not already set.

use strict;
use warnings;
use Getopt::Long qw(GetOptionsFromArray);
use HTTP::Date qw(str2time);
use LWP::UserAgent;
use Mojo::Log;
use POSIX qw(strftime);

use FindBin;
use lib "$FindBin::Bin/../lib";
use Github;
use Youtrack;
use Store;
use Checker;
use Redelivery;

$| = 1;

my $DEFAULT_ENV_FILE = '/etc/pams/service/github-webhook-listener/env';

my %commands = (
    'status'       => \&cmd_status,
    'check-ticket' => \&cmd_check_ticket,
    'check-pr'     => \&cmd_check_pr,
    'deliveries'   => \&cmd_deliveries,
    'redeliver'    => \&cmd_redeliver,
    'queue'        => \&cmd_queue,
    'sync'         => \&cmd_sync,
);

my @args = @ARGV;
my %global;
Getopt::Long::Configure('pass_through', 'require_order');
GetOptionsFromArray(\@args, \%global, 'env-file=s', 'debug', 'help|h') or usage();
Getopt::Long::Configure('no_pass_through');

my $command = shift(@args) // '';
usage() if ($global{help} or !$commands{$command});

load_env($global{'env-file'});

my $log = Mojo::Log->new(level => $global{debug} ? 'debug' : 'warn');

exit($commands{$command}->(@args) ? 0 : 1);

# ============================================================================ #

sub usage {
    print <<'EOF';
Usage: ci-doctor.pl [--env-file FILE] [--debug] <command> [options]

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
EOF
    exit 2;
}

# ============================================================================ #

# Load KEY=VALUE lines of a systemd style env file, existing ENV wins
sub load_env {
    my ($file) = @_;

    $file //= $DEFAULT_ENV_FILE if (-r $DEFAULT_ENV_FILE);
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

sub github {
    state_obj(
        github => sub {
            Github->new(private_key_file => $ENV{GITHUB_APP_KEY_FILE}, private_key => $ENV{GITHUB_APP_KEY}, logger => $log);
        }
    );
}

sub youtrack {
    state_obj(youtrack => sub { Youtrack->new(logger => $log) });
}

sub checker {
    state_obj(checker => sub { Checker->new(youtrack => youtrack(), logger => $log, pr_branch_check => $ENV{PR_BRANCH_YT_CHECK}) });
}

my %objects;

sub state_obj {
    my ($name, $build) = @_;
    return $objects{$name} //= $build->();
}

# ============================================================================ #

sub age {
    my ($epoch) = @_;
    return 'never' if (!$epoch);
    my $secs = time - $epoch;
    return "${secs}s ago"                if ($secs < 120);
    return int($secs / 60) . "m ago"     if ($secs < 7200);
    return int($secs / 3600) . "h ago"   if ($secs < 172800);
    return int($secs / 86400) . "d ago";
}

sub iso {
    return strftime('%Y-%m-%d %H:%M:%S', localtime(shift));
}

sub duration {
    my ($text) = @_;
    my ($n, $unit) = ($text =~ /^(\d+)([smhd]?)$/) or die "Invalid duration '$text', eg: 30m, 6h, 2d\n";
    return $n * {s => 1, m => 60, h => 3600, d => 86400, '' => 1}->{$unit};
}

sub result_line {
    my ($label, $result) = @_;
    if (!ref($result)) {
        printf("  %-12s WAIT     YouTrack not reachable, the service retries later\n", $label);
        return;
    }
    printf("  %-12s %-8s %s\n", $label, uc($result->{state}), $result->{desc} // '');
    printf("  %-12s          %s\n", '', $result->{link}) if ($result->{link});
}

# ============================================================================ #
# Commands
# ============================================================================ #

sub cmd_status {
    my (@args) = @_;
    my %opt = (url => 'http://localhost/ghyt-ci');
    GetOptionsFromArray(\@args, \%opt, 'url=s') or usage();

    print "Service\n";
    my $res = LWP::UserAgent->new(timeout => 5)->get($opt{url});
    printf("  Probe        %s %s\n", $res->code, $res->is_success ? 'ok' : ($res->decoded_content // $res->status_line));
    printf("  Spooler      last run %s\n", age(Store::last_alive()));
    printf("  Database     %s\n", Store::db_file());

    my $prs     = Store::get_pull_requests();
    my $commits = Store::get_commits();
    my @titles  = grep { ($_->{commit_id} // '') =~ /^PRT\|/ } @{$commits};
    my @oldest  = sort { $a <=> $b } map { $_->{created_epoch} } @{$prs}, @{$commits};

    print "\nQueue\n";
    printf("  Pull requests %d, commits %d, PR titles %d, oldest %s\n",
        scalar(@{$prs}), @{$commits} - @titles, scalar(@titles), @oldest ? age($oldest[0]) : '-');

    print "\nWeb hook redelivery\n";
    printf("  Last scan    %s\n", age(Store::get_state_epoch('redelivery_scan')));
    my $pending = Store::redelivery_list();
    printf("  Failed       %d\n", scalar(@{$pending}));
    foreach my $row (@{$pending}) {
        printf("    %-20s %-14s status %-4s attempts %d, next %s, failing since %s\n",
            $row->{guid}, $row->{event} // '', $row->{status_code} // 0, $row->{attempts},
            iso($row->{next_attempt_epoch}), age($row->{first_failed_epoch}));
    }

    return $res->is_success;
}

# ============================================================================ #

sub cmd_check_ticket {
    my (@args) = @_;
    my %opt;
    GetOptionsFromArray(\@args, \%opt, 'base=s') or usage();
    my $text = join(' ', @args);
    usage() if ($text eq '');

    my $yt_id = youtrack()->get_ticket_id($text);
    printf("Ticket id: %s\n", $yt_id // 'none found');

    my $result = defined $opt{base}
      ? checker()->evaluate_title({message => $text, base_branch => $opt{base}})
      : checker()->evaluate_commit({message => $text});

    result_line(defined $opt{base} ? 'PR title' : 'Commit', $result);
    return ref($result) && $result->{state} eq 'success';
}

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

    print "$pr->{html_url}\n";
    print "  Title: $pr->{title}\n  Base: $base, State: $pr->{state}, Head: $head_sha\n\n";

    my $title  = {message => $pr->{title}, base_branch => $base, git_link => $pr->{html_url}};
    my $all_ok = 1;

    result_line('PR title', checker()->evaluate_title($title));

    foreach my $commit (@{$commits}) {
        my $message = $commit->{commit}{message} // '';
        my $is_head = $commit->{sha} eq $head_sha;
        my $result  = checker()->evaluate_commit({message => $message}, $is_head ? [$title] : undef);

        my ($first_line) = split(/\n/, $message);
        printf("\n  %s%s  %s\n", substr($commit->{sha}, 0, 10), $is_head ? ' (head)' : '', $first_line // '');
        result_line('Result', $result);
        $all_ok = 0 if (!ref($result) or $result->{state} ne 'success');
    }

    my ($state, $epoch) = $gt->get_check_state($owner, $repo, $head_sha, ($gt->is_app and !$ENV{DISABLE_CHECK_API}));
    printf("\nPosted on head commit: %s (%s)\n", $state || 'nothing', age($epoch));

    if ($opt{queue}) {
        Store::init_schema();
        Store::add_pull_request($repo, $commits_url, $pr->{html_url}, $head_sha);
        print "Queued, the service re-checks it within a few seconds\n";
    }

    return $all_ok;
}

# ============================================================================ #

sub cmd_deliveries {
    my (@args) = @_;
    my %opt = (since => '6h');
    GetOptionsFromArray(\@args, \%opt, 'failed', 'since=s') or usage();

    my $deliveries = github()->get_hook_deliveries(time - duration($opt{since}))
      or die "Failed to get web hook deliveries (needs github app authentication)\n";

    my %delivered = map { $_->{guid} => 1 } grep { Redelivery::is_success($_) } @{$deliveries};

    my $count = 0;
    foreach my $d (@{$deliveries}) {
        next if ($opt{failed} and (Redelivery::is_success($d) or $delivered{$d->{guid}}));
        printf("%-12s %s  %-28s %-4s %s%s\n",
            $d->{id}, iso(str2time($d->{delivered_at}) || 0),
            join('.', grep {$_} $d->{event}, $d->{action}),
            $d->{status_code} // 0, $d->{guid}, $d->{redelivery} ? ' (redelivery)' : '');
        $count++;
    }

    print "$count delivery(s)\n";
    return 1;
}

# ============================================================================ #

sub cmd_redeliver {
    my (@args) = @_;
    my %opt;
    GetOptionsFromArray(\@args, \%opt, 'failed') or usage();

    if ($opt{failed}) {
        Store::init_schema();
        my $count = Redelivery->new(github => github(), logger => Mojo::Log->new(level => 'info'))->run;
        print "$count delivery(s) redelivered\n";
        return 1;
    }

    my $id = $args[0] // usage();
    my $res = github()->redeliver_hook($id);
    print $res->is_success ? "Delivery $id redelivered\n" : "Redelivery failed: " . $res->status_line . "\n";
    return $res->is_success;
}

# ============================================================================ #

sub cmd_queue {
    my ($action, $row_id) = @_;

    if (($action // '') eq 'drop') {
        usage() if (($row_id // '') !~ /^\d+$/);
        my $rows = Store::delete_queue_row($row_id);
        print $rows > 0 ? "Removed queue entry $row_id\n" : "No queue entry $row_id\n";
        return $rows > 0;
    }

    usage() if (defined $action);

    foreach my $row (@{Store::get_pull_requests()}, @{Store::get_commits()}) {
        my $what = $row->{event_type} eq 'pull_request'
          ? "PR $row->{git_link}"
          : (($row->{commit_id} // '') =~ /^PRT\|(.*)\|(\w+)$/ ? "PR title ($1) $row->{message}" : "commit $row->{commit_id}");
        my ($first_line) = split(/\n/, $what);
        printf("%-6s %-24s %-8s %s\n", $row->{row_id}, $row->{project}, age($row->{created_epoch}), $first_line);
    }

    return 1;
}

# ============================================================================ #

sub cmd_sync {
    my ($repo, $branch) = @_;
    usage() if (($repo // '') !~ /^[A-Za-z0-9_.-]+$/);

    my $gt       = github();
    my $branches = $gt->get_repo_branches($repo) or die "Failed to get branches of $repo\n";
    my $git_url  = ($ENV{GITHUB_GIT_URL} || 'https://github.com') =~ s{/+$}{}r;

    Store::init_schema();
    my $count = 0;
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
        printf("%-30s %s\n", $b->{name}, $b->{commit}{sha});
        $count++;
    }

    print "$count branch(es) updated, git sync clients fetch them on their next re-sync\n";
    return $count > 0;
}
