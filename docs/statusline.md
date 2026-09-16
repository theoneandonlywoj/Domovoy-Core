# Claude Code statusline

A project-scoped statusline that shows repository and session details together with Claude Code usage limits, so an
approaching limit is visible without stopping to run `/usage`.

```text
Domovoy-Core  ⎇ dom-5-project-setup  Opus 5 · xhigh · $1.84
ctx ━━╸╍╍╍╍╍╍╍  26% 52k   5h ━━━━╍╍╍╍╍╍  42% ·2h13m   7d ━━━━━━━╍╍╍  71% ·3d4h
```

Row 1 shows the project, branch, worktree, pull request, model, effort, fast mode, and session cost when available.
Row 2 holds fixed-width usage meters, so a long branch name cannot push them off-screen.

## Files

| Path | Purpose |
| --- | --- |
| `.claude/settings.json` | Registers the statusline for everyone working in this repository. |
| `.claude/statusline.sh` | Reads the Status hook JSON payload from stdin and writes two lines to stdout. |
| `.claude/settings.local.json` | Stores personal overrides; it is ignored by Git and takes precedence. |

## Meters

| Label | Source field | Meaning |
| --- | --- | --- |
| `ctx` | `context_window.used_percentage` | Context-window fill and input token count. |
| `5h` | `rate_limits.five_hour` | Rolling five-hour session limit. |
| `7d` | `rate_limits.seven_day` | Rolling seven-day limit. |
| `$` | `rate_limits.spend_limit` | Usage-credit spend, when gateway authentication supplies it. |

The countdown suffix is derived from each limit's `resets_at` epoch timestamp. The ten-cell bar has half-cell
resolution and changes from green to yellow at 60%, orange at 80%, and bold red at 95%. Set `NO_COLOR=1` to disable
colors.

## Previewing

```sh
make statusline-preview
```

This renders representative values and degraded cases without requiring an active Claude Code payload. It is
equivalent to `.claude/statusline.sh --demo`.

To check a specific payload, pipe one in:

```sh
printf '%s' '{"model":{"display_name":"Opus 5"},
  "workspace":{"current_dir":"'"$PWD"'","project_dir":"'"$PWD"'"},
  "cost":{"total_cost_usd":1.84},
  "context_window":{"used_percentage":26,"total_input_tokens":52000}}' \
  | .claude/statusline.sh
```

## Requirements

The script supports the macOS system Bash 3.2 and normal repositories as well as linked Git worktrees. `jq` is an
optional dependency needed for full rendering. Without it, the project and Git branch still render with a short
installation hint.

## Customizing

The constants at the top of `.claude/statusline.sh` control meter width, glyphs, thresholds, colors, and maximum
branch length. Personal settings belong in `.claude/settings.local.json`.

To turn off the project statusline locally:

```json
{ "statusLine": null }
```
