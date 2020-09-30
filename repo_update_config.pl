{
    server_host => 'micro-ci.dev.exceleron.com',
    password => 'secretpwd',

    # Max 1 hour the connection can be idle, otherwise reconnect
    inactive_timeout => 3600, # in seconds

	repo => {
        'Project-Name' => {

            local_path => '/opt/git/Project-Name.git',
            #remote_path => '', # Optional
            #force_fetch => 1,

            'refs/heads/test' => {
                force_fetch => 1,
                #local_branch => '', # Optional
            },
            'refs/heads/PRODUCTION' => {
                force_fetch => 0,
                #local_branch => '', # Optional
            }
        }
    },
}
