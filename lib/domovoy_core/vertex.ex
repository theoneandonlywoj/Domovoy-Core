defmodule DomovoyCore.Vertex do
  @moduledoc """
  The dispatch over the two kinds of vertex of a `DomovoyCore.Workflow`.

  A `DomovoyCore.Stage` and a `DomovoyCore.Decision` are the vertices of a workflow.
  They are not nodes. A vertex name and a node name are both a `String.t()`,
  so only this type keeps the two namespaces apart for a reader. A spec that
  says `Vertex.name()` names a vertex. A spec that says `Node.name()` names a
  node of a graph.

  This module is the one place that matches the struct shapes of the two
  vertex kinds. `DomovoyCore.Workflow` and `DomovoyCore.Run` ask a vertex for its
  name, its kind, its control targets, its graph and its choices through
  `name/1`, `kind/1`, `targets/1`, `graph/1` and `choices/1`. They never match
  a `%DomovoyCore.Stage{}` or a `%DomovoyCore.Decision{}` themselves, so a new vertex
  kind changes this module and no other.

  ## Examples

      iex> stage = DomovoyCore.Stage.new(%{name: "prepare", graph: DomovoyCore.Graph.new(), next: "review"})
      iex> decision = DomovoyCore.Decision.new(%{
      ...>   name: "review",
      ...>   prompt: "Is the worktree right?",
      ...>   choices: [
      ...>     DomovoyCore.Choice.new(%{name: "approve", description: "Go on.", target: {:run, "report"}}),
      ...>     DomovoyCore.Choice.new(%{name: "stop", description: "End.", target: :halt})
      ...>   ]
      ...> })
      iex> DomovoyCore.Vertex.name(stage)
      "prepare"
      iex> DomovoyCore.Vertex.kind(stage)
      :stage
      iex> DomovoyCore.Vertex.kind(decision)
      :decision
      iex> DomovoyCore.Vertex.targets(stage)
      ["review"]
      iex> DomovoyCore.Vertex.targets(decision) |> Enum.sort()
      ["report"]
      iex> DomovoyCore.Vertex.graph(decision)
      nil
      iex> DomovoyCore.Vertex.choices(decision) |> Enum.map(& &1.name)
      ["approve", "stop"]

  A Stage with no `next` gives no target:

      iex> last = DomovoyCore.Stage.new(%{name: "report", graph: DomovoyCore.Graph.new()})
      iex> DomovoyCore.Vertex.targets(last)
      []
      iex> DomovoyCore.Vertex.graph(last) != nil
      true
  """

  alias DomovoyCore.Choice
  alias DomovoyCore.Decision
  alias DomovoyCore.Error
  alias DomovoyCore.Graph
  alias DomovoyCore.Stage

  @typedoc "The name of a Stage or a Decision inside one workflow."
  @type name() :: String.t()

  @typedoc "The kind of a vertex."
  @type kind() :: :stage | :decision

  @typedoc "A Stage or a Decision of a workflow."
  @type vertex() :: Stage.t() | Decision.t()

  @doc """
  Gives the name of `vertex`.
  """
  @spec name(vertex :: vertex()) :: name()
  def name(%Stage{name: name}), do: name
  def name(%Decision{name: name}), do: name

  @doc """
  Gives the kind of `vertex`: `:stage` or `:decision`.
  """
  @spec kind(vertex :: vertex()) :: kind()
  def kind(%Stage{}), do: :stage
  def kind(%Decision{}), do: :decision

  @doc """
  Gives the control target names of `vertex`.

  A Stage gives its `next`, so it gives one name or none. A Decision gives the
  vertex of each choice, and a `:halt` target gives no name.
  """
  @spec targets(vertex :: vertex()) :: [name()]
  def targets(%Stage{next: nil}), do: []
  def targets(%Stage{next: next}) when is_binary(next), do: [next]

  def targets(%Decision{choices: choices}) do
    choices
    |> Enum.map(&Choice.target_vertex/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  @doc """
  Gives the graph of `vertex`, or `nil` when `vertex` is a Decision.

  A Decision runs no runner, so it holds no graph. The graph of a Stage may
  be a `DomovoyCore.Error` that `DomovoyCore.Graph.new/1` gave for an invalid graph.
  `DomovoyCore.Workflow.new/1` surfaces that error in its checks.
  """
  @spec graph(vertex :: vertex()) :: Graph.t() | Error.t() | nil
  def graph(%Stage{graph: graph}), do: graph
  def graph(%Decision{}), do: nil

  @doc """
  Gives the choices of `vertex`. A Stage offers no choice, so it gives `[]`.
  """
  @spec choices(vertex :: vertex()) :: [Choice.t()]
  def choices(%Stage{}), do: []
  def choices(%Decision{choices: choices}), do: choices
end
