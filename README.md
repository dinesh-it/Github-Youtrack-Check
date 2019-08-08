# Github-Youtrack-Check
Micro service to check and update status for the commits pushed to github has a valid youtrack ticket mentioned.

## Config
All the configs are read from ENV
```
# Required
export YOUTRACK_MATCH_KEY="^((?:P|M)(?:AY|\d+)-\d+)"
export YOUTRACK_TOKEN="<youtrack_token>"
export YOUTRACK_HOST="<youtrack_host>"
export GITHUB_TOKEN="github_token"

# Optional
export GITHUB_SECRET="web_hook_secret"
export GITHUB_WEB_HOOK_DB="/tmp/github_web_hook.db"
export GITHUB_WEB_HOOK_DB_USER=""
export GITHUB_WEB_HOOK_DB_PWD=""
```

#### YOUTRACK_MATCH_KEY
Regular expresion used to extract youtrack ticket from the commit message. $1 will be considered as a ticket number from the given regular expression.

#### YOUTRACK_TOKEN
YouTrack permanent token. Refer [Create a Permanent Token](https://www.jetbrains.com/help/youtrack/standalone/Manage-Permanent-Token.html#obtain-permanent-token) at youtrack help section to create one.
    * Select YouTrack scope while generating the token.
    
#### YOUTRACK_HOST
Host name with protocol where the youtrack is served eg: https://company.myjetbrains.com

#### GITHUB_TOKEN
Github personal access token, Refer [Creating a personal access token](https://help.github.com/en/articles/creating-a-personal-access-token-for-the-command-line) at github help section.
     * repo:status privilage should be enough for this token
     
#### GITHUB_SECRET
The secret string used while creating github web hook.

#### GITHUB_WEB_HOOK_DB
This script uses a sqlite database file to store commit details temporarily, please specify the full path including database name. By default it is set to `/tmp/github_web_hook.db`.

#### GITHUB_WEB_HOOK_DB_USER and GITHUB_WEB_HOOK_DB_PWD
UserName and password for the above mentioned database if preferred.

## Usage
* Start github web hook listener
`perl github_web_hook.pl daemon -l https://*:3000`

* Now a micro service to listen for github web hook is ready at your server on port 3000.
* Configure your Github web hook with address pointing to `http://<yourhost>:3000/check_youtrack` for `push` event type.
    * Web Hook settings can be found at repository->settings->Hooks
* You should start seeing the request coming to your microservice on each push to github now.
* Start youtrack check service
`perl youtrack_github_status.pl`

Thats all, green tick marks or red cross mark will appear for each commits you push to github now.

Note: Configure both services via svc or systemd to auto restart.
