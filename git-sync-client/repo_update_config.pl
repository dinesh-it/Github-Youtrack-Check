# Sample config for update_git_repo.pl, point EX_GITHOOK_CONFIG_FILE to a copy
# of this file. The shared secret is read from GH_WEBSOCKET_SECRET env.
{
    # Prefer wss:// when the server is behind TLS
    server_url => 'ws://micro-ci.dev.exceleron.com/githubpush',

    # Optional CA file to verify the server certificate when using wss://
    #ca => '/etc/ssl/certs/micro-ci-ca.pem',

    # Identifies this client, a re-connect replaces the older session of the same
    # client id and repo list (default: host name)
    #client_id => 'nm02',

    # Keep alive ping (also keeps NAT gateways from dropping the connection),
    # a connection idle for 2 x ping_interval is re-connected
    #ping_interval => 60, # in seconds

    # Ask the server for the latest state periodically to catch missed updates
    #resync_interval => 180, # in seconds

    # Command run after a successful fetch of a repo with salt_fileserver_update
    #fileserver_update_command => ['salt-run', 'fileserver.update'],

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
            #salt_fileserver_update => 1, # Refresh salt fileserver after fetch

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
