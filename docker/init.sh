#!/bin/sh
#
set -e

# Support for private key to be in Varialbe or in a file
if [ ! -z $GITHUB_APP_KEY_FILE ]; then
	echo "Updating GITHUB_APP_PRIVATE_KEY env with $GITHUB_APP_KEY_FILE content"
	export GITHUB_APP_PRIVATE_KEY="$(cat $GITHUB_APP_KEY_FILE)"
fi

# Put file in the expected location where both server and spooler can access
if [ ! -z "$GITHUB_APP_PRIVATE_KEY" ] ; then
	export GITHUB_APP_KEY_FILE=/run/github_apps_youtrack-ci.2021-05-05.private-key.pem
	echo "Creating $GITHUB_APP_KEY_FILE with key data"
	echo "$GITHUB_APP_PRIVATE_KEY" >$GITHUB_APP_KEY_FILE
fi

perl /opt/git/github-youtrack/scripts/refresh_token.pl

