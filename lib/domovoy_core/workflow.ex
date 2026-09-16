defmodule DomovoyCore.Workflow do
  @moduledoc """
  A graph of Stages and Decisions, and the store that carries the data of a
  run from one Stage to the next.

  A `DomovoyCore.Stage` owns a graph of nodes and runs it from end to end. A
  `DomovoyCore.Decision` stops the process and asks what happens next. The
  decider of a Decision answers on its own, or it waits for a person. A
  Workflow holds the vertices, the control arrows between them, the name of
  the vertex that runs first, and the inputs that a run starts with. Only one
  vertex runs at a time.

  Every arrow of a workflow is a control arrow. A Stage declares `next`, and a
  Decision declares `choices`. Data does not travel on an arrow at this level.
  It travels through the store: each node writes its record, and a node of a
  later Stage reads it by name. A workflow therefore needs no cross-stage
  bindings. It holds `start` instead.

  A workflow graph may hold a cycle, because a re-run is a back arrow. A
  workflow has no topological order. It has a cursor, and `DomovoyCore.Run` moves
  it.

  ## Inputs

  `inputs` declares the values that a run starts with. Each key is the name of
  one input, and the value is a map with a `:type` and an optional `:default`:

      inputs: %{
        "issue_id" => %{type: DomovoyCore.Type.String},
        "plan_context" => %{type: DomovoyCore.Type.String, default: ""}
      }

  `DomovoyCore.Run.start/4` casts each provided value with the declared type. It
  writes the default of each input that the caller does not provide, at
  generation `0`. A `DomovoyCore.Choice` declares its own `inputs`, and a choice
  input key may equal a workflow input key, because both write a record under
  one name. A node name never equals an input key, because both name a record
  in one store.

  ## Checks

  `new/1` gives a `DomovoyCore.Error` when:

    * the name is not a `DomovoyCore.Name`.
    * an input entry holds a name that is not a `DomovoyCore.Name`, no `:type`, or
      a `:type` that is not a `DomovoyCore.Type`.
    * `start` names no vertex.
    * a key of `vertices` is not the name of the vertex under it.
    * a control target names no vertex.
    * a `{:rerun, target}` names a vertex that is not a Stage.
    * a node name equals the name of a node of another Stage, a workflow input
      key, or a choice input key.
    * a Stage reads a graph input that no workflow input and no prior vertex
      gives on a path from `start`.
    * `DomovoyCore.Engine.Order.order/1` fails for the graph of a Stage.
    * the module of `store` does not implement `DomovoyCore.Store`.
    * the module of `journal` does not implement `DomovoyCore.Journal`.

  `new!/1` raises instead. Use it in a test or in a module attribute.

  ## Store and journal

  `store` and `journal` say where the records and the events of a run live.
  Each is `{module, opts}`, and a bare module means `{module, []}`.
  `DomovoyCore.Run.start/4` opens both for one run and adds
  `workflow: name` to the options. The defaults are
  `{DomovoyCore.Store.FileSystem, []}` and `{DomovoyCore.Journal.FileSystem, []}`,
  which write under `.domovoy/runs/<name>/<run_id>/`.

  ## Examples

  A workflow with two Stages and one Decision between them. The last call
  shows the error for a start that names no vertex:

      iex> prepare = DomovoyCore.Stage.new(%{name: "prepare", graph: DomovoyCore.Graph.new(), next: "review"})
      iex> report = DomovoyCore.Stage.new(%{name: "report", graph: DomovoyCore.Graph.new()})
      iex> review = DomovoyCore.Decision.new(%{
      ...>   name: "review",
      ...>   prompt: "Is the worktree right?",
      ...>   choices: [
      ...>     DomovoyCore.Choice.new(%{name: "approve", description: "Go on.", target: {:run, "report"}}),
      ...>     DomovoyCore.Choice.new(%{name: "rerun", description: "Again.", target: {:rerun, "prepare"}}),
      ...>     DomovoyCore.Choice.new(%{name: "stop", description: "End.", target: :halt})
      ...>   ]
      ...> })
      iex> workflow = DomovoyCore.Workflow.new!(%{
      ...>   name: "review_worktree",
      ...>   vertices: %{"prepare" => prepare, "review" => review, "report" => report},
      ...>   start: "prepare",
      ...>   inputs: %{"count" => %{type: DomovoyCore.Type.Integer, default: 1}}
      ...> })
      iex> workflow.start
      "prepare"
      iex> workflow.inputs
      %{"count" => %{type: DomovoyCore.Type.Integer, default: 1}}
      iex> workflow.store
      {DomovoyCore.Store.FileSystem, []}
      iex> workflow.journal
      {DomovoyCore.Journal.FileSystem, []}
      iex> Enum.sort(workflow.arrows)
      [
        %DomovoyCore.Arrow{from: "prepare", to: "review"},
        %DomovoyCore.Arrow{from: "review", to: "prepare"},
        %DomovoyCore.Arrow{from: "review", to: "report"}
      ]
      iex> workflow.successors["review"] |> Enum.sort()
      ["prepare", "report"]
      iex> workflow.predecessors["prepare"]
      ["review"]
      iex> DomovoyCore.Workflow.stage?(workflow, "prepare")
      true
      iex> DomovoyCore.Workflow.decision?(workflow, "review")
      true
      iex> DomovoyCore.Workflow.new(%{name: "w", vertices: %{"report" => report}, start: "prepare"})
      %DomovoyCore.Error{
        type: :vertex_not_in_workflow,
        reason: %{vertex_name: "prepare", workflow_name: "w"}
      }
  """

  alias DomovoyCore.Arrow
  alias DomovoyCore.Choice
  alias DomovoyCore.Engine.Order
  alias DomovoyCore.Error
  alias DomovoyCore.Graph
  alias DomovoyCore.Journal
  alias DomovoyCore.Name
  alias DomovoyCore.Node
  alias DomovoyCore.Stage
  alias DomovoyCore.Store
  alias DomovoyCore.Type
  alias DomovoyCore.Vertex
  alias DomovoyCore.Workflow

  @default_store {Store.FileSystem, []}
  @default_journal {Journal.FileSystem, []}

  @type metadata() :: %{String.t() => any()}
  @type vertex() :: Stage.t() | DomovoyCore.Decision.t()
  @type vertices() :: %{Vertex.name() => vertex()}

  @typedoc "An adapter module with its options."
  @type adapter() :: {module(), keyword()}

  @typedoc "The type and the default of one input of a workflow."
  @type input() :: %{type: Type.t(), default: term() | nil}

  @typedoc "The declared inputs of a workflow, by name."
  @type inputs() :: %{String.t() => input()}

  @typedoc "One input as the caller writes it: a `:type` and an optional `:default`."
  @type new_input() :: %{required(:type) => Type.t(), optional(:default) => term()}

  @typedoc "The inputs of a workflow as the caller writes them, by name."
  @type new_inputs() :: %{String.t() => new_input()}

  @type t() :: %Workflow{
          name: String.t(),
          vertices: vertices(),
          arrows: [Arrow.t()],
          predecessors: %{Vertex.name() => [Vertex.name()]},
          successors: %{Vertex.name() => [Vertex.name()]},
          start: Vertex.name(),
          inputs: inputs(),
          store: adapter(),
          journal: adapter(),
          metadata: metadata()
        }

  @type new() :: %{
          required(:name) => String.t(),
          required(:vertices) => vertices(),
          required(:start) => Vertex.name(),
          optional(:inputs) => new_inputs(),
          optional(:store) => module() | adapter(),
          optional(:journal) => module() | adapter(),
          optional(:metadata) => metadata()
        }

  defstruct name: nil,
            vertices: %{},
            arrows: [],
            predecessors: %{},
            successors: %{},
            start: nil,
            inputs: %{},
            store: @default_store,
            journal: @default_journal,
            metadata: %{}

  @doc """
  Makes a Workflow, or gives the first error that the checks find.

  See the moduledoc for the checks, the inputs and the default store and
  journal.
  """
  @spec new(new()) :: Workflow.t() | Error.t()
  def new(args) when is_map(args) do
    name = Map.fetch!(args, :name)
    vertices = Map.fetch!(args, :vertices)

    workflow = %Workflow{
      name: name,
      vertices: vertices,
      start: Map.fetch!(args, :start),
      store: adapter(Map.get(args, :store), @default_store),
      journal: adapter(Map.get(args, :journal), @default_journal),
      metadata: Map.get(args, :metadata) || %{}
    }

    arrows = arrows(workflow)

    workflow = %Workflow{
      workflow
      | arrows: arrows,
        predecessors: Arrow.predecessors(arrows),
        successors: Arrow.successors(arrows)
    }

    with :ok <- check_name(workflow),
         {:ok, inputs} <- parse_inputs(Map.get(args, :inputs, %{})),
         workflow = %Workflow{workflow | inputs: inputs},
         :ok <- check_vertex_names(workflow),
         :ok <- check_start(workflow),
         :ok <- check_targets(workflow),
         :ok <- check_rerun_targets(workflow),
         :ok <- check_node_names(workflow),
         :ok <- check_stage_inputs(workflow),
         :ok <- check_graphs(workflow),
         :ok <- check_adapters(workflow) do
      workflow
    end
  end

  @doc """
  Makes a Workflow, and raises an `ArgumentError` when a check fails.
  """
  @spec new!(new()) :: Workflow.t()
  def new!(args) do
    case new(args) do
      %Workflow{} = workflow -> workflow
      %Error{} = error -> raise ArgumentError, "invalid workflow: #{inspect(error.metadata)}"
    end
  end

  @doc """
  Gives the vertex of `workflow` with the name `name`, or `nil`.
  """
  @spec vertex(workflow :: Workflow.t(), name :: Vertex.name()) :: vertex() | nil
  def vertex(%Workflow{vertices: vertices}, name), do: Map.get(vertices, name)

  @doc """
  Returns `true` when `name` names a Stage of `workflow`.
  """
  @spec stage?(workflow :: Workflow.t(), name :: Vertex.name()) :: boolean()
  def stage?(%Workflow{} = workflow, name), do: kind_of(workflow, name) == :stage

  @doc """
  Returns `true` when `name` names a Decision of `workflow`.
  """
  @spec decision?(workflow :: Workflow.t(), name :: Vertex.name()) :: boolean()
  def decision?(%Workflow{} = workflow, name), do: kind_of(workflow, name) == :decision

  @doc """
  Gives the control targets of `vertex`. A Stage gives its `next`. A Decision
  gives the vertex of each choice. A `:halt` gives no target.

  This function delegates to `DomovoyCore.Vertex.targets/1`.
  """
  @spec targets(vertex :: vertex()) :: [Vertex.name()]
  def targets(vertex), do: Vertex.targets(vertex)

  @spec kind_of(workflow :: Workflow.t(), name :: Vertex.name()) :: Vertex.kind() | nil
  defp kind_of(%Workflow{} = workflow, name) do
    case vertex(workflow, name) do
      nil -> nil
      found -> Vertex.kind(found)
    end
  end

  @spec adapter(given :: module() | adapter() | nil, default :: adapter()) :: adapter()
  defp adapter(nil, default), do: default
  defp adapter({module, opts}, _default) when is_list(opts), do: {module, opts}
  defp adapter(module, _default), do: {module, []}

  @spec arrows(workflow :: Workflow.t()) :: [Arrow.t()]
  defp arrows(%Workflow{vertices: vertices}) do
    vertices
    |> Enum.sort()
    |> Enum.flat_map(fn {name, vertex} ->
      vertex |> targets() |> Enum.map(&Arrow.new(name, &1))
    end)
    |> Enum.uniq()
  end

  @spec parse_inputs(given :: new_inputs()) :: {:ok, inputs()} | Error.t()
  defp parse_inputs(given) when is_map(given) do
    given
    |> Enum.sort()
    |> Enum.reduce_while({:ok, %{}}, fn {name, opts}, {:ok, inputs} ->
      case parse_input(name, opts) do
        {:ok, input} -> {:cont, {:ok, Map.put(inputs, name, input)}}
        {:error, %Error{} = error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, inputs} -> {:ok, inputs}
      {:error, %Error{} = error} -> error
    end
  end

  @spec parse_input(name :: String.t(), opts :: map()) ::
          {:ok, input()} | {:error, Error.t()}
  defp parse_input(name, opts) when is_binary(name) and is_map(opts) do
    case Name.valid?(name) do
      true -> parse_input_options(name, opts)
      false -> {:error, Error.invalid_workflow_input(name, :invalid_name)}
    end
  end

  defp parse_input(name, _opts), do: {:error, Error.invalid_workflow_input(name, :invalid_name)}

  @spec parse_input_options(name :: String.t(), opts :: map()) ::
          {:ok, input()} | {:error, Error.t()}
  defp parse_input_options(name, opts) do
    case Map.get(opts, :type) do
      nil -> {:error, Error.invalid_workflow_input(name, :type_missing)}
      type when is_atom(type) -> parse_input_type(name, type, opts)
      _other -> {:error, Error.invalid_workflow_input(name, :type_missing)}
    end
  end

  @spec parse_input_type(name :: String.t(), type :: atom(), opts :: map()) ::
          {:ok, input()} | {:error, Error.t()}
  defp parse_input_type(name, type, opts) do
    case Type.type?(type) do
      true -> {:ok, %{type: type, default: Map.get(opts, :default)}}
      false -> {:error, Error.invalid_workflow_input(name, :not_a_type)}
    end
  end

  @spec check_name(workflow :: Workflow.t()) :: :ok | Error.t()
  defp check_name(%Workflow{name: name}) do
    if Name.valid?(name) do
      :ok
    else
      Error.invalid_workflow_name(name)
    end
  end

  @spec check_vertex_names(workflow :: Workflow.t()) :: :ok | Error.t()
  defp check_vertex_names(%Workflow{vertices: vertices, name: workflow_name}) do
    vertices
    |> Enum.find(fn {key, vertex} -> key != Vertex.name(vertex) end)
    |> case do
      nil -> :ok
      {key, vertex} -> Error.vertex_name_mismatch(key, Vertex.name(vertex), workflow_name)
    end
  end

  @spec check_start(workflow :: Workflow.t()) :: :ok | Error.t()
  defp check_start(%Workflow{start: start} = workflow), do: check_vertex(workflow, start)

  @spec check_targets(workflow :: Workflow.t()) :: :ok | Error.t()
  defp check_targets(%Workflow{vertices: vertices} = workflow) do
    vertices
    |> Enum.sort()
    |> Enum.flat_map(fn {_name, vertex} -> targets(vertex) end)
    |> Enum.reduce_while(:ok, fn target, :ok ->
      case check_vertex(workflow, target) do
        :ok -> {:cont, :ok}
        %Error{} = error -> {:halt, error}
      end
    end)
  end

  @spec check_rerun_targets(workflow :: Workflow.t()) :: :ok | Error.t()
  defp check_rerun_targets(%Workflow{vertices: vertices, name: workflow_name} = workflow) do
    vertices
    |> Enum.sort()
    |> Enum.flat_map(fn {_name, vertex} ->
      vertex |> Vertex.choices() |> Enum.filter(&Choice.rerun?/1)
    end)
    |> Enum.map(&Choice.target_vertex/1)
    |> Enum.reject(&stage?(workflow, &1))
    |> case do
      [] -> :ok
      [target | _rest] -> Error.rerun_target_not_a_stage(target, workflow_name)
    end
  end

  @spec check_node_names(workflow :: Workflow.t()) :: :ok | Error.t()
  defp check_node_names(%Workflow{name: workflow_name} = workflow) do
    workflow.vertices
    |> Enum.sort()
    |> Enum.reduce_while(:ok, fn {stage_name, vertex}, :ok ->
      names = vertex |> Vertex.graph() |> node_names()
      check_node_names(workflow, names, stage_name, workflow_name)
    end)
  end

  @spec check_node_names(
          workflow :: Workflow.t(),
          names :: [Node.name()],
          stage_name :: Vertex.name(),
          workflow_name :: String.t()
        ) :: {:cont, :ok} | {:halt, Error.t()}
  defp check_node_names(workflow, names, stage_name, workflow_name) do
    input_names = workflow.inputs |> Map.keys() |> MapSet.new()
    choice_names = workflow |> choice_input_names() |> MapSet.new()

    names
    |> Enum.reduce_while(:ok, fn name, :ok ->
      cond do
        name_in_other_stage?(workflow, name, stage_name) ->
          {:halt, Error.name_collision(name, :node, workflow_name)}

        MapSet.member?(input_names, name) ->
          {:halt, Error.name_collision(name, :workflow_input, workflow_name)}

        MapSet.member?(choice_names, name) ->
          {:halt, Error.name_collision(name, :choice_input, workflow_name)}

        true ->
          {:cont, :ok}
      end
    end)
    |> case do
      :ok -> {:cont, :ok}
      %Error{} = error -> {:halt, error}
    end
  end

  @spec name_in_other_stage?(
          workflow :: Workflow.t(),
          name :: Node.name(),
          stage_name :: Vertex.name()
        ) :: boolean()
  defp name_in_other_stage?(%Workflow{vertices: vertices}, name, stage_name) do
    vertices
    |> Enum.any?(fn {other_name, vertex} ->
      other_name != stage_name and Vertex.kind(vertex) == :stage and
        name in node_names(Vertex.graph(vertex))
    end)
  end

  @spec choice_input_names(workflow :: Workflow.t()) :: [String.t()]
  defp choice_input_names(%Workflow{vertices: vertices}) do
    vertices
    |> Enum.flat_map(fn {_name, vertex} -> Vertex.choices(vertex) end)
    |> Enum.flat_map(&Map.keys(&1.inputs))
  end

  # A graph input of a Stage is available when the workflow declares it, or
  # when a prior vertex on a path from `start` writes a record under that name.
  # A Stage that no path from `start` reaches never runs, so it reads nothing.
  @spec check_stage_inputs(workflow :: Workflow.t()) :: :ok | Error.t()
  defp check_stage_inputs(%Workflow{} = workflow) do
    from_start = reachable(workflow.successors, workflow.start, %{})

    workflow.vertices
    |> Enum.sort()
    |> Enum.filter(fn {name, _vertex} ->
      name == workflow.start or Map.has_key?(from_start, name)
    end)
    |> Enum.reduce_while(:ok, fn {name, vertex}, :ok ->
      check_stage_inputs(workflow, name, vertex)
    end)
  end

  @spec check_stage_inputs(
          workflow :: Workflow.t(),
          stage_name :: Vertex.name(),
          vertex :: vertex()
        ) :: {:cont, :ok} | {:halt, Error.t()}
  defp check_stage_inputs(workflow, stage_name, vertex) do
    available = available_names(workflow, stage_name)

    vertex
    |> Vertex.graph()
    |> input_names()
    |> Enum.reduce_while(:ok, fn input_name, :ok ->
      if MapSet.member?(available, input_name) do
        {:cont, :ok}
      else
        {:halt, Error.stage_input_unbound(stage_name, input_name, workflow.name)}
      end
    end)
    |> case do
      :ok -> {:cont, :ok}
      %Error{} = error -> {:halt, error}
    end
  end

  @spec available_names(workflow :: Workflow.t(), stage_name :: Vertex.name()) :: MapSet.t()
  defp available_names(%Workflow{inputs: inputs} = workflow, stage_name) do
    given =
      workflow.vertices
      |> Enum.filter(fn {_name, vertex} -> precedes?(workflow, vertex, stage_name) end)
      |> Enum.flat_map(fn {_name, vertex} -> names_given(vertex) end)

    given |> MapSet.new() |> MapSet.union(MapSet.new(Map.keys(inputs)))
  end

  @spec names_given(vertex :: vertex()) :: [Node.name()]
  defp names_given(vertex) do
    case Vertex.kind(vertex) do
      :stage -> vertex |> Vertex.graph() |> node_names()
      :decision -> vertex |> Vertex.choices() |> Enum.flat_map(&Map.keys(&1.inputs))
    end
  end

  # Returns `true` when a path of one or more control arrows leads from the
  # vertex to the Stage. A cycle through the Stage counts, because a re-run
  # writes new records under the names of the same Stage.
  @spec precedes?(workflow :: Workflow.t(), vertex :: vertex(), stage_name :: Vertex.name()) ::
          boolean()
  defp precedes?(%Workflow{successors: successors}, vertex, stage_name) do
    successors
    |> reachable(Vertex.name(vertex), %{})
    |> Map.has_key?(stage_name)
  end

  @spec reachable(successors :: map(), from :: Vertex.name(), seen :: map()) :: map()
  defp reachable(successors, from, seen) do
    successors
    |> Map.get(from, [])
    |> Enum.reduce(seen, fn next, seen ->
      if Map.has_key?(seen, next) do
        seen
      else
        reachable(successors, next, Map.put(seen, next, true))
      end
    end)
  end

  @spec check_graphs(workflow :: Workflow.t()) :: :ok | Error.t()
  defp check_graphs(%Workflow{vertices: vertices}) do
    vertices
    |> Enum.sort()
    |> Enum.reduce_while(:ok, fn {_name, vertex}, :ok ->
      vertex |> Vertex.graph() |> check_graph()
    end)
  end

  @spec node_names(graph :: Graph.t() | Error.t() | nil) :: [Node.name()]
  defp node_names(nil), do: []
  defp node_names(%Error{}), do: []

  defp node_names(%Graph{} = graph), do: Map.keys(graph.nodes_by_name)

  @spec input_names(graph :: Graph.t() | Error.t() | nil) :: [Node.name()]
  defp input_names(nil), do: []
  defp input_names(%Error{}), do: []

  defp input_names(%Graph{} = graph), do: Map.keys(graph.inputs)

  @spec check_graph(graph :: Graph.t() | Error.t() | nil) :: {:cont, :ok} | {:halt, Error.t()}
  defp check_graph(nil), do: {:cont, :ok}
  defp check_graph(%Error{} = error), do: {:halt, error}

  defp check_graph(%Graph{} = graph) do
    case Order.order(graph) do
      {:ok, _order} -> {:cont, :ok}
      %Error{} = error -> {:halt, error}
    end
  end

  @spec check_adapters(workflow :: Workflow.t()) :: :ok | Error.t()
  defp check_adapters(%Workflow{store: {store, _}, journal: {journal, _}, name: name}) do
    cond do
      not Store.adapter?(store) -> Error.not_an_adapter(store, Store, name)
      not Journal.adapter?(journal) -> Error.not_an_adapter(journal, Journal, name)
      true -> :ok
    end
  end

  @spec check_vertex(workflow :: Workflow.t(), name :: any()) :: :ok | Error.t()
  defp check_vertex(%Workflow{vertices: vertices, name: workflow_name}, name) do
    if Map.has_key?(vertices, name) do
      :ok
    else
      Error.vertex_not_in_workflow(name, workflow_name)
    end
  end
end
