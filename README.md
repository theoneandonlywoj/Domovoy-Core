# Domovoy-Core

Domovoy Engine

## Prerequisites

Install [mise](https://mise.jdx.dev/) and use the repository's pinned Erlang and Elixir versions:

```sh
mise trust
mise install
mix local.hex --force
mix local.rebar --force
mix deps.get
```

[`jq`](https://jqlang.org/) is optional and enables full Claude Code statusline rendering.

## Development

Run the standard pre-commit checks:

```sh
mix precommit
```

Run all quality checks, including compilation with warnings treated as errors, formatting validation, Credo, and
Dialyzer:

```sh
mix quality
```

Activate the committed Git hooks after every fresh clone:

```sh
make hooks-install
```

Git does not use committed hook files until `core.hooksPath` is configured. The pre-commit and pre-push hooks block
the operation when project checks fail.

Preview the project-scoped Claude Code statusline:

```sh
make statusline-preview
```

See [Claude Code statusline](docs/statusline.md) for configuration and customization details.
