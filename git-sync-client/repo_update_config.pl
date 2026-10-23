# Sample config for update_git_repo.pl, point EX_GITHOOK_CONFIG_FILE to a copy
# of this file. The shared secret is read from GH_WEBSOCKET_SECRET env.
{
    # Prefer wss:// when the server is behind TLS
    server_url => 'ws://micro-ci.dev.exceleron.com/githubpush',

    # Optional CA file to verify the server certificate when using wss://
    #ca => '/etc/ssl/certs/micro-ci-ca.pem',

    # Max 1 hour the connection can be idle, otherwise reconnect
    inactive_timeout => 3600, # in seconds

    # Messages older than this are discarded (keep the host clock in sync)
    #max_message_age => 900, # in seconds

    # Hosts the server provided remote URL may point to
    #allowed_remote_hosts => ['github.com'],
    #allowed_owners => ['exceleron'],

    repo => {
        'Project-Name' => {

            local_path => '/opt/git/Project-Name.git',
            #remote_url => 'git@github.com:exceleron/Project-Name.git', # Optional, overrides server URL
            #force_fetch => 1,

            'refs/heads/test' => {
                force_fetch => 1,
                #local_ref => 'refs/heads/test', # Optional
            },
            'refs/heads/PRODUCTION' => {
                force_fetch => 0,
                #local_ref => 'refs/heads/PRODUCTION', # Optional
            }
        }
    },
}
