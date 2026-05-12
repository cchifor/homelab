# claude-runner

Multi-arch container image for running headless Claude Code jobs as k3s
CronJobs on the Radxa arm64 nodes. Bundles `claude`, `git`, `gh`, `kubectl`,
`helm`, `node`, `python3`, `jq`, `yq`, `restic`, `tmux`. **Does not include
Docker by design** — Docker-needing jobs run on the claude-worker VM
via systemd timers.

## Build & push

Run on the claude-worker VM (amd64 host with Docker + qemu-user-static):

````markdown
```bash
sudo apt install -y qemu-user-static binfmt-support  # one-time
docker login gitea.chifor.dev                         # one-time
./build.sh
```
````

This produces `gitea.chifor.dev/c4/claude-runner:<date>-<sha>` and `:latest`,
multi-arch (`linux/amd64,linux/arm64`).

## Entrypoint

`/usr/local/bin/claude-run-pod` reads:
- `/jobs/prompt.md`         — the prompt
- `/jobs/allowed-tools.txt` — comma-separated tool allow-list
- `/jobs/job.env`           — optional env vars

…and writes transcripts to `/workspace/runs/<UTC-ts>/`.

OAuth credential is expected at `/var/run/claude/credentials.json`
(mounted from the `claude-oauth` Secret); the entrypoint symlinks it to
`~/.claude/.credentials.json`.
