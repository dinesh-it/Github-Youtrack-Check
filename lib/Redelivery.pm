package Redelivery;

# Redelivers failed GitHub App web hook deliveries.
#
# Each run scans the deliveries made since the previous run: a failed delivery
# is recorded by its guid, a successful one (eg: an earlier redelivery) clears
# it. Recorded failures are redelivered with backoff (5m, 10m, 20m ... max 6h)
# until one succeeds or max attempts is reached. GitHub keeps deliveries for 3
# days, older ones can not be redelivered.

use strict;
use warnings;
use List::Util qw(min max);
use Store;

use constant RETENTION => 3 * 24 * 3600;

# ============================================================================ #

sub new {
    my ($class, %args) = @_;

    return bless {
        github       => $args{github},
        logger       => $args{logger},
        max_attempts => $args{max_attempts} || $ENV{REDELIVERY_MAX_ATTEMPTS} || 10,
        lookback     => $args{lookback}     || $ENV{REDELIVERY_LOOKBACK}     || 6 * 3600,
        base_delay   => $args{base_delay}   || 300,
        max_delay    => $args{max_delay}    || 6 * 3600,
    }, $class;
}

# ============================================================================ #

sub is_success {
    my ($delivery) = @_;
    my $code = $delivery->{status_code} // 0;
    return ($code >= 200 and $code < 300) ? 1 : 0;
}

# ============================================================================ #

# Scan new deliveries and redeliver the due failures, returns the number of
# redeliveries requested
sub run {
    my ($self) = @_;

    my $gt  = $self->{github};
    my $log = $self->{logger};

    return 0 if (!$gt->is_app);

    my $now = time;
    $self->scan($now);

    my $count = 0;
    foreach my $row (@{Store::redelivery_due($now, $self->{max_attempts})}) {
        $count++ if ($self->redeliver($row, $now));
    }

    Store::redelivery_cleanup($now - RETENTION - 24 * 3600);

    return $count;
}

# ============================================================================ #

# Record failures / successes of the deliveries made since the last scan
sub scan {
    my ($self, $now) = @_;

    my $last  = Store::get_state_epoch('redelivery_scan');
    my $since = $last ? $last - 120 : $now - $self->{lookback};
    $since = max($since, $now - RETENTION);

    my ($deliveries, $truncated) = $self->{github}->get_hook_deliveries($since);
    if ($truncated) {
        $self->{logger}->error("More web hook deliveries since the last scan than fetched, older failures are not redelivered"
              . " - list them with ci-doctor.pl deliveries --failed --since 3d");
    }

    if (!$deliveries) {
        $self->{logger}->error("Failed to get web hook deliveries from github, will try again");
        return;
    }

    # Oldest first, so a later success clears an earlier failure
    foreach my $delivery (sort { $a->{id} <=> $b->{id} } @{$deliveries}) {
        next if (!$delivery->{guid} or !$delivery->{id});

        if (is_success($delivery)) {
            Store::redelivery_succeeded($delivery->{guid});
            next;
        }

        Store::redelivery_failed($delivery, $now);
    }

    Store::set_state_epoch('redelivery_scan', $now);
    return scalar(@{$deliveries});
}

# ============================================================================ #

sub redeliver {
    my ($self, $row, $now) = @_;

    my $log  = $self->{logger};
    my $desc = ($row->{event} // 'unknown') . " delivery $row->{guid} (last status " . ($row->{status_code} // 0) . ")";

    if ($row->{first_failed_epoch} < $now - RETENTION) {
        $log->error("Web hook $desc is older than github keeps deliveries, giving up");
        Store::redelivery_succeeded($row->{guid});
        return 0;
    }

    my $res = $self->{github}->redeliver_hook($row->{delivery_id});

    if (!$res->is_success) {
        if ($self->{github}->is_retryable($res)) {
            $log->warn("Redelivery of web hook $desc failed, will try again");
        }
        else {
            $log->error("Redelivery of web hook $desc rejected by github: " . $res->status_line . ", giving up");
            Store::redelivery_succeeded($row->{guid});
        }
        return 0;
    }

    my $attempts = $row->{attempts} + 1;
    my $next     = $now + min($self->{max_delay}, $self->{base_delay} * 2**($attempts - 1));
    Store::redelivery_attempted($row->{guid}, $attempts, $next);

    $log->info("Redelivered web hook $desc, attempt $attempts of $self->{max_attempts}");
    if ($attempts >= $self->{max_attempts}) {
        $log->error("Web hook $desc reached max redelivery attempts, check the web hook errors in github");
    }

    return 1;
}

# ============================================================================ #

1;
