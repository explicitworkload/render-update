#!/usr/bin/env bash
#
# render.sh — manage env vars and deploys for a single Render.com service.
#
# Quick start:
#   ./render.sh init            # store API key, resolve service id
#   ./render.sh azure           # update AZURE_CLIENT_ID / TENANT_ID / CLIENT_SECRET
#   ./render.sh list            # show all env vars (secret values masked)
#
# After any env-var change you get the same three choices as the dashboard:
#   1) Save, rebuild, and deploy   POST /deploys  deployMode=build_and_deploy
#   2) Save and deploy             POST /deploys  deployMode=deploy_only
#   3) Save only                   no deploy — values apply on the next one
#
# Config lives in ~/.config/render-update/config (chmod 600).
# Env vars RENDER_API_KEY / RENDER_SERVICE_ID / RENDER_SERVICE_NAME override it.

set -euo pipefail

API_BASE="https://api.render.com/v1"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/render-update"
CONFIG_FILE="$CONFIG_DIR/config"
DEFAULT_SERVICE_NAME="rhlifecycle"
AZURE_KEYS="AZURE_CLIENT_ID AZURE_TENANT_ID AZURE_CLIENT_SECRET"

PROG=$(basename "$0")
RUN_TMP=""
CURLRC=""
RESP=""
LAST_DEPLOY_ID=""
DEPLOY_CHOICE=""     # rebuild | deploy | none  ("" = ask)
CLEAR_CACHE=""       # "clear" or empty
WATCH=1
ASSUME_YES=0
TAB=$(printf '\t')
API_KEY="${RENDER_API_KEY:-}"
SERVICE_ID="${RENDER_SERVICE_ID:-}"
SERVICE_NAME="${RENDER_SERVICE_NAME:-$DEFAULT_SERVICE_NAME}"

# ---------------------------------------------------------------- helpers ---

die()  { printf 'error: %s\n' "$*" >&2; exit 1; }
info() { printf '%s\n' "$*" >&2; }

cleanup() {
  if [ -n "$RUN_TMP" ]; then rm -rf "$RUN_TMP"; fi
}
trap cleanup EXIT INT TERM

tmpdir() {
  if [ -z "$RUN_TMP" ]; then
    RUN_TMP=$(mktemp -d "${TMPDIR:-/tmp}/render-update.XXXXXX")
    chmod 700 "$RUN_TMP"
  fi
  printf '%s' "$RUN_TMP"
}

# Read a line from the terminal even when stdin is a pipe.
ask() { # ask VAR_NAME "prompt" [silent]
  local __var=$1 __prompt=$2 __silent=${3:-} __val="" __tty=/dev/stdin
  # Use the terminal when there is one, so prompts still work if stdin is a pipe.
  if { true < /dev/tty; } 2>/dev/null; then __tty=/dev/tty; fi
  printf '%s' "$__prompt" >&2
  if [ -n "$__silent" ]; then
    read -r -s __val < "$__tty" || true
    printf '\n' >&2
  else
    read -r __val < "$__tty" || true
  fi
  eval "$__var=\$__val"
}

confirm() { # confirm "question" [default_yes]
  local q=$1 def=${2:-} ans hint="[y/N]"
  if [ -n "$def" ]; then hint="[Y/n]"; fi
  if [ "$ASSUME_YES" = 1 ]; then return 0; fi
  ask ans "$q $hint "
  case "$ans" in
    [yY]|[yY][eE][sS]) return 0 ;;
    "") if [ -n "$def" ]; then return 0; else return 1; fi ;;
    *) return 1 ;;
  esac
}

is_secret_key() {
  case "$1" in
    *SECRET*|*PASSWORD*|*TOKEN*|*_KEY|*APIKEY*) return 0 ;;
    *) return 1 ;;
  esac
}

mask() { # mask VALUE
  local v=$1 n=${#1}
  if [ "$n" -eq 0 ]; then printf '(empty)'
  elif [ "$n" -le 8 ]; then printf '•••••••• (%d chars)' "$n"
  else printf '%s••••%s (%d chars)' "${v:0:3}" "${v: -3}" "$n"
  fi
}

trim() { # strip leading/trailing whitespace (paste artifacts)
  local v=$1
  v=${v#"${v%%[![:space:]]*}"}
  v=${v%"${v##*[![:space:]]}"}
  printf '%s' "$v"
}

looks_like_guid() {
  [[ $1 =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
}

display_value() { # display_value KEY VALUE [SHOW_ALL]
  if [ "${3:-0}" = 1 ] || ! is_secret_key "$1"; then printf '%s' "$2"; else mask "$2"; fi
}

# ------------------------------------------------------------- api client ---

curl_config() {
  if [ -z "$CURLRC" ]; then
    CURLRC="$(tmpdir)/curlrc"
    # printf is a shell builtin, so the key never appears in a process listing.
    printf 'header = "Authorization: Bearer %s"\n' "$API_KEY" > "$CURLRC"
    chmod 600 "$CURLRC"
  fi
  printf '%s' "$CURLRC"
}

# api METHOD PATH [BODY_FILE] -> response body in $RESP
api() {
  local method=$1 path=$2 bodyfile=${3:-} out code
  local -a extra=()
  if [ -n "$bodyfile" ]; then
    extra=(-H 'Content-Type: application/json' --data-binary @"$bodyfile")
  fi
  out=$(curl -sS -X "$method" -K "$(curl_config)" \
          -H 'Accept: application/json' \
          ${extra[@]+"${extra[@]}"} \
          -w $'\n%{http_code}' \
          "$API_BASE$path") || die "network call failed: $method $path"
  code=${out##*$'\n'}
  RESP=${out%$'\n'*}
  case "$code" in
    2*)  return 0 ;;
    401) die "unauthorized (401) — the API key is wrong, expired, or lacks access" ;;
    403) die "forbidden (403) — this key cannot act on $SERVICE_NAME" ;;
    404) die "not found (404): $method $path" ;;
    429) die "rate limited (429) — wait a moment and retry" ;;
    *)   printf 'error: HTTP %s from %s %s\n%s\n' "$code" "$method" "$path" "$RESP" >&2; exit 1 ;;
  esac
}

json_value_body() { # json_value_body VALUE -> path of temp file {"value": ...}
  local f
  f="$(tmpdir)/body.json"
  VALUE="$1" jq -n '{value: env.VALUE}' > "$f"
  chmod 600 "$f"
  printf '%s' "$f"
}

urlenc() { printf '%s' "$1" | jq -sRr @uri; }

# ----------------------------------------------------------------- config ---

load_config() {
  if [ -f "$CONFIG_FILE" ]; then
    # shellcheck source=/dev/null
    . "$CONFIG_FILE"
    if [ -z "$API_KEY" ];    then API_KEY="${RENDER_API_KEY:-}"; fi
    if [ -z "$SERVICE_ID" ]; then SERVICE_ID="${RENDER_SERVICE_ID:-}"; fi
    if [ "$SERVICE_NAME" = "$DEFAULT_SERVICE_NAME" ]; then
      SERVICE_NAME="${RENDER_SERVICE_NAME:-$DEFAULT_SERVICE_NAME}"
    fi
  fi
  return 0
}

save_config() {
  mkdir -p "$CONFIG_DIR"
  chmod 700 "$CONFIG_DIR"
  umask 077
  {
    printf '# written by %s on %s\n' "$PROG" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'RENDER_API_KEY=%q\n'      "$API_KEY"
    printf 'RENDER_SERVICE_ID=%q\n'   "$SERVICE_ID"
    printf 'RENDER_SERVICE_NAME=%q\n' "$SERVICE_NAME"
  } > "$CONFIG_FILE"
  chmod 600 "$CONFIG_FILE"
}

resolve_service() {
  local n
  api GET "/services?limit=100&name=$(urlenc "$SERVICE_NAME")"
  n=$(printf '%s' "$RESP" | jq --arg n "$SERVICE_NAME" '[.[] | select(.service.name == $n)] | length')
  case "$n" in
    0) die "no service named '$SERVICE_NAME' in this workspace (try: $PROG services)" ;;
    1) SERVICE_ID=$(printf '%s' "$RESP" | jq -r --arg n "$SERVICE_NAME" \
         'first(.[] | select(.service.name == $n) | .service.id)') ;;
    *) die "multiple services named '$SERVICE_NAME' — set RENDER_SERVICE_ID explicitly" ;;
  esac
}

need_tools() {
  command -v jq   >/dev/null 2>&1 || die "jq is required (brew install jq)"
  command -v curl >/dev/null 2>&1 || die "curl is required"
}

need_auth() {
  need_tools
  load_config
  [ -n "$API_KEY" ] || die "no API key — run '$PROG init' or export RENDER_API_KEY"
  if [ -z "$SERVICE_ID" ]; then
    resolve_service
    if [ -f "$CONFIG_FILE" ]; then save_config; fi
  fi
}

# ------------------------------------------------------- deploy decisions ---

# The dashboard's post-save menu, as a prompt.
choose_deploy_action() {
  if [ -n "$DEPLOY_CHOICE" ]; then return 0; fi
  if [ "$ASSUME_YES" = 1 ]; then DEPLOY_CHOICE=rebuild; return 0; fi
  local ans
  info ""
  info "What should Render do?"
  info "  1) Save, rebuild, and deploy   build from source, then deploy (default)"
  info "  2) Save and deploy             redeploy the existing build"
  info "  3) Save only                   no deploy; values apply on the next one"
  info "  4) Cancel                      change nothing"
  ask ans "Choose [1]: "
  case "${ans:-1}" in
    1|r|rebuild)       DEPLOY_CHOICE=rebuild ;;
    2|d|deploy)        DEPLOY_CHOICE=deploy ;;
    3|s|save|saveonly) DEPLOY_CHOICE=none ;;
    4|c|cancel|q)      die "cancelled — nothing was changed" ;;
    *) die "invalid choice: $ans" ;;
  esac
}

trigger_deploy() { # trigger_deploy rebuild|deploy
  local mode=$1 f
  f="$(tmpdir)/deploy.json"
  if [ "$mode" = deploy ]; then
    printf '{"deployMode":"deploy_only"}\n' > "$f"
  elif [ -n "$CLEAR_CACHE" ]; then
    printf '{"deployMode":"build_and_deploy","clearCache":"clear"}\n' > "$f"
  else
    printf '{"deployMode":"build_and_deploy","clearCache":"do_not_clear"}\n' > "$f"
  fi
  api POST "/services/$SERVICE_ID/deploys" "$f"
  LAST_DEPLOY_ID=$(printf '%s' "$RESP" | jq -r '.id // empty')
  if [ -z "$LAST_DEPLOY_ID" ]; then LAST_DEPLOY_ID=$(latest_deploy_id); fi
  info "Deploy $LAST_DEPLOY_ID started ($mode)."
}

# Run the chosen action after env vars have been written.
apply_deploy_action() {
  case "$DEPLOY_CHOICE" in
    rebuild|deploy)
      trigger_deploy "$DEPLOY_CHOICE"
      if [ "$WATCH" = 1 ]; then watch_deploy "$LAST_DEPLOY_ID"; fi
      ;;
    none)
      info "Saved only — the service keeps running with the old values until its next deploy."
      info "Run '$PROG deploy' (or '$PROG deploy --deploy-only') when you're ready."
      ;;
  esac
}

latest_deploy_id() {
  api GET "/services/$SERVICE_ID/deploys?limit=1"
  printf '%s' "$RESP" | jq -r '.[0].deploy.id // empty'
}

deploy_status() { # deploy_status DEPLOY_ID
  api GET "/services/$SERVICE_ID/deploys?limit=20"
  printf '%s' "$RESP" | jq -r --arg id "$1" \
    'first(.[] | select(.deploy.id == $id) | .deploy.status) // empty'
}

watch_deploy() { # watch_deploy DEPLOY_ID
  local id=${1:-} status last="" waited=0
  if [ -z "$id" ]; then info "no deploy to watch"; return 0; fi
  info "Watching $id — ctrl-c stops watching, not the deploy."
  while :; do
    status=$(deploy_status "$id")
    if [ -z "$status" ]; then status="unknown"; fi
    if [ "$status" != "$last" ]; then
      printf '  [%s] %s\n' "$(date +%H:%M:%S)" "$status" >&2
      last=$status
    fi
    case "$status" in
      live)
        info "Deploy is live."
        return 0 ;;
      build_failed|update_failed|pre_deploy_failed|canceled|deactivated)
        info "Deploy ended as '$status' — check the logs in the dashboard."
        return 1 ;;
    esac
    sleep 5
    waited=$((waited + 5))
    if [ "$waited" -ge 1800 ]; then
      info "Still '$status' after 30 minutes; giving up on watching."
      return 1
    fi
  done
}

# Shared option parser for the env-var changing commands.
parse_change_opts() { # sets DEPLOY_CHOICE/CLEAR_CACHE/WATCH, leaves rest in REST_ARGS
  REST_ARGS=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --rebuild)             DEPLOY_CHOICE=rebuild ;;
      --deploy|--deploy-only) DEPLOY_CHOICE=deploy ;;
      --save-only|--no-deploy) DEPLOY_CHOICE=none ;;
      --clear-cache)         CLEAR_CACHE=clear ;;
      --no-watch)            WATCH=0 ;;
      -y|--yes)              ASSUME_YES=1 ;;
      -f|--file)             OPT_FILE=${2:-}; [ -n "$OPT_FILE" ] || die "--file needs a path"; shift ;;
      -s|--show)             OPT_SHOW=1 ;;
      --) shift; while [ $# -gt 0 ]; do REST_ARGS[${#REST_ARGS[@]}]=$1; shift; done; break ;;
      -*) die "unknown option: $1" ;;
      *)  REST_ARGS[${#REST_ARGS[@]}]=$1 ;;
    esac
    shift
  done
}

# ---------------------------------------------------------------- commands ---

cmd_init() {
  need_tools
  load_config
  if [ -n "$API_KEY" ]; then
    if confirm "An API key is already stored. Replace it?"; then API_KEY=""; fi
  fi
  if [ -z "$API_KEY" ]; then
    ask API_KEY "Render API key (rnd_...): " silent
    [ -n "$API_KEY" ] || die "no key entered"
  fi
  local name
  ask name "Service name [$SERVICE_NAME]: "
  if [ -n "$name" ]; then SERVICE_NAME="$name"; fi
  SERVICE_ID=""
  resolve_service
  save_config
  info "Saved $CONFIG_FILE"
  info ""
  cmd_info
}

cmd_services() {
  need_tools
  load_config
  [ -n "$API_KEY" ] || die "no API key — run '$PROG init' or export RENDER_API_KEY"
  api GET "/services?limit=100"
  printf '%s' "$RESP" | jq -r '.[] | .service | [.id, .type, .name] | @tsv' | column -t -s "$TAB"
}

cmd_info() {
  need_auth
  api GET "/services/$SERVICE_ID"
  printf '%s' "$RESP" | jq -r '
    "name:        \(.name)",
    "id:          \(.id)",
    "type:        \(.type)",
    "autoDeploy:  \(.autoDeploy)",
    "suspended:   \(.suspended)",
    "url:         \(.serviceDetails.url // "-")",
    "dashboard:   \(.dashboardUrl)"'
}

cmd_list() {
  OPT_SHOW=0
  parse_change_opts "$@"
  need_auth
  api GET "/services/$SERVICE_ID/env-vars?limit=100"
  local k v
  # @tsv escapes any tabs/newlines inside a value, so one var stays on one line.
  while IFS="$TAB" read -r k v; do
    [ -n "$k" ] || continue
    printf '%-26s %s\n' "$k" "$(display_value "$k" "$v" "$OPT_SHOW")"
  done <<EOF
$(printf '%s' "$RESP" | jq -r '.[] | [.envVar.key, .envVar.value] | @tsv' | sort)
EOF
}

get_var() { # get_var KEY -> prints value, non-zero if absent
  api GET "/services/$SERVICE_ID/env-vars?limit=100"
  printf '%s' "$RESP" | jq -er --arg k "$1" 'first(.[] | select(.envVar.key == $k) | .envVar.value)'
}

cmd_get() {
  [ $# -ge 1 ] || die "usage: $PROG get KEY"
  need_auth
  get_var "$1" || die "no env var named '$1'"
}

put_var() { # put_var KEY VALUE
  api PUT "/services/$SERVICE_ID/env-vars/$(urlenc "$1")" "$(json_value_body "$2")"
}

cmd_set() {
  parse_change_opts "$@"
  set -- ${REST_ARGS[@]+"${REST_ARGS[@]}"}
  [ $# -ge 1 ] || die "usage: $PROG set KEY [VALUE]   (omit VALUE to be prompted)"
  need_auth
  local key=$1 val
  if [ $# -ge 2 ]; then
    val=$2
  elif is_secret_key "$key"; then
    ask val "Value for $key (hidden): " silent
  else
    ask val "Value for $key: "
  fi
  [ -n "$val" ] || die "empty value; use '$PROG unset $key' to remove the variable"
  info "$key -> $(display_value "$key" "$val")"
  choose_deploy_action
  put_var "$key" "$val"
  info "Saved."
  apply_deploy_action
}

cmd_unset() {
  parse_change_opts "$@"
  set -- ${REST_ARGS[@]+"${REST_ARGS[@]}"}
  [ $# -ge 1 ] || die "usage: $PROG unset KEY"
  need_auth
  confirm "Delete $1 from $SERVICE_NAME?" || die "aborted"
  choose_deploy_action
  api DELETE "/services/$SERVICE_ID/env-vars/$(urlenc "$1")"
  info "$1 deleted."
  apply_deploy_action
}

# Read KEY=VALUE lines from a .env-style file (only the AZURE_* keys are used).
load_env_file() { # load_env_file PATH
  local file=$1 line key val
  [ -r "$file" ] || die "cannot read $file"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    line=${line#export }
    key=${line%%=*}
    val=${line#*=}
    if [ "$key" = "$line" ]; then continue; fi
    key=$(printf '%s' "$key" | tr -d '[:space:]')
    case "$val" in
      \"*\") val=${val#\"}; val=${val%\"} ;;
      \'*\') val=${val#\'}; val=${val%\'} ;;
    esac
    case "$key" in
      AZURE_CLIENT_ID)     file_client_id=$val ;;
      AZURE_TENANT_ID)     file_tenant_id=$val ;;
      AZURE_CLIENT_SECRET) file_client_secret=$val ;;
      *) info "note: ignoring $key (only $AZURE_KEYS are read from a file)" ;;
    esac
  done < "$file"
}

cmd_azure() {
  OPT_FILE=""
  parse_change_opts "$@"
  need_auth

  file_client_id=""; file_tenant_id=""; file_client_secret=""
  if [ -n "$OPT_FILE" ]; then load_env_file "$OPT_FILE"; fi

  api GET "/services/$SERVICE_ID/env-vars?limit=100"
  local current="$RESP" key cur new changed=0 pending
  pending="$(tmpdir)/azure.tsv"
  : > "$pending"; chmod 600 "$pending"

  info "Service: $SERVICE_NAME ($SERVICE_ID)"
  info ""
  for key in $AZURE_KEYS; do
    cur=$(printf '%s' "$current" | jq -r --arg k "$key" \
      'first(.[] | select(.envVar.key == $k) | .envVar.value) // ""')
    case "$key" in
      AZURE_CLIENT_ID)     new=$file_client_id ;;
      AZURE_TENANT_ID)     new=$file_tenant_id ;;
      AZURE_CLIENT_SECRET) new=$file_client_secret ;;
      *) new="" ;;
    esac
    if [ -z "$new" ]; then
      if is_secret_key "$key"; then
        ask new "$key [current: $(display_value "$key" "$cur")] (hidden, blank = keep): " silent
      else
        ask new "$key [current: ${cur:-none}] (blank = keep): "
      fi
    fi
    new=$(trim "$new")
    [ -n "$new" ] || continue
    if [ "$new" = "$cur" ]; then
      info "  $key unchanged"
      continue
    fi
    case "$key" in
      AZURE_CLIENT_ID|AZURE_TENANT_ID)
        if ! looks_like_guid "$new"; then
          info "  warning: $key does not look like a GUID"
          confirm "  use it anyway?" || die "aborted"
        fi ;;
    esac
    printf '%s\t%s\n' "$key" "$new" >> "$pending"
    changed=$((changed + 1))
  done

  if [ "$changed" -eq 0 ]; then
    info ""
    info "Nothing to change."
    return 0
  fi

  info ""
  info "Changes to apply on $SERVICE_NAME:"
  while IFS="$TAB" read -r key new; do
    info "  $key -> $(display_value "$key" "$new")"
  done < "$pending"

  choose_deploy_action

  while IFS="$TAB" read -r key new; do
    put_var "$key" "$new"
    info "  $key saved"
  done < "$pending"

  apply_deploy_action
}

cmd_deploy() {
  DEPLOY_CHOICE=rebuild
  WATCH=1
  parse_change_opts "$@"
  if [ "$DEPLOY_CHOICE" = none ]; then die "nothing to do: --save-only has no meaning for 'deploy'"; fi
  need_auth
  trigger_deploy "$DEPLOY_CHOICE"
  if [ "$WATCH" = 1 ]; then watch_deploy "$LAST_DEPLOY_ID"; fi
}

cmd_status() {
  need_auth
  api GET "/services/$SERVICE_ID/deploys?limit=5"
  printf '%s' "$RESP" | jq -r '.[] | .deploy |
    [.status, .createdAt, (.trigger // "-"), ((.commit.message // "-") | split("\n")[0])] | @tsv' \
    | column -t -s "$TAB"
}

cmd_watch() {
  need_auth
  watch_deploy "$(latest_deploy_id)"
}

usage() {
  cat <<EOF
$PROG — manage the Render service "$SERVICE_NAME"

  init                      Store the API key and resolve the service id
  services                  List every service in the workspace
  info                      Service url, dashboard link, auto-deploy setting
  list [--show]             List env vars (secret-looking values masked)
  get KEY                   Print one value (raw, pipeable)
  set KEY [VALUE]           Add/update one var; prompts if VALUE is omitted
  unset KEY                 Delete one var
  azure [-f FILE]           Update AZURE_CLIENT_ID / TENANT_ID / CLIENT_SECRET
  deploy                    Deploy without changing anything
  status                    Recent deploys
  watch                     Follow the latest deploy until it settles

After an env-var change (set / unset / azure) you pick one of:
  1) Save, rebuild, and deploy   2) Save and deploy   3) Save only   4) Cancel

Skip the prompt with a flag:
  --rebuild        same as choice 1 (add --clear-cache to drop the build cache)
  --deploy-only    same as choice 2
  --save-only      same as choice 3
  --no-watch       don't follow the deploy afterwards
  -y               non-interactive; defaults to --rebuild

Examples:
  $PROG azure                          # interactive; blank input keeps a value
  $PROG azure -f ~/new-creds.env       # read the three values from KEY=VALUE lines
  $PROG azure -f ~/new-creds.env --deploy-only -y
  $PROG set GROQ_API_KEY --save-only   # hidden prompt, no deploy
  $PROG list --show

Secrets passed as arguments end up in your shell history and in 'ps' output —
prefer the hidden prompt or -f FILE for AZURE_CLIENT_SECRET.
EOF
}

main() {
  local cmd=${1:-help}
  if [ $# -gt 0 ]; then shift; fi
  case "$cmd" in
    init)            cmd_init "$@" ;;
    services)        cmd_services "$@" ;;
    info)            cmd_info "$@" ;;
    list|ls|env)     cmd_list "$@" ;;
    get)             cmd_get "$@" ;;
    set)             cmd_set "$@" ;;
    unset|rm|delete) cmd_unset "$@" ;;
    azure)           cmd_azure "$@" ;;
    deploy)          cmd_deploy "$@" ;;
    status)          cmd_status "$@" ;;
    watch)           cmd_watch "$@" ;;
    help|-h|--help)  usage ;;
    *) usage; exit 1 ;;
  esac
}

main "$@"
