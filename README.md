# Github-Youtrack-Check
Micro service to
* check and update status for the commits pushed to github has a valid youtrack ticket mentioned.
* check and update Pull request based on config
* Adds comment in the Youtrack ticket with the respective pull request
* Can be used for auto sync local git repo when remote repository is updated

## Config
All the configs are read from ENV
```
# Required
export YOUTRACK_TOKEN="<youtrack_token>"
export YOUTRACK_HOST="<youtrack_host>"

export GITHUB_TOKEN="github_token"
or
export GITHUB_APP_KEY_FILE='./private-key.pem' (if using a github app)

# Optional
export GITHUB_SECRET="web_hook_secret"
export GITHUB_WEB_HOOK_DB="/tmp/github_web_hook.db"
export GITHUB_WEB_HOOK_DB_USER=""
export GITHUB_WEB_HOOK_DB_PWD=""
export GH_WEBSOCKET_SECRET="some_secret"
export PR_BRANCH_YT_CHECK='PRODUCTION*=CLUSTER-*'
export DISABLE_CHECK_API=1
```

#### YOUTRACK_TOKEN
YouTrack permanent token. Refer [Create a Permanent Token](https://www.jetbrains.com/help/youtrack/standalone/Manage-Permanent-Token.html#obtain-permanent-token) at youtrack help section to create one.
    * Select YouTrack scope while generating the token.
    
#### YOUTRACK_HOST
Host name with protocol where the youtrack is served eg: https://company.myjetbrains.com

#### GITHUB_TOKEN
Github personal access token, Refer [Creating a personal access token](https://help.github.com/en/articles/creating-a-personal-access-token-for-the-command-line) at github help section.
     * Repo privilage is required for this token
     
#### GITHUB_SECRET
The secret string used while creating github web hook.

#### GITHUB_WEB_HOOK_DB
This script uses a sqlite database file to store commit details temporarily, please specify the full path including database name. By default it is set to `/tmp/github_web_hook.db`.

#### GITHUB_WEB_HOOK_DB_USER and GITHUB_WEB_HOOK_DB_PWD
UserName and password for the above mentioned database if preferred.

#### GH_WEBSOCKET_SECRET
Password string which will used to encrypt data sent to the Git sync client

#### GITHUB_APP_KEY_FILE
Server secret file path if using GIthub app (Can be generated from the app settings - Create client secrets)

#### PR_BRANCH_YT_CHECK
eg value: 'PRODUCTION*=CLUSTER-*' - Enables specific ticket check for PR's created against mentioned branch - check happens on the title of the PR

#### DISABLE_CHECK_API=1
If GITHUB_APP_KEY_FILE is set, github checks API will be used to better utilise the github app feature, we can set the flag to disable this behaviour. Github status API will be used otherwise. Enabling this feature will send checks API with a link to open the Github App - So if you have created an app for Authentication purpose only then its recomended to disable this feature.

## Usage
* Install all the perl modules required using `cpanm` command
`cpanm <modlist`

* Start github web hook listener and spool service
`github_web_hook.pl daemon -m production -l http://*:3000`

* Now a micro service to listen for github web hook is ready at your server on port 3000.
* Configure your Github web hook with address pointing to `http://<yourhost>:3000/check_youtrack` for `push` and `pull_request` event types.
    * Web Hook settings can be found at Github.com Repository->settings->Hooks
* You should start seeing the request coming to your microservice on each push to github now.

Additionally there is a helper script to force check a pull request without waiting for github web hook.
`./scripts/add_pull_request.pl 'repo_owner' 'repo_name' 'pull_request_number'`

Thats all, green tick marks (if comment has valid ticket) or red cross mark (if commits does not have a valid youtrack ticket) will appear for each commits you push to github now.

Note: Configure the service via daemon or systemd to auto restart on exception.

* To test if the service is up and running there is a probe path supported by the service - hit `http://<yourhost>:3000/ghyt-ci` and you should see json output with status 'ok' to make sure the service is running.

## Git Sync Feature
* A client can subscribe (open a web socket and listen for messages) to `ws://<yourhost>:3000/githubpush` path. When a push happens, it sends a single line text message with pipe seperated data in following format
project|ref|latest_commit_id|last_updated|remote_url|updated_epoch

* Optionally a client can send a message 'give-latest' on the opened websocket to receive latest commits for each branch in each configured github repository. We need to send this message when ever the client stopped and restarted to retrive all the pending actions that happened in the mean time.

* Note: The text messages received will be encrypted with hex8 encoding using GH_WEBSOCKET_SECRET key if configured - refer Crypt::Lite for more info.

* Refer: `./git-sync-client/update_git_repo.pl` and `./git-sync-client/repo_update_config.pl` - For a sample perl client and config file which utilize the Git Sync feature

## Docker
* We can run this application in container using docker
* Create a file named .env and add all the configurations env as KEY=VALUE format line by line in the project root directory
    * Please note the Project path in container will be /opt/git/github-youtrack/
* Start the service
    * Run command `make run` from project root directory
* If the configurations are correct you should see `Web application available at http://127.0.0.1:80` message and now you can hit `http://127.0.0.1/ghyt-ci` which responds with service status

