# render.sh

Manage env vars and deploys for the Render web service **rhlifecycle** from the terminal.

Needs `curl` and `jq` (`brew install jq`).

## Setup (once)

```sh
./render.sh init
```

Prompts for your Render API key (hidden), looks up the service id by name, and writes
`~/.config/render-update/config` with mode 600.

Prefer to keep the key elsewhere? Skip `init` and export it instead — env vars win over the
config file:

```sh
export RENDER_API_KEY="rnd_..."           # e.g. from a keychain: $(security find-generic-password -s render -w)
export RENDER_SERVICE_NAME="rhlifecycle"  # or RENDER_SERVICE_ID=srv-...
```

## The thing you'll do most

```sh
./render.sh azure
```

Shows the current `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_CLIENT_SECRET`, prompts for each
(blank keeps the current value, the secret is typed hidden), lists what will change, then asks
what to do — the same three choices as the dashboard:

```
  1) Save, rebuild, and deploy   build from source, then deploy (default)
  2) Save and deploy             redeploy the existing build
  3) Save only                   no deploy; values apply on the next one
  4) Cancel                      change nothing
```

Nothing is written until after you choose, so `4` is a real escape hatch. After 1 or 2 it follows
the deploy and prints each status change until it's `live` or failed.

Non-interactive, reading the three values from a file:

```sh
./render.sh azure -f ~/new-creds.env --deploy-only -y
```

The file is plain `KEY=VALUE` lines (`#` comments, optional quotes, surrounding whitespace
trimmed); only the three `AZURE_*` keys are read, anything else is ignored.

## Other commands

```sh
./render.sh list              # all env vars, secret-looking values masked
./render.sh list --show       # real values
./render.sh get AZURE_CLIENT_ID
./render.sh set GROQ_API_KEY            # hidden prompt, then the deploy menu
./render.sh set PRIMARY_MODEL llama-3.3-70b --save-only
./render.sh unset OLD_VAR
./render.sh deploy            # rebuild + deploy, nothing changed
./render.sh deploy --deploy-only --clear-cache
./render.sh status            # last 5 deploys
./render.sh watch             # follow the current deploy
./render.sh info              # url, dashboard link, autoDeploy
./render.sh services          # every service in the workspace
```

Flags that skip the menu on `set` / `unset` / `azure`: `--rebuild`, `--deploy-only`,
`--save-only`, `--clear-cache`, `--no-watch`, `-y` (non-interactive, defaults to `--rebuild`).

## Notes

- Updating an env var through the API does **not** deploy by itself — that's why the menu exists.
  "Save only" leaves the running service on the old values until its next deploy.
- Client and tenant IDs are checked against the GUID shape; a mismatch warns before saving.
- The API key is sent via a temp curl config file (mode 600, deleted on exit), so it never shows
  up in `ps`. Values you pass as a command argument *do* land in your shell history and in `ps` —
  use the prompt or `-f FILE` for the client secret.
- Only variables set directly on the service are touched; linked environment groups are separate.
