#!/bin/sh

set -e

exec perl /opt/git/github-youtrack/github_web_hook.pl daemon -m production -l http://*:3000
