# Domovoy-Core

DomovoyCore is an Elixir library for building typed, persistent workflows from
data-flow graphs, stages, and human or automated decisions.

It is a library application: it does not define an `Application` callback or
start a global runtime. The host application owns each named runtime, following
the same setup style as Finch.

## Installation

Add `domovoy_core` to the dependencies of the host application:

```elixir
def deps do
  [
    {:domovoy_core, "~> 0.1"}
  ]
end
```

For a local checkout, use a path dependency instead:

```elixir
{:domovoy_core, path: "../Domovoy-Core"}
```

Then fetch dependencies with `mix deps.get`.

## Runtime Setup

Add a named runtime to the host application's supervision tree:

```elixir
children = [
  {DomovoyCore.Runtime, name: MyDomovoy}
]

Supervisor.start_link(children,
  strategy: :one_for_one,
  name: MyApp.Supervisor
)
```

Pass `MyDomovoy` as the first argument to runtime-dependent APIs. Separate
names create isolated registries, task supervisors, workflow supervisors, and
PubSub instances in the same VM.

## Workflow Usage

Workflows combine stages and decisions. This minimal workflow starts, finishes
its empty stage, and persists records and events under the default
`.domovoy/runs` root:

```elixir
alias DomovoyCore.{Graph, Job, Run, Stage, Workflow}

finish = Stage.new(%{name: "finish", graph: Graph.new()})

workflow =
  Workflow.new!(%{
    name: "hello",
    vertices: %{"finish" => finish},
    start: "finish"
  })

run = Run.start(MyDomovoy, workflow, %{}, job: Job.new("hello-1"))
run = Run.run_to_decision(workflow, run)
run.status
# => :finished
```

For typed runners, graph construction, decisions, persistence, supervised
execution, replay, and telemetry, see [Core concepts](docs/core_concepts.md).

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
