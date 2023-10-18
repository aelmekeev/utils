#!/usr/bin/env bash

set -euo pipefail

function minimise_comments() {
  set_defaults
  parse_params "$@"

  if [[ -z "$pr_number" ]]; then
    echo "Trying to find PR number from current branch"
    pr_number=$(gh pr view --json number --jq '.number')
  fi

  author_filter=$([[ -n "$author" ]] && echo "select(.node.author.login == \"$author\")" || echo ".")
  # commit_filter="$(create_commit_filter)"
  create_commit_filter

  gh api graphql -F owner="$owner" -F name="$repo" -F pr_number="$pr_number" -f query='
    query($name: String!, $owner: String!, $pr_number: Int!) {
      repository(owner: $owner, name: $name) {
        pullRequest(number: $pr_number) {
          comments(first: 100) {
            edges {
              node {
                id
                createdAt
                author {
                  login
                }
              }
            }
          }
        }
      }
    }
  ' --jq "
    .data.repository.pullRequest.comments.edges[] |
    $author_filter |
    $commit_filter |
    .node.id
  " |
    while read -r id; do
      gh api graphql --silent -F id="$id" -f query="
        mutation(\$id: ID!) {
          $mutation(input: {
            subjectId: \$id
            $([[ "$mutation" == "minimizeComment" ]] && echo "classifier: OUTDATED")
          }) {
            clientMutationId
          }
        }
      " && work_done=true
    done

  if [ $mutation == "minimizeComment" ]; then
    echo "Minimised comments on PR #$pr_number"
  else [[ $mutation == "unminimizeComment" ]]
    echo "Unminimised comments on PR #$pr_number"
  fi
}

function set_defaults() {
  mutation="minimizeComment"
  pr_number=""
  author=""
  owner="{owner}"
  repo="{repo}"
  work_done=false
}

function parse_pr_url() {
  url="$1"
  url_regex="^https://github.com/\(.*\)/\(.*\)/pull/\(.*\)$"
  owner=$(echo "$url" | sed -n "s|$url_regex|\1|p")
  repo=$(echo "$url" | sed -n "s|$url_regex|\2|p")
  pr_number=$(echo "$url" | sed -n "s|$url_regex|\3|p")
}

function create_commit_filter() {
  gh api graphql -F owner="$owner" -F name="$repo" -F pr_number="$pr_number" -f query='
    query($name: String!, $owner: String!, $pr_number: Int!) {
      repository(owner: $owner, name: $name) {
        pullRequest(number: $pr_number) {
          commits(last: 1) {
            edges {
              node {
                commit {
                  committedDate
                }
              }
            }
          }
        }
      }
    }
  ' --jq '.data.repository.pullRequest.commits.edges[0].node.commit.committedDate' |
    while read -r date; do
      echo "select(.node.createdAt < \"$date\")"
      return
    done

  echo "."
}

# DESC: Exit script with the given message
# ARGS: $1 (required): Message to print on exit
#       $2 (optional): Exit code (defaults to 0)
function script_exit() {
  if [[ $# -eq 1 ]]; then
    printf '%s\n' "$1"
    exit 0
  fi

  if [[ ${2-} =~ ^[0-9]+$ ]]; then
    printf '%b\n' "$1"
    exit $2
  fi

  script_exit 'Missing required argument to script_exit()!' 2
}

function script_usage() {
  cat <<EOF
Usage:
     -u <url>            PR URL, uses current branch if not provided
     -r                  Unminimise comments instead
     -a <github login>   Only minimise comments by this author
     -o                  Only outdate comments on commits before the last one
     -h                  Displays this help
EOF
}

function parse_params() {
  while getopts ":hu:ra:c:" arg; do
    case $arg in
    u)
      url="$OPTARG"
      parse_pr_url "$url"
      ;;
    r)
      mutation="unminimizeComment"
      ;;
    a)
      author="$OPTARG"
      ;;
    c)
      commit="$OPTARG"
      ;;
    h)
      script_usage && exit 0
      ;;
    *)
      script_usage && exit 1
      ;;
    esac
  done
}

# Invoke main with args if not sourced
# Approach via: https://stackoverflow.com/a/28776166/8787985
if ! (return 0 2>/dev/null); then
  minimise_comments "$@"
fi
