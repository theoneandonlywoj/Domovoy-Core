defmodule DomovoyCore.Run do
  @moduledoc """
  The state of one run of a `DomovoyCore.Workflow`, and the functions that move
  its cursor.

  The run holds no records. The `DomovoyCore.Store` of the run holds each record,
  and the `DomovoyCore.Journal` holds each event. The run holds the
  `DomovoyCore.Job`, the name of the workflow, the cursor, the status, the
  re-run limit and the open store and journal. The job names the run and
  holds its generation. The state of a run is therefore small, and it does
  not grow with the size of a graph. The journal is the history.

  A run has one of four statuses:

    * `:ready` — the vertex under the cursor can run. `step/2` runs it.
    * `:awaiting_decision` — the cursor is on a Decision whose decider waits
      for a person. `decide/4` takes the answer of the person.
    * `:finished` — the last Stage ran, or a choice halted the workflow.
    * `:failed` — a Stage, a decider, the store or the journal gave an error.
      `error` holds it.

  The generation of the job starts at `0`. Each `{:rerun, stage}` calls
  `DomovoyCore.Job.next_generation/1`. A Stage at generation `1` writes its own
  records, and the records of generation `0` stay in the store. A re-run that
  would rise the generation past `max_generations` fails the run with
  `DomovoyCore.Error.rerun_limit_exceeded/2`. The default limit is `10`.

  ## Deciders

  `step/2` asks the decider of a Decision what happens next. The default
  decider, `DomovoyCore.Decider.Person`, gives `:await`, so the run stops and a
  person answers with `decide/4`. A Decision that names its own decider
  answers on its own, and the run moves on without a stop. A decider can add
  a value for each input that the chosen choice declares.

  ## The order of `decide/4`

  1. `DomovoyCore.Decision.choice/2` resolves the name to a `DomovoyCore.Choice`.
  2. `DomovoyCore.Run` casts each value of `inputs` with the type that the choice
     declares for it. A value for an input that the choice does not declare
     refuses the answer.
  3. The record of the answer goes to the store under the name of the
     Decision, at the current generation.
  4. A `{:rerun, stage}` target raises the generation. The count rises first.
  5. Each cast input goes to the store at the new generation.
  6. The journal gets `:decided`, and the cursor moves to the target.

  Step 4 before step 5 lets a person send new text into a re-run. The Stage
  reads that text as a graph input at the new generation, and
  `DomovoyCore.Store.latest/3` finds it first.

  An answer that the Decision does not offer, a value that its choice refuses,
  or an answer to a run that waits for no person, does not end the run. The
  run comes back with `error` set and its status unchanged, so a caller can
  ask again.

  ## Events, apply and replay

  Each step appends to the journal: `:run_started`, `:stage_started`,
  `:stage_finished` or `:stage_failed`, `:decision_awaited`, `:decided`,
  `:run_finished`, `:run_halted` and `:run_failed`. The subject of a run
  event is the name of the workflow, and the payload names the cursor. The
  Engine appends the node events. A journal that cannot take an event fails
  the run.

  `apply/2` folds one event into the state of a run. It is pure, and it needs
  no store, no journal and no process. `replay/2` opens the journal of a run,
  folds every event with `apply/2`, and gives the run back with the store and
  the journal open. A run that stopped mid-stage therefore resumes from the
  records of its store.

  ## Examples

  `start/4` and `step/2` open a store and run runners, so this example is
  illustrative:

      job = DomovoyCore.Job.new("dom-30", %{"issue_id" => "DOM-30"})
      inputs = %{"issue_id" => DomovoyCore.Value.cast!("30", DomovoyCore.Type.String)}
      run = DomovoyCore.Run.start(MyDomovoy, workflow, inputs, job: job)
      {run.status, run.cursor, run.job.generation}
      {:ready, "prepare", 0}
      run = DomovoyCore.Run.run_to_decision(workflow, run)
      {run.status, run.cursor}
      {:awaiting_decision, "review_plan"}
      run = DomovoyCore.Run.decide(workflow, run, "revise", %{"plan_context" => "Keep the public API."})
      {run.status, run.cursor, run.job.generation}
      {:ready, "plan", 1}
      {:ok, events} = DomovoyCore.Journal.events(run.journal)
      Enum.map(events, & &1.kind)
      [:run_started, :stage_started, :node_started, :node_finished, ...]
      run = DomovoyCore.Run.replay(MyDomovoy, workflow, run.job.id)
      {run.status, run.cursor, run.job.generation}
      {:ready, "plan", 1}

  `apply/2` needs no store, so its examples run as they are. See the
  documentation of `apply/2`.
  """

  alias DomovoyCore.Choice
  alias DomovoyCore.Context
  alias DomovoyCore.Decision
  alias DomovoyCore.Engine
  alias DomovoyCore.Error
  alias DomovoyCore.Event
  alias DomovoyCore.Graph
  alias DomovoyCore.Job
  alias DomovoyCore.Journal
  alias DomovoyCore.Name
  alias DomovoyCore.Node
  alias DomovoyCore.Record
  alias DomovoyCore.Run
  alias DomovoyCore.Runtime
  alias DomovoyCore.Stage
  alias DomovoyCore.Store
  alias DomovoyCore.Value
  alias DomovoyCore.Vertex
  alias DomovoyCore.Workflow

  @default_max_generations 10

  @type status() :: :ready | :awaiting_decision | :finished | :failed
  @type inputs() :: %{Node.name() => Value.t() | any()}
  @type metadata() :: %{String.t() => any()}

  @typedoc "A choice name with the choice as a `DomovoyCore.Value`."
  @type answer() :: {Choice.name(), Value.t()}

  @type t() :: %Run{
          job: Job.t(),
          workflow: String.t(),
          cursor: Vertex.name() | nil,
          status: status(),
          max_generations: pos_integer(),
          error: Error.t() | nil,
          store: Store.t() | nil,
          journal: Journal.t() | nil,
          runtime: Runtime.ref() | nil,
          runners: %{Node.name() => module()},
          metadata: metadata()
        }

  @soft_errors [:choice_not_offered, :run_not_awaiting_decision, :invalid_choice_inputs]

  defstruct job: nil,
            workflow: nil,
            cursor: nil,
            status: :ready,
            max_generations: @default_max_generations,
            error: nil,
            store: nil,
            journal: nil,
            runtime: nil,
            runners: %{},
            metadata: %{}

  @doc """
  Starts a run of `workflow`.

  This function opens the store and the journal of the workflow for the run,
  casts each value of `inputs` with the type that `workflow.inputs` declares
  for it, casts and writes the default of each declared input that the caller
  does not provide, and fingerprints the cast values. It writes one record for
  each value under the job. It appends `:run_started` with the fingerprint and
  puts the cursor on `workflow.start`. A store or journal that does not open
  gives `status: :failed`.

  A value for an input that the workflow does not declare gives
  `DomovoyCore.Error.invalid_workflow_input/2`.

  ## Options

    * `:job` — the `DomovoyCore.Job` of the run. `DomovoyCore.Job.new/2` checks the
      id, so no adapter sees a name it must clean. The default is a job with
      a `DomovoyCore.Name.random/0` id and no metadata.
    * `:runners` — execution-time runner overrides, keyed by graph node name.
      This function validates all overrides before any stage runs.
      The run keeps overrides through decisions and generations. It does not persist them.
    * `:max_generations` — the highest generation that a re-run may reach.
      The default is `10`. A re-run that would rise
      the generation past the limit fails with
      `DomovoyCore.Error.rerun_limit_exceeded/2`.
  """
  @spec start(Runtime.ref(), workflow :: Workflow.t(), inputs :: inputs(), opts :: keyword()) ::
          Run.t()
  def start(runtime, %Workflow{} = workflow, inputs, opts \\ [])
      when is_atom(runtime) and is_map(inputs) and is_list(opts) do
    job = job(opts)

    run = %Run{
      job: job,
      workflow: workflow.name,
      cursor: workflow.start,
      status: :ready,
      runtime: runtime,
      max_generations: max_generations(opts),
      runners: Keyword.get(opts, :runners, %{})
    }

    with :ok <- validate_runners(workflow, run.runners),
         {:ok, values} <- prepare_inputs(workflow, inputs),
         {:ok, %Run{} = opened} <- open(workflow, run) do
      begun(opened, values)
    else
      %Error{} = error -> fail(run, error)
      {:error, %Error{} = error} -> fail(run, error)
    end
  end

  @doc false
  @spec input_fingerprint(workflow :: Workflow.t(), inputs :: inputs()) ::
          {:ok, String.t()} | {:error, Error.t()}
  def input_fingerprint(%Workflow{} = workflow, inputs) when is_map(inputs) do
    with {:ok, values} <- prepare_inputs(workflow, inputs) do
      {:ok, fingerprint(values)}
    end
  end

  @doc """
  Gives the `DomovoyCore.Context` of `run`.

  `DomovoyCore.Stage.run/3` and a `DomovoyCore.Decider` get this context. It holds
  the job, the workflow, the store and the journal.
  """
  @spec context(run :: Run.t()) :: Context.t()
  def context(%Run{} = run) do
    %Context{
      job: run.job,
      workflow: run.workflow,
      store: run.store,
      journal: run.journal,
      runtime: run.runtime
    }
  end

  @doc """
  Runs the vertex under the cursor.

  A Stage runs, and the cursor moves to its `next`. A `next` of `nil`
  finishes the run. A Decision asks its decider. A decider that gives
  `:await` sets `:awaiting_decision`, and the run stops. A decider that picks
  a choice moves the cursor to its target. A run that is not `:ready` comes
  back unchanged.
  """
  @spec step(workflow :: Workflow.t(), run :: Run.t()) :: Run.t()
  def step(%Workflow{} = workflow, %Run{status: :ready, cursor: cursor} = run)
      when is_binary(cursor) do
    case Workflow.vertex(workflow, cursor) do
      nil ->
        fail(run, Error.vertex_not_in_workflow(cursor, workflow.name))

      vertex ->
        case Vertex.kind(vertex) do
          :stage -> run_stage(run, vertex)
          :decision -> step_decision(workflow, run, vertex)
        end
    end
  end

  def step(%Workflow{}, %Run{} = run), do: run

  @doc """
  Calls `step/2` until the status is not `:ready`.
  """
  @spec run_to_decision(workflow :: Workflow.t(), run :: Run.t()) :: Run.t()
  def run_to_decision(%Workflow{} = workflow, %Run{status: :ready} = run) do
    run_to_decision(workflow, step(workflow, run))
  end

  def run_to_decision(%Workflow{}, %Run{} = run), do: run

  @doc """
  Takes the answer `choice_name` of a person, and the values in `inputs` that
  the person adds with it.

  See the moduledoc for the order of the steps.
  """
  @spec decide(
          workflow :: Workflow.t(),
          run :: Run.t(),
          choice_name :: Choice.name(),
          inputs :: inputs()
        ) :: Run.t()
  def decide(%Workflow{} = workflow, %Run{} = run, choice_name, inputs \\ %{})
      when is_binary(choice_name) and is_map(inputs) do
    result =
      case awaited_decision(workflow, run) do
        %Error{} = error -> error
        decision -> follow(workflow, run, decision, choice_name, inputs)
      end

    case result do
      %Run{} = next -> next
      %Error{type: type} = error when type in @soft_errors -> refuse(run, error)
      %Error{} = error -> fail(run, error)
    end
  end

  @doc """
  Folds one `DomovoyCore.Event` into `run` and gives the next run.

  This function is the one pure state transition of a run. It opens no store,
  it appends no journal and it starts no process. `replay/2` folds every
  event of a journal with it, so the state of a run is what its events say.

  A `:run_started` event sets the workflow, the cursor, the job and the input
  fingerprint. An old event without a fingerprint remains valid. A
  `:stage_started` event moves the cursor to its subject. A
  `:decision_awaited` event moves the cursor and waits. A `:decided` event
  takes the job of the event, which holds the raised generation, and moves
  the cursor to the target. A `:run_finished` or `:run_halted` event ends the
  run. A `:run_failed` event fails it. The node events change no state of
  the run, because each node job holds its own attempt.

  The error of a failed run round-trips through the journal. The
  `:run_failed` payload holds the full dumped error under `"error"`, with
  `"error_type"` and `"cursor"` beside it for readers that need no reason.
  `apply/2` loads the dumped error back, so the replayed run keeps the type,
  the reason, the retry flag and the metadata. A payload from an older
  release with only `"error_type"` still gives the type.

  ## Examples

      iex> job = DomovoyCore.Job.new("dom-30")
      iex> run = %DomovoyCore.Run{job: job, workflow: "review_double"}
      iex> run = DomovoyCore.Run.apply(run, DomovoyCore.Event.new(%{
      ...>   job: job,
      ...>   kind: :run_started,
      ...>   subject: "review_double",
      ...>   payload: %{"cursor" => "prepare"}
      ...> }))
      iex> {run.status, run.cursor}
      {:ready, "prepare"}
      iex> run = DomovoyCore.Run.apply(run, DomovoyCore.Event.new(%{
      ...>   job: job,
      ...>   kind: :stage_started,
      ...>   subject: "prepare"
      ...> }))
      iex> run = DomovoyCore.Run.apply(run, DomovoyCore.Event.new(%{
      ...>   job: job,
      ...>   kind: :decision_awaited,
      ...>   subject: "review"
      ...> }))
      iex> {run.status, run.cursor}
      {:awaiting_decision, "review"}
      iex> next = DomovoyCore.Job.next_generation(job)
      iex> run = DomovoyCore.Run.apply(run, DomovoyCore.Event.new(%{
      ...>   job: next,
      ...>   kind: :decided,
      ...>   subject: "review",
      ...>   payload: %{"choice" => "rerun", "target" => %{"kind" => "rerun", "vertex" => "prepare"}}
      ...> }))
      iex> {run.status, run.cursor, run.job.generation}
      {:ready, "prepare", 1}
      iex> run = DomovoyCore.Run.apply(run, DomovoyCore.Event.new(%{
      ...>   job: next,
      ...>   kind: :run_finished,
      ...>   subject: nil
      ...> }))
      iex> {run.status, run.cursor}
      {:finished, nil}
  """
  @spec apply(run :: Run.t(), event :: Event.t()) :: Run.t()
  def apply(%Run{} = run, %Event{kind: :run_started, subject: workflow} = event) do
    metadata =
      case Map.get(event.payload, "input_fingerprint") do
        fingerprint when is_binary(fingerprint) ->
          Map.put(run.metadata, "input_fingerprint", fingerprint)

        _other ->
          Map.delete(run.metadata, "input_fingerprint")
      end

    %Run{
      run
      | workflow: workflow,
        cursor: Map.get(event.payload, "cursor"),
        status: :ready,
        job: event.job,
        error: nil,
        metadata: metadata
    }
  end

  def apply(%Run{} = run, %Event{kind: :stage_started, subject: stage} = event) do
    %Run{run | cursor: stage, status: :ready, job: event.job}
  end

  def apply(%Run{} = run, %Event{kind: :decision_awaited, subject: decision} = event) do
    %Run{run | cursor: decision, status: :awaiting_decision, job: event.job}
  end

  def apply(%Run{} = run, %Event{kind: :decided, payload: payload} = event) do
    run = %Run{run | job: event.job}

    case target_vertex(Map.get(payload, "target")) do
      vertex when is_binary(vertex) -> %Run{run | cursor: vertex, status: :ready}
      _other -> run
    end
  end

  def apply(%Run{} = run, %Event{kind: kind}) when kind in [:run_finished, :run_halted] do
    %Run{run | cursor: nil, status: :finished}
  end

  def apply(%Run{} = run, %Event{kind: :run_failed, payload: payload}) do
    %Run{run | status: :failed, error: rebuilt_error(payload)}
  end

  def apply(%Run{} = run, %Event{}) do
    run
  end

  @doc """
  Rebuilds the run of `workflow` with the id `run_id` from its journal.

  This function opens the store and the journal of the workflow for the run,
  reads every event in order, and folds each one with `apply/2`. The run that
  comes back holds the cursor, the status, the job and the error that the
  events say, with the store and the journal open. A caller can resume a run
  that stopped mid-stage, because the Engine reads the records of earlier
  nodes from the store.

  A journal that holds no event gives the run at the start vertex, as
  `start/4` gives it before any step.

  ## Options

    * `:runners` — execution-time runner overrides, as in `start/4`.
    * `:max_generations` — the re-run limit, as in `start/4`.
  """
  @spec replay(Runtime.ref(), workflow :: Workflow.t(), run_id :: String.t(), opts :: keyword()) ::
          Run.t()
  def replay(runtime, %Workflow{} = workflow, run_id, opts \\ [])
      when is_atom(runtime) and is_binary(run_id) and is_list(opts) do
    run = %Run{
      job: Job.new(run_id),
      workflow: workflow.name,
      cursor: workflow.start,
      status: :ready,
      runtime: runtime,
      max_generations: max_generations(opts),
      runners: Keyword.get(opts, :runners, %{})
    }

    with {:ok, %Run{} = opened} <- open(workflow, run),
         {:ok, events} <- Journal.events(opened.journal) do
      Enum.reduce(events, opened, fn event, current -> Run.apply(current, event) end)
    else
      {:error, %Error{} = error} -> fail(run, error)
    end
  end

  @spec job(opts :: keyword()) :: Job.t()
  defp job(opts) do
    case Keyword.get(opts, :job) do
      %Job{} = job -> job
      nil -> Job.new(Name.random())
      other -> raise ArgumentError, "job must be a %DomovoyCore.Job{}, got: #{inspect(other)}"
    end
  end

  @spec max_generations(opts :: keyword()) :: pos_integer()
  defp max_generations(opts) do
    case Keyword.get(opts, :max_generations, @default_max_generations) do
      max when is_integer(max) and max >= 1 ->
        max

      other ->
        raise ArgumentError,
              "max_generations must be a positive integer, got: #{inspect(other)}"
    end
  end

  @spec open(workflow :: Workflow.t(), run :: Run.t()) :: {:ok, Run.t()} | {:error, Error.t()}
  defp open(%Workflow{store: {store, store_opts}, journal: {journal, journal_opts}}, %Run{} = run) do
    with {:ok, store} <- Store.open(store, run.job.id, adapter_opts(store_opts, run)),
         {:ok, journal} <-
           Journal.open(run.runtime, journal, run.job.id, adapter_opts(journal_opts, run)) do
      {:ok, %Run{run | store: store, journal: journal}}
    end
  end

  @spec validate_runners(workflow :: Workflow.t(), runners :: term()) :: :ok | Error.t()
  defp validate_runners(%Workflow{vertices: vertices}, runners) do
    stages =
      vertices
      |> Enum.sort()
      |> Enum.filter(fn {_name, vertex} -> Vertex.kind(vertex) == :stage end)

    names =
      Enum.flat_map(stages, fn {_name, vertex} -> vertex |> Vertex.graph() |> node_names() end)

    cond do
      not is_map(runners) or is_struct(runners) ->
        Error.new(%{type: :invalid_runner_override, reason: %{expected: :map}})

      Enum.any?(Map.keys(runners), &(&1 not in names)) ->
        Error.new(%{type: :invalid_runner_override, reason: %{expected: :workflow_node}})

      true ->
        Enum.reduce_while(stages, :ok, &validate_stage_runners(&1, &2, runners))
    end
  end

  @spec validate_stage_runners(
          stage :: {Vertex.name(), Vertex.vertex()},
          result :: :ok,
          runners :: map()
        ) :: {:cont, :ok} | {:halt, Error.t()}
  defp validate_stage_runners({_name, vertex}, :ok, runners) do
    graph = Vertex.graph(vertex)
    overrides = Map.take(runners, node_names(graph))

    case Engine.validate_runner_overrides(graph, overrides) do
      :ok -> {:cont, :ok}
      %Error{} = error -> {:halt, error}
    end
  end

  @spec adapter_opts(opts :: keyword(), run :: Run.t()) :: keyword()
  defp adapter_opts(opts, %Run{workflow: workflow}), do: Keyword.put(opts, :workflow, workflow)

  # Casts each provided value with its declared type, then casts and adds the
  # default of each declared input that the caller does not provide.
  @spec prepare_inputs(workflow :: Workflow.t(), inputs :: inputs()) ::
          {:ok, inputs()} | {:error, Error.t()}
  defp prepare_inputs(%Workflow{inputs: declared}, inputs) do
    with {:ok, values} <- provided_values(declared, inputs) do
      default_values(declared, values)
    end
  end

  @spec provided_values(declared :: Workflow.inputs(), inputs :: inputs()) ::
          {:ok, inputs()} | {:error, Error.t()}
  defp provided_values(declared, inputs) do
    inputs
    |> Enum.sort()
    |> Enum.reduce_while({:ok, %{}}, fn {name, given}, {:ok, values} ->
      case declared_input(declared, name, given) do
        {:ok, %Value{} = value} -> {:cont, {:ok, Map.put(values, name, value)}}
        {:error, %Error{} = error} -> {:halt, {:error, error}}
      end
    end)
  end

  @spec declared_input(
          declared :: Workflow.inputs(),
          name :: Node.name(),
          given :: Value.t() | any()
        ) :: {:ok, Value.t()} | {:error, Error.t()}
  defp declared_input(declared, name, given) do
    case Map.get(declared, name) do
      %{type: type} ->
        case cast_value(given, type) do
          {:ok, %Value{} = value} -> {:ok, value}
          {:error, %Error{} = error} -> {:error, Error.invalid_workflow_input(name, error.reason)}
        end

      nil ->
        {:error, Error.invalid_workflow_input(name, :not_declared)}
    end
  end

  @spec default_values(declared :: Workflow.inputs(), provided :: inputs()) ::
          {:ok, inputs()} | {:error, Error.t()}
  defp default_values(declared, provided) do
    declared
    |> Enum.reject(fn {name, %{default: default}} ->
      default == nil or Map.has_key?(provided, name)
    end)
    |> Enum.reduce_while({:ok, provided}, fn {name, %{type: type, default: default}},
                                             {:ok, values} ->
      case Value.cast(default, type) do
        {:ok, %Value{} = value} ->
          {:cont, {:ok, Map.put(values, name, value)}}

        {:error, %Error{} = error} ->
          {:halt, {:error, Error.invalid_workflow_input(name, error.reason)}}
      end
    end)
  end

  # A value that is already a %DomovoyCore.Value{} casts its raw content with the
  # declared type, so a wrong type cannot pass. A raw value casts as it is.
  @spec cast_value(given :: Value.t() | any(), type :: module()) ::
          {:ok, Value.t()} | {:error, Error.t()}
  defp cast_value(%Value{value: raw, metadata: metadata}, type),
    do: Value.cast(raw, type, metadata)

  defp cast_value(raw, type), do: Value.cast(raw, type)

  @spec begun(run :: Run.t(), inputs :: inputs()) :: Run.t()
  defp begun(%Run{} = run, inputs) do
    fingerprint = fingerprint(inputs)
    started = %Run{run | metadata: Map.put(run.metadata, "input_fingerprint", fingerprint)}
    payload = started |> cursor_payload() |> Map.put("input_fingerprint", fingerprint)

    with :ok <- write_inputs(started, inputs),
         :ok <- journal(started, :run_started, payload) do
      started
    else
      {:error, %Error{} = error} -> fail(started, error)
    end
  end

  @spec fingerprint(inputs :: inputs()) :: String.t()
  defp fingerprint(inputs) do
    encoded = :erlang.term_to_binary(inputs, [:deterministic, {:minor_version, 1}])

    :crypto.hash(:sha256, encoded)
    |> Base.encode16(case: :lower)
  end

  @spec awaited_decision(workflow :: Workflow.t(), run :: Run.t()) ::
          Workflow.vertex() | Error.t()
  defp awaited_decision(
         %Workflow{} = workflow,
         %Run{status: :awaiting_decision, cursor: cursor}
       ) do
    case Workflow.vertex(workflow, cursor) do
      nil -> Error.run_not_awaiting_decision(workflow.name, cursor, :awaiting_decision)
      vertex -> awaiting_decision(workflow, vertex, cursor)
    end
  end

  defp awaited_decision(%Workflow{} = workflow, %Run{cursor: cursor, status: status}) do
    Error.run_not_awaiting_decision(workflow.name, cursor, status)
  end

  @spec awaiting_decision(
          workflow :: Workflow.t(),
          vertex :: Workflow.vertex(),
          cursor :: Vertex.name()
        ) :: Workflow.vertex() | Error.t()
  defp awaiting_decision(workflow, vertex, cursor) do
    if Vertex.kind(vertex) == :decision do
      vertex
    else
      Error.run_not_awaiting_decision(workflow.name, cursor, :awaiting_decision)
    end
  end

  @spec run_stage(run :: Run.t(), vertex :: Workflow.vertex()) :: Run.t()
  defp run_stage(%Run{} = run, vertex) do
    runners = Map.take(run.runners, node_names(Vertex.graph(vertex)))

    with :ok <- journal(run, :stage_started, Vertex.name(vertex), %{}),
         {:ok, records} <- Stage.run(vertex, context(run), runners: runners),
         :ok <- journal(run, :stage_finished, Vertex.name(vertex), stage_payload(records)) do
      move_after_stage(run, vertex)
    else
      {:error, %Error{} = error} -> fail(run, error)
      {:error, %Error{} = error, _records} -> stage_failed(run, vertex, error)
    end
  end

  @spec move_after_stage(run :: Run.t(), vertex :: Workflow.vertex()) :: Run.t()
  defp move_after_stage(%Run{} = run, vertex) do
    case Vertex.targets(vertex) do
      [next] -> move(run, next)
      [] -> move(run, nil)
    end
  end

  @spec stage_failed(run :: Run.t(), vertex :: Workflow.vertex(), error :: Error.t()) :: Run.t()
  defp stage_failed(%Run{} = run, vertex, %Error{} = error) do
    name = Vertex.name(vertex)
    payload = %{"error_type" => Atom.to_string(error.type)}

    case journal(run, :stage_failed, name, payload) do
      :ok -> fail(run, error)
      {:error, %Error{} = journal_error} -> fail(run, journal_error)
    end
  end

  @spec step_decision(workflow :: Workflow.t(), run :: Run.t(), decision :: Workflow.vertex()) ::
          Run.t()
  defp step_decision(workflow, %Run{} = run, decision) do
    {module, opts} = Decision.decider_parts(decision)

    case module.decide(decision, context(run), opts) do
      :await ->
        await(run, decision)

      {:ok, choice_name} when is_binary(choice_name) ->
        follow_or_fail(workflow, run, decision, choice_name, %{})

      {:ok, choice_name, inputs} when is_binary(choice_name) and is_map(inputs) ->
        follow_or_fail(workflow, run, decision, choice_name, inputs)

      {:error, reason} ->
        fail(run, Error.decider_failed(Vertex.name(decision), reason))

      other ->
        fail(run, Error.decider_failed(Vertex.name(decision), {:unexpected, other}))
    end
  end

  @spec follow_or_fail(
          workflow :: Workflow.t(),
          run :: Run.t(),
          decision :: Decision.t(),
          choice_name :: Choice.name(),
          inputs :: inputs()
        ) :: Run.t()
  defp follow_or_fail(workflow, %Run{} = run, decision, choice_name, inputs) do
    case follow(workflow, run, decision, choice_name, inputs) do
      %Run{} = next -> next
      %Error{} = error -> fail(run, error)
    end
  end

  @spec await(run :: Run.t(), decision :: Workflow.vertex()) :: Run.t()
  defp await(%Run{} = run, decision) do
    payload = %{"choices" => Decision.choice_names(decision)}

    case journal(run, :decision_awaited, Vertex.name(decision), payload) do
      :ok -> %Run{run | status: :awaiting_decision}
      {:error, %Error{} = error} -> fail(run, error)
    end
  end

  # Resolves the choice, casts its inputs, checks the re-run limit, then
  # writes the answer, the inputs and the event, and moves the cursor.
  @spec follow(
          workflow :: Workflow.t(),
          run :: Run.t(),
          decision :: Workflow.vertex(),
          choice_name :: Choice.name(),
          given :: inputs()
        ) :: Run.t() | Error.t()
  defp follow(workflow, %Run{} = run, decision, choice_name, given) do
    with {:ok, choice} <- choice_of(decision, choice_name),
         {:ok, inputs} <- choice_inputs(decision, choice, given),
         :ok <- rerun_limit(workflow, run, choice),
         %Value{} = answer <- Decision.answer(decision, choice_name),
         %Run{} = next <- proceed(run, decision, choice, answer, inputs) do
      next
    else
      {:error, %Error{} = error} -> error
      %Error{} = error -> error
    end
  end

  @spec choice_of(decision :: Workflow.vertex(), choice_name :: Choice.name()) ::
          {:ok, Choice.t()} | {:error, Error.t()}
  defp choice_of(decision, choice_name) do
    case Decision.choice(decision, choice_name) do
      %Choice{} = choice -> {:ok, choice}
      %Error{} = error -> {:error, error}
    end
  end

  # Casts each given value with the type that the choice declares for it. A
  # value for an input that the choice does not declare gives an error.
  @spec choice_inputs(
          decision :: Workflow.vertex(),
          choice :: Choice.t(),
          given :: inputs()
        ) :: {:ok, inputs()} | {:error, Error.t()}
  defp choice_inputs(decision, %Choice{inputs: declared}, given) do
    decision_name = Vertex.name(decision)

    given
    |> Enum.sort()
    |> Enum.reduce_while({:ok, %{}}, fn {name, value}, {:ok, inputs} ->
      case cast_input(Map.get(declared, name), value) do
        {:ok, %Value{} = cast} -> {:cont, {:ok, Map.put(inputs, name, cast)}}
        :error -> {:halt, {:error, Error.invalid_choice_inputs(decision_name, name)}}
      end
    end)
  end

  @spec cast_input(declared :: DomovoyCore.Type.t() | nil, value :: Value.t() | any()) ::
          {:ok, Value.t()} | :error
  defp cast_input(type, value) when is_atom(type) and not is_nil(type) do
    case cast_value(value, type) do
      {:ok, %Value{} = cast} -> {:ok, cast}
      {:error, %Error{}} -> :error
    end
  end

  defp cast_input(nil, _value), do: :error

  @spec rerun_limit(workflow :: Workflow.t(), run :: Run.t(), choice :: Choice.t()) ::
          :ok | {:error, Error.t()}
  defp rerun_limit(
         %Workflow{name: name},
         %Run{job: %Job{generation: generation}, max_generations: max},
         %Choice{target: {:rerun, _stage}}
       ) do
    if generation + 1 > max do
      {:error, Error.rerun_limit_exceeded(name, max)}
    else
      :ok
    end
  end

  defp rerun_limit(%Workflow{}, %Run{}, %Choice{}), do: :ok

  # Writes the answer at the current generation, raises the generation of the
  # job for a re-run, writes the inputs, appends :decided, and moves the
  # cursor. The job on the :decided event is therefore the job after the
  # decision.
  @spec proceed(
          run :: Run.t(),
          decision :: Workflow.vertex(),
          choice :: Choice.t(),
          answer :: Value.t(),
          inputs :: inputs()
        ) :: Run.t() | Error.t()
  defp proceed(%Run{} = run, decision, %Choice{target: target} = choice, answer, inputs) do
    decision_name = Vertex.name(decision)
    next = %Run{run | job: job_for_target(run.job, target), error: nil}

    with :ok <- write_value(run, decision_name, answer),
         :ok <- write_inputs(next, inputs),
         :ok <- journal(next, :decided, decision_name, decided_payload(choice.name, target)) do
      go(next, target, decision_name)
    else
      {:error, %Error{} = error} -> error
    end
  end

  @spec job_for_target(job :: Job.t(), target :: Choice.target()) :: Job.t()
  defp job_for_target(%Job{} = job, {:rerun, _stage}), do: Job.next_generation(job)
  defp job_for_target(%Job{} = job, _target), do: job

  @spec go(run :: Run.t(), target :: Choice.target(), decision_name :: Vertex.name()) ::
          Run.t() | Error.t()
  defp go(%Run{} = run, :halt, decision_name) do
    halted = %Run{run | cursor: nil, status: :finished}

    case journal(halted, :run_halted, %{"decision" => decision_name}) do
      :ok -> halted
      {:error, %Error{} = error} -> fail(run, error)
    end
  end

  defp go(%Run{} = run, {_kind, vertex}, _decision_name), do: move(run, vertex)

  @spec move(run :: Run.t(), next :: Vertex.name() | nil) :: Run.t() | Error.t()
  defp move(%Run{cursor: cursor} = run, nil) do
    finished = %Run{run | cursor: nil, status: :finished}

    case journal(finished, :run_finished, %{"last" => cursor}) do
      :ok -> finished
      {:error, %Error{} = error} -> fail(run, error)
    end
  end

  defp move(%Run{} = run, next), do: %Run{run | cursor: next, status: :ready}

  @spec fail(run :: Run.t(), error :: Error.t()) :: Run.t()
  defp fail(%Run{} = run, %Error{} = error) do
    failed = %Run{run | status: :failed, error: error}
    payload = failed |> cursor_payload() |> failed_payload(error)
    _result = journal(failed, :run_failed, payload)

    failed
  end

  @doc """
  Fails `run` when its step task exits without a result.

  This function builds a `run_step_crashed` error from `cause` and appends
  `:run_failed` with the cursor, the error type and the full dumped error.
  It writes no store record, as `fail/2` writes none. It gives the failed
  run and the result of the append, so the caller sees a journal failure.

  A replay with `apply/2` folds the `:run_failed` event back to the same
  `failed` status with the same type and reason.

  ## Examples

      iex> job = DomovoyCore.Job.new("dom-30")
      iex> run = %DomovoyCore.Run{job: job, workflow: "issue_to_pr", cursor: "prepare", status: :ready}
      iex> {failed, :ok} = DomovoyCore.Run.crash(run, :killed)
      iex> {failed.status, failed.error.type}
      {:failed, :run_step_crashed}
  """
  @spec crash(run :: Run.t(), cause :: term()) :: {Run.t(), :ok | {:error, Error.t()}}
  def crash(%Run{} = run, cause) do
    error = Error.run_step_crashed(run.workflow, run.job.id, cause)
    failed = %Run{run | status: :failed, error: error}
    payload = failed |> cursor_payload() |> failed_payload(error)

    {failed, journal(failed, :run_failed, payload)}
  end

  @spec refuse(run :: Run.t(), error :: Error.t()) :: Run.t()
  defp refuse(%Run{} = run, %Error{} = error), do: %Run{run | error: error}

  @spec write_inputs(run :: Run.t(), inputs :: inputs()) :: :ok | {:error, Error.t()}
  defp write_inputs(%Run{} = run, inputs) do
    inputs
    |> Enum.sort()
    |> Enum.reduce_while(:ok, fn {name, %Value{} = value}, :ok ->
      case write_value(run, name, value) do
        :ok -> {:cont, :ok}
        {:error, %Error{} = error} -> {:halt, {:error, error}}
      end
    end)
  end

  @spec write_value(run :: Run.t(), name :: Node.name(), value :: Value.t()) ::
          :ok | {:error, Error.t()}
  defp write_value(%Run{store: %Store{} = store} = run, name, %Value{} = value) do
    record = Record.new(%{job: run.job, node: name, status: :ok, result: value})

    Store.put(store, record)
  end

  @spec journal(run :: Run.t(), kind :: Event.kind(), payload :: map()) ::
          :ok | {:error, Error.t()}
  defp journal(%Run{workflow: workflow} = run, kind, payload),
    do: journal(run, kind, workflow, payload)

  @spec journal(run :: Run.t(), kind :: Event.kind(), subject :: String.t(), payload :: map()) ::
          :ok | {:error, Error.t()}
  defp journal(%Run{journal: nil}, _kind, _subject, _payload), do: :ok

  defp journal(%Run{journal: %Journal{} = journal, job: job}, kind, subject, payload) do
    Journal.append(
      journal,
      Event.new(%{job: job, kind: kind, subject: subject, payload: payload})
    )
  end

  @spec target_vertex(target :: any()) :: Vertex.name() | :halt | nil
  defp target_vertex("halt"), do: :halt
  defp target_vertex(%{"vertex" => vertex}) when is_binary(vertex), do: vertex
  defp target_vertex(_other), do: nil

  @spec rebuilt_error(payload :: map()) :: Error.t() | nil
  defp rebuilt_error(%{"error" => %{"type" => _type} = document}) do
    case Error.load(document) do
      {:ok, %Error{} = error} -> error
      {:error, %Error{}} -> rebuilt_type(document)
    end
  end

  defp rebuilt_error(%{"error" => _other} = payload), do: rebuilt_type(payload)
  defp rebuilt_error(%{"error_type" => _type} = payload), do: rebuilt_type(payload)

  defp rebuilt_error(_payload), do: nil

  @spec rebuilt_type(payload :: map()) :: Error.t() | nil
  defp rebuilt_type(%{"error_type" => type}) when is_binary(type) do
    %Error{type: String.to_existing_atom(type)}
  rescue
    ArgumentError -> nil
  end

  defp rebuilt_type(_payload), do: nil

  @spec failed_payload(payload :: map(), error :: Error.t()) :: map()
  defp failed_payload(payload, %Error{} = error) do
    payload
    |> Map.put("error_type", Atom.to_string(error.type))
    |> Map.put("error", Error.dump(error))
  end

  @spec node_names(graph :: Graph.t() | DomovoyCore.Error.t() | nil) :: [Node.name()]
  defp node_names(nil), do: []
  defp node_names(%DomovoyCore.Error{}), do: []

  defp node_names(%Graph{} = graph), do: Map.keys(graph.nodes_by_name)

  @spec cursor_payload(run :: Run.t()) :: %{String.t() => any()}
  defp cursor_payload(%Run{cursor: cursor}), do: %{"cursor" => cursor}

  @spec stage_payload(records :: %{Node.name() => Record.t()}) :: %{String.t() => any()}
  defp stage_payload(records), do: %{"nodes" => records |> Map.keys() |> Enum.sort()}

  @spec decided_payload(choice_name :: Choice.name(), target :: Choice.target()) ::
          %{String.t() => any()}
  defp decided_payload(choice_name, target) do
    %{"choice" => choice_name, "target" => target_payload(target)}
  end

  @spec target_payload(target :: Choice.target()) :: String.t() | %{String.t() => String.t()}
  defp target_payload(:halt), do: "halt"
  defp target_payload({kind, vertex}), do: %{"kind" => Atom.to_string(kind), "vertex" => vertex}
end
