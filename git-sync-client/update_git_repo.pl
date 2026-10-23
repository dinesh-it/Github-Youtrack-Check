#!/usr/bin/env perl

#
# update_git_repo.pl
#
# Developed by Dinesh Dharmalingam <dinesh@exceleron.com>
# Copyright (c) 2020 Exceleron Software LLC.,
# All rights reserved.
#
# Git sync client - listens on the micro-ci websocket and fetches the
# configured branches into local repositories whenever they change on github.
#
# Changelog:
# 2020-09-23 - created
# 2026-10-23 - authenticated handshake, verified + encrypted messages
#
use strict;
use warnings;
use Mojo::UserAgent;
use Mojo::IOLoop;
use Mojo::JSON qw(decode_json from_json);
use Config::Any;
use List::Util qw(min);

use FindBin;
use lib "$FindBin::Bin/..", $FindBin::Bin;
use SecureChannel;

$| = 1;

my $config  = load_config();
my $channel = SecureChannel->new(secret => $config->{secret});
delete $config->{secret};

# Keep the secret away from git and its hooks / helpers
delete $ENV{GH_WEBSOCKET_SECRET};

my $ua = Mojo::UserAgent->new;
$ua->inactivity_timeout($config->{inactive_timeout} // 3600);
$ua->ca($config->{ca}) if ($config->{ca});

my $reconnect_delay = 1;
my $reconnect_timer;

# ============================================================================ #

sub log_msg {
    my ($level, $msg) = @_;
    my $ts = scalar localtime;
    print "$ts [$level] $msg\n";
}

sub debug {
    log_msg('DEBUG', $_[0]) if ($config->{debug});
}

# ============================================================================ #

sub listen_github_hook {
    $reconnect_timer = undef;

    $ua->websocket(
        $config->{server_url} => sub {
            my ($ua, $tx) = @_;

            if (!$tx->is_websocket) {
                my $err = $tx->error // {};
                log_msg('ERROR', "WebSocket handshake failed: " . join(' ', grep {defined} $err->{code}, $err->{message}));
                schedule_reconnect();
                return;
            }

            my $authed = 0;

            $tx->on(
                message => sub {
                    my ($tx, $msg) = @_;
                    if ($authed) {
                        handle_message($msg);
                    }
                    else {
                        $authed = handle_handshake($tx, $msg);
                    }
                }
            );

            # Re-Connect on connection close
            $tx->on(
                finish => sub {
                    my ($tx, $code, $reason) = @_;
                    log_msg('INFO', "Connection closed (" . join(' ', grep {defined} $code, $reason) . "), Re-Connecting...");
                    schedule_reconnect();
                }
            );
        }
    );
}

# ============================================================================ #

sub schedule_reconnect {
    return if ($reconnect_timer);

    my $delay = $reconnect_delay;
    $reconnect_delay = min(60, $reconnect_delay * 2);

    log_msg('INFO', "Will try connecting again in $delay sec(s)...");
    $reconnect_timer = Mojo::IOLoop->timer($delay => \&listen_github_hook);
}

# ============================================================================ #

# Returns 1 once the server accepted our authentication
sub handle_handshake {
    my ($tx, $msg) = @_;

    my $data = eval { from_json($msg) };
    my $type = ref($data) eq 'HASH' ? ($data->{type} // '') : '';

    if ($type eq 'challenge' and ($data->{challenge} // '') =~ /^[0-9a-f]{64}$/) {
        my @repos = sort keys %{$config->{repo}};
        $tx->send(
            {
                json => {
                    type     => 'auth',
                    repos    => \@repos,
                    response => $channel->auth_response($data->{challenge}, join(',', @repos)),
                }
            }
        );
        return 0;
    }

    if ($type eq 'ready') {
        $reconnect_delay = 1;
        log_msg('INFO', "Connected! Getting latest info...");
        $tx->send('give-latest');
        return 1;
    }

    log_msg('ERROR', "Unexpected message from server during handshake, closing connection");
    $tx->finish;
    return 0;
}

# ============================================================================ #

sub handle_message {
    my ($msg) = @_;

    return if (!defined $msg or !length $msg);

    my $plain = $channel->unseal($msg);
    if (!defined $plain) {
        log_msg('ERROR', "Discarding message that failed verification, please check the GH_WEBSOCKET_SECRET");
        return;
    }

    my $data = eval { decode_json($plain) };
    if (ref($data) ne 'HASH' or ($data->{type} // '') ne 'state') {
        log_msg('ERROR', "Discarding message with invalid format");
        return;
    }

    my $age = abs(time - ($data->{ts} // 0));
    if ($age > $config->{max_message_age}) {
        log_msg('ERROR', "Discarding message which is $age secs old, please check the clock on this host");
        return;
    }

    debug("PushEvent received: $data->{project} " . ($data->{ref} // '') . ' ' . ($data->{sha} // ''));

    check_for_change($data);
}

# ============================================================================ #

sub check_for_change {
    my ($data) = @_;

    my $project    = $data->{project} // '';
    my $remote_ref = $data->{ref}     // '';
    my $prj_config = $config->{repo}{$project};

    if (!$prj_config) {
        debug("$project repo not configured, ignoring this event");
        return;
    }

    my $ref_config = $prj_config->{$remote_ref};
    if (ref($ref_config) ne 'HASH') {
        debug("$remote_ref for $project not configured, ignoring this event");
        return;
    }

    if (($data->{sha} // '') !~ /\A[0-9a-f]{40}(?:[0-9a-f]{24})?\z/) {
        log_msg('ERROR', "Invalid commit id received for $project $remote_ref");
        return;
    }

    my $local_path = $prj_config->{local_path};
    if (!-d $local_path) {
        log_msg('ERROR', "$local_path not exist");
        return;
    }

    my $local_ref = local_ref($remote_ref, $ref_config);

    my ($status, $last_commit) = run_git({}, 'git', '-C', $local_path, 'rev-parse', '--verify', '--quiet', "$local_ref^{commit}");
    chomp($last_commit);
    $last_commit = '' if ($status != 0);

    if ($last_commit eq $data->{sha}) {
        log_msg('INFO', "$project $remote_ref - no update required");
        return;
    }

    log_msg('INFO', "Commit hash mismatch found for $project $remote_ref");
    fetch_repo($prj_config, $ref_config, $data, $local_ref);
}

# ============================================================================ #

sub fetch_repo {
    my ($prj_config, $ref_config, $data, $local_ref) = @_;

    my $remote_ref = $data->{ref};
    my $remote_url = $prj_config->{remote_url} // $prj_config->{remote_path};

    # Remote URL from the server is only accepted for the allowed github hosts
    if (!$remote_url) {
        $remote_url = $data->{remote_url} // '';
        my $hosts  = join('|', map {quotemeta} @{$config->{allowed_remote_hosts}});
        my $owners = join('|', map {quotemeta} @{$config->{allowed_owners}});
        if ($remote_url !~ m{\Ahttps://(?:$hosts)/(?:$owners)/\Q$data->{project}\E\.git\z}i) {
            log_msg('ERROR', "Refusing to fetch from unexpected remote URL for $data->{project}");
            return;
        }
    }

    my $force_fetch = $ref_config->{force_fetch} // $prj_config->{force_fetch};
    my $refspec     = ($force_fetch ? '+' : '') . "$remote_ref:$local_ref";

    my @cmd = (
        'git', '-C', $prj_config->{local_path},

        # Do not let any configured credential helper store our token
        '-c', 'credential.helper=',

        # Abort stalled transfers instead of blocking forever
        '-c', 'http.lowSpeedLimit=1000', '-c', 'http.lowSpeedTime=120',

        # Never follow redirects to other hosts with our credentials
        '-c', 'http.followRedirects=false',
    );

    my %env = (GIT_TERMINAL_PROMPT => 0);
    my $token = $data->{token};

    # The token is handed over via env to a credential helper, so it never
    # shows up in the process list, git config or FETCH_HEAD
    # The helper only answers for the host of the remote URL
    if ($token and $remote_url =~ m{\Ahttps://([^/:]+)}) {
        $env{GHYT_GIT_TOKEN} = $token;
        $env{GHYT_GIT_HOST}  = lc($1);
        push(@cmd, '-c',
                'credential.helper=!f() { test "$1" = get || return 0; ok=; '
              . 'while read -r l; do test "$l" = "host=$GHYT_GIT_HOST" && ok=1; done; '
              . 'test -n "$ok" && echo username=x-access-token && echo "password=$GHYT_GIT_TOKEN"; }; f');
    }

    push(@cmd, 'fetch', '--', $remote_url, $refspec);

    log_msg('INFO', "Running git fetch $remote_url $refspec");
    my ($status, $output) = run_git(\%env, @cmd);

    $output =~ s/\Q$token\E/***/g if ($token);
    if ($status != 0) {
        log_msg('ERROR', "Git fetch failed ($status): $output");
        return;
    }

    debug($output) if ($output);
    log_msg('INFO', "Done!");
}

# ============================================================================ #

sub local_ref {
    my ($remote_ref, $ref_config) = @_;
    my $local = $ref_config->{local_ref} // $ref_config->{local_branch} // $remote_ref;
    $local = "refs/heads/$local" if ($local !~ m{^refs/});
    return $local;
}

# ============================================================================ #

# Run a command without shell, returns (exit code, combined output)
sub run_git {
    my ($env, @cmd) = @_;

    my $pid = open(my $fh, '-|');
    if (!defined $pid) {
        return (-1, "fork failed: $!");
    }

    if (!$pid) {
        @ENV{keys %{$env}} = values %{$env};
        open(STDERR, '>&', \*STDOUT);
        { no warnings "exec"; exec {$cmd[0]} @cmd; }
        print "exec failed: $!\n";
        exit(127);
    }

    local $/ = undef;
    my $output = <$fh> // '';
    close($fh);

    return ($? >> 8, $output);
}

# ============================================================================ #

sub valid_ref {
    my ($ref) = @_;
    return ($ref =~ m{^refs/[A-Za-z0-9_./-]+$} and $ref !~ m{\.\.|//|/\.|\.lock$|/$}) ? 1 : 0;
}

# ============================================================================ #

sub load_config {
    my $file = $ENV{EX_GITHOOK_CONFIG_FILE};

    if (!$file or !-e $file) {
        die "Please set EX_GITHOOK_CONFIG_FILE env with config file path\n";
    }

    print "Reading config from $file\n";
    my $cfg = Config::Any->load_files({files => [$file], use_ext => 1, flatten_to_hash => 1})->{$file};
    die "Failed to read config file $file\n" if (ref($cfg) ne 'HASH');

    $cfg->{debug} = $ENV{DEBUG} if ($ENV{DEBUG});

    if (!$cfg->{server_url}) {
        die "server_url (or server_host) is required in the config\n" if (!$cfg->{server_host});
        $cfg->{server_url} = "ws://$cfg->{server_host}/githubpush";
    }
    die "server_url must start with ws:// or wss://\n" if ($cfg->{server_url} !~ m{^wss?://});

    my $secret_in_file = (!$ENV{GH_WEBSOCKET_SECRET} and ($cfg->{secret} or $cfg->{password}));
    $cfg->{secret} = $ENV{GH_WEBSOCKET_SECRET} || $cfg->{secret} || delete $cfg->{password};
    die "GH_WEBSOCKET_SECRET env is required\n" if (!$cfg->{secret});

    if ($secret_in_file and ((stat $file)[2] & 0077)) {
        print "WARNING: $file contains the secret and is readable by other users, chmod 600 it\n";
    }

    $cfg->{allowed_remote_hosts} //= ['github.com'];
    $cfg->{allowed_owners}       //= ['exceleron'];
    $cfg->{max_message_age}      //= 900;

    die "No repo configured\n" if (ref($cfg->{repo}) ne 'HASH' or !%{$cfg->{repo}});

    foreach my $name (keys %{$cfg->{repo}}) {
        die "Invalid repo name '$name' in config\n" if ($name !~ /^[A-Za-z0-9_.-]{1,100}$/);

        my $repo = $cfg->{repo}{$name};
        die "local_path is required for repo $name\n" if (!$repo->{local_path});

        foreach my $ref (grep {m{^refs/}} keys %{$repo}) {
            die "Invalid ref '$ref' for repo $name\n" if (!valid_ref($ref));
            die "Invalid local ref for $name $ref\n"  if (!valid_ref(local_ref($ref, $repo->{$ref} // {})));
        }
    }

    print "Will be connecting to: $cfg->{server_url}\n";
    if ($cfg->{server_url} =~ m{^ws://}) {
        print "WARNING: server_url is not using TLS (wss://), messages are still encrypted and authenticated with the shared secret\n";
    }
    print "inactivity_timeout set to " . ($cfg->{inactive_timeout} // 3600) . "\n";

    return $cfg;
}

# ============================================================================ #

listen_github_hook();
Mojo::IOLoop->start unless Mojo::IOLoop->is_running;
