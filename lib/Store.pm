package Store;

# SQLite backed queue and state shared by the web hook service and the helper
# scripts. Schema changes must stay additive so an existing database file and
# the rows queued in it survive an upgrade.

use strict;
use warnings;
use DBI;

my $dbh;
my $dbh_pid = -1;

# ============================================================================ #

sub db_file {
    return $ENV{GITHUB_WEB_HOOK_DB} || '/tmp/github_web_hook.db';
}

# ============================================================================ #

sub dbh {
    return $dbh if ($dbh and $dbh_pid == $$ and $dbh->ping);

    my $file = db_file();
    my $user = $ENV{GITHUB_WEB_HOOK_DB_USER} // '';
    my $pass = $ENV{GITHUB_WEB_HOOK_DB_PWD}  // '';

    # Do not leave a world readable window while sqlite creates the file
    my $old_umask = umask(0027);
    $dbh = DBI->connect("DBI:SQLite:dbname=$file", $user, $pass, {RaiseError => 1, PrintError => 0, AutoCommit => 1});
    umask($old_umask);

    $dbh->sqlite_busy_timeout(10_000);
    $dbh_pid = $$;

    return $dbh;
}

# ============================================================================ #

sub init_schema {
    my $db = dbh();

    $db->do(
        q/CREATE TABLE IF NOT EXISTS GitPushEvent (
            event_type TEXT NOT NULL,
            project TEXT NOT NULL,
            owner TEXT NULL,
            commit_id TEXT NULL,
            message TEXT NOT NULL,
            git_link TEXT NULL,
            created_epoch INTEGER NOT NULL
        )/
    );

    $db->do(
        q/CREATE TABLE IF NOT EXISTS GitRepoState (
            project TEXT NOT NULL,
            ref TEXT NOT NULL,
            latest_commit_id TEXT NOT NULL,
            last_updated INTEGER NOT NULL,
            remote_url TEXT NOT NULL,
            updated_epoch INTEGER NOT NULL
        )/
    );

    $db->do(q/CREATE TABLE IF NOT EXISTS SpoolerState (name TEXT PRIMARY KEY, updated_epoch INTEGER NOT NULL)/);

    # Failed github web hook deliveries waiting for redelivery, by delivery guid
    $db->do(
        q/CREATE TABLE IF NOT EXISTS WebhookRedelivery (
            guid TEXT PRIMARY KEY,
            delivery_id INTEGER NOT NULL,
            event TEXT NULL,
            status_code INTEGER NULL,
            attempts INTEGER NOT NULL DEFAULT 0,
            next_attempt_epoch INTEGER NOT NULL,
            first_failed_epoch INTEGER NOT NULL,
            updated_epoch INTEGER NOT NULL
        )/
    );

    $db->do(q/CREATE INDEX IF NOT EXISTS idx_push_event_type ON GitPushEvent (event_type, created_epoch)/);
    $db->do(q/CREATE INDEX IF NOT EXISTS idx_push_event_commit ON GitPushEvent (project, commit_id)/);
    $db->do(q/CREATE INDEX IF NOT EXISTS idx_repo_state ON GitRepoState (project, ref)/);

    chmod(0640, db_file());

    return 1;
}

# ============================================================================ #
# Queue
# ============================================================================ #

sub add_commit {
    my ($project, $owner, $commit_id, $message, $git_link) = @_;
    return dbh()->do(
        q/INSERT INTO GitPushEvent (event_type, project, owner, commit_id, message, git_link, created_epoch)
          VALUES ('push', ?, ?, ?, ?, ?, ?)/, undef, $project, $owner, $commit_id, $message // '', $git_link, time
    );
}

# ============================================================================ #

# Queue a pull request, commits and title are fetched later by the spooler
# The head commit id (if known) is kept in commit_id, so a PR which cannot be
# verified can still be marked failed on its head commit
sub add_pull_request {
    my ($project, $commits_url, $pr_link, $head_sha) = @_;

    # Skip if the same pull request is already waiting in the queue
    my ($exists) = dbh()->selectrow_array(
        q/SELECT 1 FROM GitPushEvent WHERE event_type = 'pull_request' AND project = ? AND message = ? LIMIT 1/,
        undef, $project, $commits_url
    );

    if ($exists) {
        dbh()->do(q/UPDATE GitPushEvent SET commit_id = ? WHERE event_type = 'pull_request' AND project = ? AND message = ?/,
            undef, $head_sha, $project, $commits_url) if ($head_sha);
        return 1;
    }

    return dbh()->do(
        q/INSERT INTO GitPushEvent (event_type, project, owner, commit_id, message, git_link, created_epoch)
          VALUES ('pull_request', ?, NULL, ?, ?, ?, ?)/, undef, $project, $head_sha, $commits_url, $pr_link, time
    );
}

# ============================================================================ #

sub get_pull_requests {
    return dbh()->selectall_arrayref(
        q/SELECT rowid AS row_id, * FROM GitPushEvent WHERE event_type = 'pull_request' ORDER BY created_epoch ASC/,
        {Slice => {}});
}

# ============================================================================ #

sub delete_pull_request {
    my ($project, $commits_url) = @_;
    return dbh()->do(q/DELETE FROM GitPushEvent WHERE event_type = 'pull_request' AND project = ? AND message = ?/,
        undef, $project, $commits_url);
}

# ============================================================================ #

sub has_pending_pull_request {
    my ($project) = @_;
    my ($exists) = dbh()->selectrow_array(
        q/SELECT 1 FROM GitPushEvent WHERE event_type = 'pull_request' AND project = ? LIMIT 1/, undef, $project);
    return $exists ? 1 : 0;
}

# ============================================================================ #

sub get_commits {
    return dbh()->selectall_arrayref(
        q/SELECT rowid AS row_id, * FROM GitPushEvent WHERE event_type = 'push' ORDER BY created_epoch ASC/,
        {Slice => {}});
}

# ============================================================================ #

sub delete_commit {
    my ($project, $commit_id) = @_;
    return dbh()->do(q/DELETE FROM GitPushEvent WHERE event_type = 'push' AND project = ? AND commit_id = ?/,
        undef, $project, $commit_id);
}

# ============================================================================ #

# Remove one queue entry by its rowid (manual clean up)
sub delete_queue_row {
    my ($row_id) = @_;
    return dbh()->do(q/DELETE FROM GitPushEvent WHERE rowid = ?/, undef, $row_id);
}

# ============================================================================ #

sub txn {
    my ($code) = @_;
    my $db = dbh();
    $db->begin_work;
    my $ok = eval { $code->(); 1 };
    if (!$ok) {
        my $err = $@;
        eval { $db->rollback };
        die $err;
    }
    $db->commit;
    return 1;
}

# ============================================================================ #
# Repository state for git sync clients
# ============================================================================ #

sub get_repo_state {
    my ($project, $ref) = @_;
    return dbh()->selectrow_hashref(q/SELECT * FROM GitRepoState WHERE project = ? AND ref = ?/, undef, $project, $ref);
}

# ============================================================================ #

sub get_all_repo_state {
    return dbh()->selectall_arrayref(q/SELECT * FROM GitRepoState/, {Slice => {}}) || [];
}

# ============================================================================ #

sub update_repo_state {
    my ($data) = @_;

    my $db  = dbh();
    my $now = time;

    my @values = ($data->{latest_commit_id}, $data->{last_updated} // $now, $data->{remote_url}, $now);
    my $rows   = $db->do(
        q/UPDATE GitRepoState SET latest_commit_id = ?, last_updated = ?, remote_url = ?, updated_epoch = ?
          WHERE project = ? AND ref = ?/, undef, @values, $data->{project}, $data->{ref}
    );

    if ($rows == 0) {
        $db->do(
            q/INSERT INTO GitRepoState (latest_commit_id, last_updated, remote_url, updated_epoch, project, ref)
              VALUES (?,?,?,?,?,?)/, undef, @values, $data->{project}, $data->{ref}
        );
    }

    return {%{$data}, updated_epoch => $now};
}

# ============================================================================ #

sub delete_repo_state {
    my ($project, $ref) = @_;
    return dbh()->do(q/DELETE FROM GitRepoState WHERE project = ? AND ref = ?/, undef, $project, $ref);
}

# ============================================================================ #
# Spooler heartbeat
# ============================================================================ #

sub update_alive {
    my $now = time;
    dbh()->do(
        q/INSERT INTO SpoolerState (name, updated_epoch) VALUES ('spooler', ?)
          ON CONFLICT(name) DO UPDATE SET updated_epoch = excluded.updated_epoch/, undef, $now
    );
    return $now;
}

# ============================================================================ #

sub last_alive {
    return get_state_epoch('spooler');
}

# ============================================================================ #

# Named timestamps kept in SpoolerState (eg: last redelivery scan)
sub get_state_epoch {
    my ($name) = @_;
    my ($epoch) = dbh()->selectrow_array(q/SELECT updated_epoch FROM SpoolerState WHERE name = ?/, undef, $name);
    return $epoch;
}

sub set_state_epoch {
    my ($name, $epoch) = @_;
    dbh()->do(
        q/INSERT INTO SpoolerState (name, updated_epoch) VALUES (?, ?)
          ON CONFLICT(name) DO UPDATE SET updated_epoch = excluded.updated_epoch/, undef, $name, $epoch
    );
    return $epoch;
}

# ============================================================================ #
# Web hook redelivery
# ============================================================================ #

# Record a failed delivery, keeps the attempt count of an already known guid
sub redelivery_failed {
    my ($delivery, $now) = @_;
    my $db = dbh();

    my $rows = $db->do(
        q/UPDATE WebhookRedelivery SET delivery_id = ?, status_code = ?, updated_epoch = ?
          WHERE guid = ? AND delivery_id < ?/, undef,
        $delivery->{id}, $delivery->{status_code}, $now, $delivery->{guid}, $delivery->{id}
    );

    return if ($rows > 0);

    $db->do(
        q/INSERT OR IGNORE INTO WebhookRedelivery
          (guid, delivery_id, event, status_code, attempts, next_attempt_epoch, first_failed_epoch, updated_epoch)
          VALUES (?, ?, ?, ?, 0, ?, ?, ?)/, undef,
        $delivery->{guid}, $delivery->{id}, $delivery->{event}, $delivery->{status_code}, $now, $now, $now
    );
}

sub redelivery_succeeded {
    my ($guid) = @_;
    return dbh()->do(q/DELETE FROM WebhookRedelivery WHERE guid = ?/, undef, $guid);
}

sub redelivery_due {
    my ($now, $max_attempts) = @_;
    return dbh()->selectall_arrayref(
        q/SELECT * FROM WebhookRedelivery WHERE next_attempt_epoch <= ? AND attempts < ? ORDER BY first_failed_epoch/,
        {Slice => {}}, $now, $max_attempts);
}

sub redelivery_attempted {
    my ($guid, $attempts, $next_epoch) = @_;
    return dbh()->do(q/UPDATE WebhookRedelivery SET attempts = ?, next_attempt_epoch = ?, updated_epoch = ? WHERE guid = ?/,
        undef, $attempts, $next_epoch, time, $guid);
}

sub redelivery_list {
    return dbh()->selectall_arrayref(q/SELECT * FROM WebhookRedelivery ORDER BY first_failed_epoch/, {Slice => {}});
}

sub redelivery_cleanup {
    my ($before) = @_;
    return dbh()->do(q/DELETE FROM WebhookRedelivery WHERE first_failed_epoch < ?/, undef, $before);
}

# ============================================================================ #

1;
