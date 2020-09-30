#!/usr/bin/env perl

#
# update_git_repo.pl
#
# Developed by Dinesh Dharmalingam <dinesh@exceleron.com>
# Copyright (c) 2020 Exceleron Software LLC.,
# All rights reserved.
#
# Changelog:
# 2020-09-23 - created
#
use strict;
use warnings;
use Mojo::UserAgent;
use Mojo::IOLoop;
use Config::Any;
use Crypt::Lite;
use Git;

my $ua = Mojo::UserAgent->new;
my $crypt = Crypt::Lite->new( debug => 0, encoding => 'hex8' );
my $config = {};

# ============================================================================ #

sub listen_github_hook {

    my $remote_host = $config->{server_host};
    my $tx = $ua->websocket("ws://$remote_host/githubpush" => sub {
            my ($ua, $tx) = @_;

            # Try every second when socket connection not availalbe
            if(!$tx->is_websocket) {
                print "WebSocket handshake failed! Will try connecting again in a second...\n";
                sleep(1);
                listen_github_hook();
            }

            $tx->on(message => sub {
                    my ($tx, $msg) = @_;
                    print "WebSocket message: $msg\n" if($config->{debug});
                    parse_message($tx, $msg);
                });

            # Re-Connect on connection close
            $tx->on(finish => sub {
                    my ($tx, $res) = @_;
                    print "Connection closed, Re-Connecting...\n";
                    listen_github_hook();
                });

            # Ask for latest update when connection initiates
            if($tx->is_websocket) {
                print "Connected! Getting latest info...\n";
                $tx->send('give-latest');
            }
        });
}

# ============================================================================ #

sub parse_message {
    my ($self, $msg) = @_;

    return if(!$msg);

    my $password = $ENV{GH_WEBSOCKET_SECRET} //= $config->{password};

    if($password) {
        my $dec_msg = $crypt->decrypt($msg, $password);

        if(!$msg) {
            print "ERROR: Failed to decrypt the message, please check the GH_WEBSOCKET_SECRET env\n";
            print "Msg: $msg\n";
            return;
        }
        $msg = $dec_msg;
    }

    my $pipe_count = () = $msg =~ /\|/g;

    if($pipe_count != 5) {
        print "ERROR: Invalid message format, Msg: $msg\n";
        return;
    }

    print "PushEvent received: $msg\n" if($config->{debug});

    my ($project, $ref, $latest_commit_id, $last_updated, $remote_url, $updated_epoch) = split('\|', $msg);

    my $data = {
        project => $project,
        ref => $ref,
        latest_commit_id => $latest_commit_id,
        last_updated => $last_updated,
        remote_url => $remote_url,
        updated_epoch => $updated_epoch,
    };

    check_for_change($self, $data, $msg);
}

# ============================================================================ #

sub check_for_change {
    my ($self, $data, $msg) = @_;

    my $prj_config = $config->{repo}{$data->{project}};

    if(!$prj_config) {
        print "$data->{project} repo not configured, ignoring this event\n" if($config->{debug});
        return;
    }

    my $remote_ref = $data->{ref};

    if(!$prj_config->{$remote_ref}) {
        print "$remote_ref for $data->{project} not configured, ignoring this event\n" if($config->{debug});
        return;
    }

    if(not -d $prj_config->{local_path}) {
        print "ERROR: $prj_config->{local_path} not exist\n";
        return;
    }

    print "Configured PushEvent received: $msg\n" if(!$config->{debug});

    my $repo = Git->repository(Directory => $prj_config->{local_path});

    my $local_ref = $prj_config->{$remote_ref}->{local_ref} //= $remote_ref;

    my $last_commit = '';
    eval {
        $last_commit = $repo->command_oneline('log', $local_ref, '--pretty=%H', '-n 1');
    };
    if($@) {
        print "ERROR: Git log failed - $@\n";
    }

    if(!$last_commit or $last_commit ne $data->{latest_commit_id}) {
        print "Commit hash mismatch found for $data->{project} $remote_ref\n";
        fetch_repo($repo, $prj_config, $data);
    }
    else {
        print "$data->{project} $remote_ref - no update required\n";
    }
}

# ============================================================================ #

sub fetch_repo {
    my ($repo, $config, $data) = @_;

    my $remote_url = $config->{remote_url} //= $data->{remote_url};
    my $remote_ref = $data->{ref};
    my $local_ref = $config->{$remote_ref}{local_ref} //= $remote_ref;
    my $force_fetch = $config->{$remote_ref}->{force_fetch} //= $config->{force_fetch};

    my @fetch_command = ('fetch', $remote_url, "$local_ref:$remote_ref");

    if($force_fetch) {
        push(@fetch_command, '-f');
    }

    eval {
        print "Running git @fetch_command\n";
        $repo->command_oneline(\@fetch_command);
        print "Done!\n";
    };
    if($@) {
        print "ERROR: Git fetch failed - $@\n";
    }
}

# ============================================================================ #

sub store_config {
    my $file = $ENV{EX_GITHOOK_CONFIG_FILE};

    if(!$file or not -e $file) {
        die "Please set EX_GITHOOK_CONFIG_FILE env with config file path\n";
    }

    print "Reading config from $file\n";
    my $cfg = Config::Any->load_files({ files => [$file], use_ext => 1 });

    $config = $cfg->[0]->{$file};

    $config->{debug} = $ENV{DEBUG} if($ENV{DEBUG});

    print "Will be connecting to: ws://$config->{server_host}/githubpush\n";
    print "inactivity_timeout set to $config->{inactive_timeout}\n";
}

# ============================================================================ #

store_config();

$ua = $ua->inactivity_timeout($config->{inactive_timeout}) if($config->{inactive_timeout});

listen_github_hook();
Mojo::IOLoop->start unless Mojo::IOLoop->is_running;
