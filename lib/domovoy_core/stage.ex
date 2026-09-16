defmodule DomovoyCore.Stage do
  @moduledoc """
  A named wrapper around one `DomovoyCore.Graph`, and a vertex of a
  `DomovoyCore.Workflow`.

  A Stage is not a node and it is not a graph. It holds one graph and the name
  of the vertex that runs next. `run/3` runs that graph from end to end with
  `DomovoyCore.Engine`, and it forwards the tagged Engine result.

  A Stage declares no output and no type. The value of every node is in the
  store under the name of that node. A node of a later Stage binds to that
  node by name, and the Engine reads the value. The type check stays at
  the node, so a Stage holds no second mapping layer.

  A Stage has one control successor. `next` names a Stage or a Decision, and
  it is one name or `nil`. A `next` of `nil` ends the workflow. A Stage that
  needs to branch points at a Decision instead, and `Stage.new/1` rejects a
  list of names.

  ## Examples

      graph = DomovoyCore.Graph.new([
        DomovoyCore.Node.new(%{
          name: "delay",
          runner: MyApp.Runner.Delay,
          type: DomovoyCore.Type.Integer,
          bind: %{
            min_delay_ms: {"count", DomovoyCore.Type.Integer},
            max_delay_ms: {"count", DomovoyCore.Type.Integer}
          }
        })
      ])
      stage = DomovoyCore.Stage.new(%{name: "compute", graph: graph, next: "review"})
      stage.name
      "compute"
      stage.next
      "review"
      stage.metadata
      %{}
      DomovoyCore.Stage.inputs(stage)
      %{"count" => DomovoyCore.Type.Integer}

  `next` is `nil` by default:

      DomovoyCore.Stage.new(%{name: "last", graph: DomovoyCore.Graph.new()}).next
      nil

  A list of names raises, because a Stage has one successor:

      DomovoyCore.Stage.new(%{name: "split", graph: DomovoyCore.Graph.new(), next: ["a", "b"]})
      ** (ArgumentError) next of stage "split" must be one vertex name or nil, got: ["a", "b"]

  `run/3` runs runners. See its documentation for an illustrative example.
  """

  alias DomovoyCore.Context
  alias DomovoyCore.Engine
  alias DomovoyCore.Graph
  alias DomovoyCore.Node
  alias DomovoyCore.Stage
  alias DomovoyCore.Type
  alias DomovoyCore.Vertex

  @type metadata() :: %{String.t() => any()}

  @type t() :: %Stage{
          name: Vertex.name(),
          graph: Graph.t(),
          next: Vertex.name() | nil,
          metadata: metadata()
        }

  @type new() :: %{
          required(:name) => Vertex.name(),
          required(:graph) => Graph.t(),
          optional(:next) => Vertex.name() | nil,
          optional(:metadata) => metadata()
        }

  defstruct name: nil,
            graph: nil,
            next: nil,
            metadata: %{}

  @doc """
  Makes a Stage. `:name` and `:graph` are necessary. `:next` is `nil` by
  default, and `:metadata` is empty by default.

  `:next` must be one vertex name or `nil`. A list of names raises an
  `ArgumentError`, because a Stage that branches points at a Decision.
  """
  @spec new(new()) :: Stage.t()
  def new(args) when is_map(args) do
    name = Map.fetch!(args, :name)
    next = Map.get(args, :next)

    if not (is_binary(next) or is_nil(next)) do
      raise ArgumentError,
            "next of stage #{inspect(name)} must be one vertex name or nil, " <>
              "got: #{inspect(next)}"
    end

    %Stage{
      name: name,
      graph: Map.fetch!(args, :graph),
      next: next,
      metadata: Map.get(args, :metadata) || %{}
    }
  end

  @doc """
  Gives the typed inputs of the graph of `stage`.

  Each key is a name that a node of the graph depends on and that no node of
  the graph gives. An earlier Stage or the caller of the workflow gives it.
  """
  @spec inputs(stage :: Stage.t()) :: %{Node.name() => Type.t()}
  def inputs(%Stage{graph: %Graph{} = graph}), do: graph.inputs

  @doc """
  Runs the graph of `stage` in `context`.

  The Engine gets an empty `inputs` map, because the store holds each value
  that an earlier Stage wrote. This function puts the name of the Stage in
  `context.stage` and gives the rest of the context on as it is.
  `DomovoyCore.Run` makes the context. A Stage opens no store and
  writes no event of its own. `opts` are the options of `DomovoyCore.Engine.run/4`.

  The `:runners` option replaces runners in this graph only.
  `DomovoyCore.Run` validates workflow overrides and selects the keys for each stage.

  ## Examples

  This example runs a runner, so it is illustrative. The store holds
  `"count"` with the value `40`, which an earlier Stage wrote:

      stage = DomovoyCore.Stage.new(%{name: "compute", graph: graph, next: "review"})
      {:ok, store} = DomovoyCore.Store.open(MyApp.Store.Memory, "dom-30", workflow: "doc")
      job = DomovoyCore.Job.new("dom-30")
      context = %DomovoyCore.Context{job: job, workflow: "doc", store: store}
      DomovoyCore.Stage.run(stage, context)
      {:ok, %{
        "delay" => %DomovoyCore.Record{
          job: %DomovoyCore.Job{id: "dom-30", generation: 0, attempt: 1, metadata: %{}},
          node: "delay",
          status: :ok,
          result: %DomovoyCore.Value{value: 40, type: DomovoyCore.Type.Integer, metadata: %{}},
          ...
        }
      }}
  """
  @spec run(stage :: Stage.t(), context :: Context.t(), opts :: Engine.opts()) :: Engine.result()
  def run(%Stage{name: name, graph: %Graph{} = graph}, %Context{} = context, opts \\ []) do
    Engine.run(graph, %{}, %Context{context | stage: name}, opts)
  end
end
