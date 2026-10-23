requires 'Crypt::OpenSSL::RSA';
requires 'DBI';
requires 'DBD::SQLite';
requires 'Digest::SHA';
requires 'HTTP::Date';
requires 'HTTP::Message';
requires 'IO::Socket::SSL';
requires 'JSON::WebToken';
requires 'JSON::XS';
requires 'Log::Handler';
requires 'LWP::UserAgent';
requires 'LWP::Protocol::https';
requires 'Mojolicious';
requires 'Moose';
requires 'URI';

feature 'git-sync-client', 'Git sync client (git-sync-client/update_git_repo.pl)' => sub {
    requires 'Config::Any';
};

on 'test' => sub {
    requires 'Test::More';
};
