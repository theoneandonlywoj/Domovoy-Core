defmodule DomovoyCore.Context do
  @moduledoc """
  The identity that a run hands to a node.

  A context holds the `DomovoyCore.Job` of the run, and it says which workflow,
  which stage and which node are at work, and where the records and the
  events go. The job names the run and holds its generation and attempt.
  `DomovoyCore.Run` makes one context per run. `DomovoyCore.Stage.run/3`
  sets `stage`, and `DomovoyCore.Engine` sets `node` before it runs a runner.

  `store` is a `DomovoyCore.Store` and `journal` is a `DomovoyCore.Journal`. The
  Engine reads and writes records through the store and appends events to the
  journal. `metadata` has string keys and the core never reads it.

  ## Examples

      iex> job = DomovoyCore.Job.new("dom-30")
      iex> context = %DomovoyCore.Context{job: job, workflow: "issue_to_pr"}
      iex> {context.job.id, context.job.generation, context.stage, context.node}
      {"dom-30", 0, nil, nil}
  """

  alias DomovoyCore.Context
  alias DomovoyCore.Job
  alias DomovoyCore.Journal
  alias DomovoyCore.Runtime
  alias DomovoyCore.Store

  @type t() :: %Context{
          job: Job.t(),
          workflow: String.t(),
          stage: String.t() | nil,
          node: String.t() | nil,
          store: Store.t() | nil,
          journal: Journal.t() | nil,
          runtime: Runtime.ref() | nil,
          metadata: %{String.t() => any()}
        }

  defstruct job: nil,
            workflow: nil,
            stage: nil,
            node: nil,
            store: nil,
            journal: nil,
            runtime: nil,
            metadata: %{}
end
