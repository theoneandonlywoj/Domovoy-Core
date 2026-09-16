defmodule DomovoyCore.Engine do
  @moduledoc """
  Runs a `DomovoyCore.Graph` with readiness-driven dataflow scheduling.

  A node starts as soon as all its graph-node predecessors finish successfully.
  `:max_concurrency` limits active runner tasks. It does not make static waves.
  The Engine still calls `DomovoyCore.Engine.Order.waves/1` before execution to
  reject a graph that bypassed normal cycle validation.

  The Engine resolves and validates inputs in its caller process. It runs each
  runner call under the task supervisor selected by the context's runtime. Each attempt uses its own
  `DomovoyCore.Job`, record, timeout, and fixed retry backoff.

  The first terminal failure stops new work. The Engine cancels active nodes,
  cancels pending retries, and skips unstarted nodes. The failure result keeps
  one final record for every graph node.

  A graph input is a data source that no graph node gives. The caller supplies
  a `DomovoyCore.Record` or a `DomovoyCore.Value`. Graph inputs do not appear in the
  returned records.

  ## Options

    * `:max_concurrency` sets the maximum number of active runner tasks. It
      defaults to `System.schedulers_online/0`.
    * `:runners` replaces runners by node name. The Engine validates the full
      map before execution.

  ## Examples

  The Engine calls runners, so this example is illustrative. The graph reads
  the input `"count"`, doubles it, and adds one:

      graph = DomovoyCore.Graph.new([
        DomovoyCore.Node.new(%{
          name: "double",
          runner: MyApp.Runner.Double,
          type: DomovoyCore.Type.Integer,
          bind: %{count: {"count", DomovoyCore.Type.Integer}}
        }),
        DomovoyCore.Node.new(%{
          name: "increment",
          runner: MyApp.Runner.Increment,
          type: DomovoyCore.Type.Integer,
          bind: %{count: {"double", DomovoyCore.Type.Integer}}
        })
      ])
      job = DomovoyCore.Job.new("dom-58")
      context = %DomovoyCore.Context{job: job, workflow: "doc"}
      count = DomovoyCore.Value.cast!(20, DomovoyCore.Type.Integer)
      {:ok, records} = DomovoyCore.Engine.run(graph, %{"count" => count}, context)
      %DomovoyCore.Record{result: %DomovoyCore.Value{value: increment}} = records["increment"]
      increment
      41

  A failure gives the primary error and a final record for every graph node.
  The node that failed keeps status `:error`, and its unstarted successor is
  `:skipped`:

      {:error, %DomovoyCore.Error{} = error, records} =
        DomovoyCore.Engine.run(graph, %{}, context)
      {error.type, records["double"].status, records["increment"].status}
      {:node_not_in_graph, :error, :skipped}
  """

  alias DomovoyCore.Context
  alias DomovoyCore.Engine.Order
  alias DomovoyCore.Engine.Resolve
  alias DomovoyCore.Engine.Scheduler
  alias DomovoyCore.Error
  alias DomovoyCore.Event
  alias DomovoyCore.Graph
  alias DomovoyCore.Job
  alias DomovoyCore.Journal
  alias DomovoyCore.Node
  alias DomovoyCore.Record
  alias DomovoyCore.Runner
  alias DomovoyCore.Runtime
  alias DomovoyCore.Store
  alias DomovoyCore.Value
  alias Ecto.Changeset

  @type input() :: Record.t() | Value.t()
  @type inputs() :: %{Node.name() => input()}
  @type records() :: %{Node.name() => Record.t()}
  @type opts() :: keyword()
  @type result() :: {:ok, records()} | {:error, Error.t(), records()}

  @doc "Runs `graph` in `context` and gives a tagged result with final records."
  @spec run(
          graph :: Graph.t() | Error.t(),
          inputs :: inputs(),
          context :: Context.t(),
          opts :: opts()
        ) :: result()
  def run(graph, inputs, context, opts \\ [])

  def run(%Graph{} = graph, inputs, %Context{} = context, opts)
      when is_map(inputs) and is_list(opts) do
    runners = Keyword.get(opts, :runners, %{})
    max_concurrency = Keyword.get(opts, :max_concurrency, System.schedulers_online())

    with :ok <- validate_runner_overrides(graph, runners),
         :ok <- validate_max_concurrency(max_concurrency),
         {:ok, _waves} <- Order.waves(graph),
         {:ok, input_records} <- prepare_inputs(graph, inputs, context),
         {:ok, hits} <- preload_hits(graph, context),
         :ok <- announce_hits(hits, context) do
      state = %{
        graph: graph,
        context: context,
        input_records: input_records,
        scheduler: Scheduler.new(graph, hits),
        active: %{},
        retry_timers: %{},
        max_concurrency: max_concurrency,
        runners: runners,
        cancellation: Process.get(:domovoy_workflow_step),
        in_process?: Keyword.get(opts, :in_process?, false),
        primary_error: nil
      }

      previous_trap_exit? = Process.flag(:trap_exit, true)

      try do
        coordinate(state)
      after
        Process.flag(:trap_exit, previous_trap_exit?)
      end
    else
      %Error{} = error -> {:error, error, %{}}
      {:error, %Error{} = error} -> {:error, error, %{}}
    end
  end

  def run(%Error{} = error, inputs, %Context{}, opts) when is_map(inputs) and is_list(opts),
    do: {:error, error, %{}}

  @spec coordinate(state :: map()) :: result()
  defp coordinate(state) do
    state = fill_slots(state)

    cond do
      Scheduler.halted?(state.scheduler) ->
        finish_failure(state)

      Scheduler.done?(state.scheduler) ->
        {:ok, Scheduler.records(state.scheduler)}

      true ->
        wait_for_message(state)
    end
  end

  @spec wait_for_message(state :: map()) :: result()
  defp wait_for_message(state) do
    active = state.active
    retry_timers = state.retry_timers

    receive do
      {ref, result} when is_reference(ref) and is_map_key(active, ref) ->
        state |> accept_task_result(ref, result) |> coordinate()

      {:DOWN, ref, :process, pid, reason} when is_reference(ref) and is_map_key(active, ref) ->
        state |> accept_task_exit(ref, pid, reason) |> coordinate()

      {:EXIT, pid, _reason} when is_pid(pid) ->
        if cancellation_owner?(state.cancellation, pid) and not active_pid?(active, pid) do
          stop_coordinator(state)
        else
          coordinate(state)
        end

      {:domovoy_cancel_workflow_step, owner, step_id} ->
        if state.cancellation == {owner, step_id} do
          stop_coordinator(state)
        else
          coordinate(state)
        end

      {:domovoy_engine_timeout, token, ref} when is_map_key(active, ref) ->
        state |> accept_timeout(token, ref) |> coordinate()

      {:domovoy_engine_retry, token, node_name} when is_map_key(retry_timers, node_name) ->
        state |> accept_retry(token, node_name) |> coordinate()
    end
  end

  @spec fill_slots(state :: map()) :: map()
  defp fill_slots(state) do
    if map_size(state.active) < state.max_concurrency and not Scheduler.halted?(state.scheduler) do
      case Scheduler.ready(state.scheduler) do
        {{node_name, ordinal}, scheduler} ->
          state
          |> Map.put(:scheduler, scheduler)
          |> start_attempt(node_name, ordinal)
          |> fill_slots()

        {nil, scheduler} ->
          Map.put(state, :scheduler, scheduler)
      end
    else
      state
    end
  end

  @spec start_attempt(state :: map(), node_name :: Node.name(), ordinal :: pos_integer()) :: map()
  defp start_attempt(state, node_name, ordinal) do
    node = Map.fetch!(state.graph.nodes_by_name, node_name)
    runner = Map.get(state.runners, node_name, node.runner)
    context = attempt_context(state.context, node_name, ordinal)
    records = Map.merge(state.input_records, Scheduler.records(state.scheduler))

    case prepare(node, records, context, runner) do
      {:ok, invocation} -> start_prepared(state, node, runner, context, ordinal, invocation)
      %Error{} = error -> preparation_failed(state, node, context, error)
    end
  end

  @spec start_prepared(
          state :: map(),
          node :: Node.t(),
          runner :: module(),
          context :: Context.t(),
          ordinal :: pos_integer(),
          invocation :: map()
        ) :: map()
  defp start_prepared(state, node, runner, context, ordinal, invocation) do
    started_at = DateTime.utc_now()

    case journal(context, :node_started, %{}) do
      :ok ->
        if state.in_process? do
          result = invoke_safely(invocation, node, runner)

          accept_outcome(
            state,
            node,
            context,
            ordinal,
            runner,
            started_at,
            result
          )
        else
          start_task(state, node, runner, context, ordinal, invocation, started_at)
        end

      {:error, %Error{} = error} ->
        preparation_failed(state, node, context, error)
    end
  end

  @spec start_task(
          state :: map(),
          node :: Node.t(),
          runner :: module(),
          context :: Context.t(),
          ordinal :: pos_integer(),
          invocation :: map(),
          started_at :: DateTime.t()
        ) :: map()
  defp start_task(state, node, runner, context, ordinal, invocation, started_at) do
    group_leader = Process.group_leader()
    coordinator = self()

    task =
      Task.Supervisor.async_nolink(Runtime.engine_task_supervisor(context.runtime), fn ->
        Process.link(coordinator)
        Process.group_leader(self(), group_leader)
        invoke(invocation, node, runner)
      end)

    {timeout_timer, timeout_token} = schedule_timeout(task.ref, node.retry.timeout_ms)

    info = %{
      pid: task.pid,
      ref: task.ref,
      node: node,
      runner: runner,
      context: context,
      ordinal: ordinal,
      started_at: started_at,
      start_time: System.monotonic_time(:millisecond),
      timeout_timer: timeout_timer,
      timeout_token: timeout_token
    }

    %{state | active: Map.put(state.active, task.ref, info)}
  end

  @spec accept_task_result(state :: map(), ref :: reference(), result :: term()) :: map()
  defp accept_task_result(state, ref, result) do
    case Map.pop(state.active, ref) do
      {nil, _active} ->
        state

      {info, active} ->
        cancel_timeout(info)
        Process.demonitor(ref, [:flush])

        state
        |> Map.put(:active, active)
        |> accept_outcome(
          info.node,
          info.context,
          info.ordinal,
          info.runner,
          info.started_at,
          result
        )
    end
  end

  @spec accept_task_exit(
          state :: map(),
          ref :: reference(),
          pid :: pid(),
          reason :: term()
        ) :: map()
  defp accept_task_exit(state, ref, _pid, reason) do
    case Map.pop(state.active, ref) do
      {nil, _active} ->
        state

      {info, active} ->
        cancel_timeout(info)
        error = task_exit_error(info.node.name, info.runner, reason)

        state
        |> Map.put(:active, active)
        |> accept_outcome(
          info.node,
          info.context,
          info.ordinal,
          info.runner,
          info.started_at,
          error
        )
    end
  end

  @spec accept_timeout(state :: map(), token :: reference(), ref :: reference()) :: map()
  defp accept_timeout(state, token, ref) do
    case Map.get(state.active, ref) do
      %{timeout_token: ^token} = info ->
        active = Map.delete(state.active, ref)
        state = %{state | active: active}

        _ =
          Task.Supervisor.terminate_child(
            Runtime.engine_task_supervisor(info.context.runtime),
            info.pid
          )

        Process.demonitor(ref, [:flush])
        flush_task_result(ref)

        error = %Error{
          type: :timeout,
          reason: %{node: info.node.name, timeout_ms: info.node.retry.timeout_ms},
          retryable?: true
        }

        accept_outcome(
          state,
          info.node,
          info.context,
          info.ordinal,
          info.runner,
          info.started_at,
          error
        )

      _other ->
        state
    end
  end

  @spec accept_retry(state :: map(), token :: reference(), node_name :: Node.name()) :: map()
  defp accept_retry(state, token, node_name) do
    case Map.get(state.retry_timers, node_name) do
      {_timer, ^token} ->
        %{
          state
          | retry_timers: Map.delete(state.retry_timers, node_name),
            scheduler: Scheduler.retry_ready(state.scheduler, node_name)
        }

      _other ->
        state
    end
  end

  @spec accept_outcome(
          state :: map(),
          node :: Node.t(),
          context :: Context.t(),
          ordinal :: pos_integer(),
          runner :: module(),
          started_at :: DateTime.t(),
          result :: term()
        ) :: map()
  defp accept_outcome(state, node, context, ordinal, runner, started_at, result) do
    outcome = normalize_result(result, node, runner)
    record = persist_outcome(outcome, node, context, started_at)
    advance(state, node, context, ordinal, record)
  end

  @spec preparation_failed(
          state :: map(),
          node :: Node.t(),
          context :: Context.t(),
          error :: Error.t()
        ) :: map()
  defp preparation_failed(state, node, context, %Error{} = error) do
    error = %Error{error | retryable?: false}
    record = persist_outcome(error, node, context, nil)
    advance(state, node, context, context.job.attempt - state.context.job.attempt + 1, record)
  end

  @spec advance(
          state :: map(),
          node :: Node.t(),
          context :: Context.t(),
          ordinal :: pos_integer(),
          record :: Record.t()
        ) :: map()
  defp advance(state, node, _context, _ordinal, %Record{status: :ok} = record) do
    %{state | scheduler: Scheduler.complete(state.scheduler, node.name, record)}
  end

  defp advance(state, node, _context, _ordinal, %Record{status: :error, result: error} = record) do
    case Scheduler.fail(state.scheduler, node.name, record, node.retry) do
      {:retry, next_ordinal, scheduler} ->
        next_context = attempt_context(state.context, node.name, next_ordinal)
        payload = %{"backoff_ms" => node.retry.backoff_ms}

        case journal(next_context, :node_retried, payload) do
          :ok ->
            token = make_ref()

            timer =
              Process.send_after(
                self(),
                {:domovoy_engine_retry, token, node.name},
                node.retry.backoff_ms
              )

            %{
              state
              | scheduler: scheduler,
                retry_timers: Map.put(state.retry_timers, node.name, {timer, token})
            }

          {:error, %Error{} = journal_error} ->
            failed = persist_outcome(journal_error, node, next_context, nil)
            {:halt, scheduler} = Scheduler.fail(scheduler, node.name, failed, node.retry)
            %{state | scheduler: scheduler, primary_error: journal_error}
        end

      {:halt, scheduler} ->
        %{state | scheduler: scheduler, primary_error: error}
    end
  end

  @spec finish_failure(state :: map()) :: result()
  defp finish_failure(state) do
    active_by_name = Map.new(state.active, fn {_ref, info} -> {info.node.name, info} end)
    cancel_retry_timers(state.retry_timers)
    cancel_active_tasks(state.active)

    classified =
      Enum.map(Scheduler.cancelled(state.scheduler), &{&1, :cancelled}) ++
        Enum.map(Scheduler.skipped(state.scheduler), &{&1, :skipped})

    records = Scheduler.records(state.scheduler)

    records =
      classified
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.reduce(records, fn {node_name, status}, records ->
        %Record{} = record = Map.fetch!(records, node_name)

        record =
          case Map.get(active_by_name, node_name) do
            %{started_at: started_at} ->
              %Record{record | started_at: started_at, finished_at: DateTime.utc_now()}

            nil ->
              record
          end

        node = Map.fetch!(state.graph.nodes_by_name, node_name)
        _ = persist_classification(record, node, state.context, status)
        Map.put(records, node_name, record)
      end)

    {:error, state.primary_error, records}
  end

  @spec cancel_active_tasks(active :: map()) :: :ok
  defp cancel_active_tasks(active) do
    Enum.each(active, fn {ref, info} ->
      cancel_timeout(info)

      _ =
        Task.Supervisor.terminate_child(
          Runtime.engine_task_supervisor(info.context.runtime),
          info.pid
        )

      Process.demonitor(ref, [:flush])
      flush_task_result(ref)
    end)

    :ok
  end

  @spec cancel_retry_timers(retry_timers :: map()) :: :ok
  defp cancel_retry_timers(retry_timers) do
    Enum.each(retry_timers, fn {node_name, {timer, token}} ->
      _ = Process.cancel_timer(timer)
      flush_retry(token, node_name)
    end)

    :ok
  end

  @spec active_pid?(active :: map(), pid :: pid()) :: boolean()
  defp active_pid?(active, pid) do
    active
    |> Map.values()
    |> Enum.any?(fn info -> info.pid == pid end)
  end

  @spec cancellation_owner?(cancellation :: {pid(), non_neg_integer()} | nil, pid :: pid()) ::
          boolean()
  defp cancellation_owner?({owner, _step_id}, pid), do: owner == pid
  defp cancellation_owner?(nil, _pid), do: false

  @spec stop_coordinator(state :: map()) :: no_return()
  defp stop_coordinator(state) do
    cancel_retry_timers(state.retry_timers)
    cancel_active_tasks(state.active)
    exit(:shutdown)
  end

  @spec prepare(
          node :: Node.t(),
          records :: records(),
          context :: Context.t(),
          runner :: module()
        ) :: {:ok, map()} | Error.t()
  defp prepare(%Node{} = node, records, %Context{} = context, runner) do
    case Resolve.params(node, records, context, runner) do
      {:ok, params} ->
        changeset =
          runner
          |> Runner.changeset(params)
          |> validate(runner.__domovoy_core__(:validators) ++ node.validators, context)

        case Changeset.apply_action(changeset, :run) do
          {:ok, input} -> {:ok, %{input: input, context: context}}
          {:error, invalid} -> %Error{type: :invalid_input, reason: invalid.errors}
        end

      %Error{} = error ->
        %Error{error | retryable?: false}
    end
  end

  @spec invoke(invocation :: map(), node :: Node.t(), runner :: module()) :: term()
  defp invoke(%{input: input, context: context}, %Node{}, runner),
    do: runner.run(input, context)

  @spec invoke_safely(invocation :: map(), node :: Node.t(), runner :: module()) :: term()
  defp invoke_safely(invocation, %Node{} = node, runner) do
    invoke(invocation, node, runner)
  rescue
    exception -> task_exit_error(node.name, runner, exception)
  catch
    kind, reason -> task_exit_error(node.name, runner, {kind, reason})
  end

  @spec normalize_result(
          result :: term(),
          node :: Node.t(),
          runner :: module()
        ) :: Value.t() | Error.t()
  defp normalize_result({:ok, raw}, %Node{} = node, runner),
    do: normalize_value(Value.cast(raw, node.type), node, runner)

  defp normalize_result({:ok, raw, metadata}, %Node{} = node, runner)
       when is_map(metadata) and not is_struct(metadata),
       do: normalize_value(Value.cast(raw, node.type, metadata), node, runner)

  defp normalize_result({:error, %Error{} = error}, %Node{}, _runner), do: error

  defp normalize_result({:error, reason}, %Node{}, _runner),
    do: Error.new(%{type: :runner_failed, reason: reason, retryable?: true})

  defp normalize_result(%Error{} = error, %Node{}, _runner), do: error

  defp normalize_result(_result, %Node{} = node, runner),
    do: %Error{type: :invalid_runner_result, reason: %{node: node.name, runner: runner}}

  @spec normalize_value(
          result :: {:ok, Value.t()} | {:error, Error.t()},
          node :: Node.t(),
          runner :: module()
        ) :: Value.t() | Error.t()
  defp normalize_value({:ok, %Value{} = value}, %Node{}, _runner), do: value
  defp normalize_value({:error, %Error{} = error}, %Node{}, _runner), do: error

  @spec persist_outcome(
          outcome :: Value.t() | Error.t(),
          node :: Node.t(),
          context :: Context.t(),
          started_at :: DateTime.t() | nil
        ) :: Record.t()
  defp persist_outcome(outcome, %Node{} = node, %Context{} = context, started_at) do
    record = attempt_record(outcome, context, started_at)

    record =
      case store_record(record, node, context) do
        :ok -> record
        {:error, %Error{} = error} -> attempt_record(error, context, started_at)
      end

    case announce(record, context) do
      :ok ->
        record

      {:error, %Error{} = error} ->
        failed = attempt_record(error, context, started_at)
        _ = store_record(failed, node, context)
        failed
    end
  end

  @spec attempt_record(
          outcome :: Value.t() | Error.t(),
          context :: Context.t(),
          started_at :: DateTime.t() | nil
        ) :: Record.t()
  defp attempt_record(outcome, %Context{} = context, started_at) do
    Record.new(%{
      job: context.job,
      node: context.node,
      status: status(outcome),
      result: outcome,
      started_at: started_at,
      finished_at: DateTime.utc_now()
    })
  end

  @spec status(outcome :: Value.t() | Error.t()) :: :ok | :error
  defp status(%Value{}), do: :ok
  defp status(%Error{}), do: :error

  @spec announce(record :: Record.t(), context :: Context.t()) :: :ok | {:error, Error.t()}
  defp announce(%Record{status: :ok}, %Context{} = context),
    do: journal(context, :node_finished, %{"hit" => false})

  defp announce(%Record{status: :error, result: %Error{} = error}, %Context{} = context),
    do: journal(context, :node_failed, %{"error_type" => Atom.to_string(error.type)})

  @spec persist_classification(
          record :: Record.t(),
          node :: Node.t(),
          context :: Context.t(),
          status :: :cancelled | :skipped
        ) :: :ok
  defp persist_classification(%Record{} = record, %Node{} = node, %Context{} = context, status) do
    attempt_context = %Context{context | job: record.job, node: record.node}
    _ = store_record(record, node, attempt_context)
    kind = if status == :cancelled, do: :node_cancelled, else: :node_skipped
    _ = journal(attempt_context, kind, %{})
    :ok
  end

  @spec store_record(record :: Record.t(), node :: Node.t(), context :: Context.t()) ::
          :ok | {:error, Error.t()}
  defp store_record(%Record{} = record, %Node{} = node, %Context{store: store}) do
    if Node.store?(node), do: put(store, record), else: :ok
  end

  @spec prepare_inputs(graph :: Graph.t(), inputs :: inputs(), context :: Context.t()) ::
          {:ok, records()} | Error.t()
  defp prepare_inputs(%Graph{} = graph, inputs, %Context{} = context) do
    inputs
    |> Map.take(Map.keys(graph.inputs))
    |> Enum.sort()
    |> Enum.reduce_while({:ok, %{}}, fn {name, input}, {:ok, records} ->
      case prepare_input(name, input, context) do
        %Record{} = record -> {:cont, {:ok, Map.put(records, name, record)}}
        %Error{} = error -> {:halt, error}
      end
    end)
  end

  @spec prepare_input(name :: Node.name(), input :: input(), context :: Context.t()) ::
          Record.t() | Error.t()
  defp prepare_input(_name, %Record{} = record, %Context{}), do: record

  defp prepare_input(name, %Value{} = value, %Context{} = context) do
    record = Record.new(%{job: context.job, node: name, status: :ok, result: value})

    case put(context.store, record) do
      :ok -> record
      {:error, %Error{} = error} -> error
    end
  end

  @spec preload_hits(graph :: Graph.t(), context :: Context.t()) ::
          {:ok, records()} | Error.t()
  defp preload_hits(%Graph{} = graph, %Context{} = context) do
    graph.nodes_by_name
    |> Map.keys()
    |> Enum.sort()
    |> Enum.reduce_while({:ok, %{}}, fn name, {:ok, hits} ->
      hit_context = %Context{context | node: name}

      case hit(hit_context) do
        {:ok, %Record{} = record} -> {:cont, {:ok, Map.put(hits, name, record)}}
        :miss -> {:cont, {:ok, hits}}
        {:error, %Error{} = error} -> {:halt, error}
      end
    end)
  end

  @spec announce_hits(hits :: records(), context :: Context.t()) :: :ok | {:error, Error.t()}
  defp announce_hits(hits, %Context{} = context) do
    hits
    |> Enum.sort()
    |> Enum.reduce_while(:ok, fn {name, record}, :ok ->
      hit_context = %Context{context | job: record.job, node: name}
      payload = %{"hit" => true, "attempt" => record.job.attempt}

      case journal(hit_context, :node_finished, payload) do
        :ok -> {:cont, :ok}
        {:error, %Error{} = error} -> {:halt, {:error, error}}
      end
    end)
  end

  @spec hit(context :: Context.t()) :: Store.read()
  defp hit(%Context{store: nil}), do: :miss

  defp hit(%Context{store: store, node: node, job: %Job{} = job}),
    do: Store.get(store, node, job.generation)

  @spec validate(changeset :: Changeset.t(), validators :: [module()], context :: Context.t()) ::
          Changeset.t()
  defp validate(%Changeset{} = changeset, validators, %Context{} = context) do
    Enum.reduce(validators, changeset, fn validator, changeset ->
      validator.validate(changeset, context)
    end)
  end

  @spec attempt_context(
          context :: Context.t(),
          node_name :: Node.name(),
          ordinal :: pos_integer()
        ) ::
          Context.t()
  defp attempt_context(%Context{} = context, node_name, ordinal) do
    absolute_attempt = context.job.attempt + ordinal - 1

    %Context{
      context
      | job: Job.at_attempt(context.job, absolute_attempt),
        node: node_name
    }
  end

  @spec schedule_timeout(ref :: reference(), timeout_ms :: :infinity | pos_integer()) ::
          {reference() | nil, reference() | nil}
  defp schedule_timeout(_ref, :infinity), do: {nil, nil}

  defp schedule_timeout(ref, timeout_ms) do
    token = make_ref()
    timer = Process.send_after(self(), {:domovoy_engine_timeout, token, ref}, timeout_ms)
    {timer, token}
  end

  @spec cancel_timeout(info :: map()) :: :ok
  defp cancel_timeout(%{timeout_timer: nil}), do: :ok

  defp cancel_timeout(%{timeout_timer: timer, timeout_token: token, ref: ref}) do
    _ = Process.cancel_timer(timer)
    flush_timeout(token, ref)
  end

  @spec flush_timeout(token :: reference(), ref :: reference()) :: :ok
  defp flush_timeout(token, ref) do
    receive do
      {:domovoy_engine_timeout, ^token, ^ref} -> :ok
    after
      0 -> :ok
    end
  end

  @spec flush_retry(token :: reference(), node_name :: Node.name()) :: :ok
  defp flush_retry(token, node_name) do
    receive do
      {:domovoy_engine_retry, ^token, ^node_name} -> :ok
    after
      0 -> :ok
    end
  end

  @spec flush_task_result(ref :: reference()) :: :ok
  defp flush_task_result(ref) do
    receive do
      {^ref, _result} -> :ok
      {:DOWN, ^ref, :process, _pid, _reason} -> flush_task_result(ref)
    after
      0 -> :ok
    end
  end

  @spec task_exit_error(node_name :: Node.name(), runner :: module(), reason :: term()) ::
          Error.t()
  defp task_exit_error(node_name, runner, reason) do
    reason =
      case exception_module(reason) do
        nil -> %{node: node_name, runner: runner, exit: :abnormal}
        module -> %{node: node_name, runner: runner, exception: module}
      end

    %Error{type: :runner_failed, reason: reason, retryable?: true}
  end

  @spec exception_module(reason :: term()) :: module() | nil
  defp exception_module({%module{}, _stacktrace}) when is_atom(module), do: module
  defp exception_module(%module{}) when is_atom(module), do: module
  defp exception_module({_kind, reason}), do: exception_module(reason)
  defp exception_module(_reason), do: nil

  @spec put(store :: Store.t() | nil, record :: Record.t()) :: :ok | {:error, Error.t()}
  defp put(nil, %Record{}), do: :ok
  defp put(%Store{} = store, %Record{} = record), do: Store.put(store, record)

  @spec journal(context :: Context.t(), kind :: Event.kind(), payload :: map()) ::
          :ok | {:error, Error.t()}
  defp journal(%Context{journal: nil}, _kind, _payload), do: :ok

  defp journal(%Context{journal: %Journal{} = journal} = context, kind, payload) do
    event = Event.new(%{job: context.job, kind: kind, subject: context.node, payload: payload})
    Journal.append(journal, event)
  end

  @spec validate_max_concurrency(term()) :: :ok | Error.t()
  defp validate_max_concurrency(value) when is_integer(value) and value > 0, do: :ok

  defp validate_max_concurrency(_value),
    do: %Error{type: :invalid_max_concurrency, reason: %{expected: :positive_integer}}

  @doc """
  Validates every execution-time runner override.

  An override accepts only a typed runner with equal fields, field types,
  required fields, and extras support.
  """
  @spec validate_runner_overrides(graph :: Graph.t(), runners :: term()) :: :ok | Error.t()
  def validate_runner_overrides(%Graph{} = graph, runners) do
    if is_map(runners) and not is_struct(runners) do
      runners |> Enum.sort() |> validate_runner_override_entries(graph)
    else
      invalid_override(%{expected: :map})
    end
  end

  @spec validate_runner_override_entries(entries :: list(), graph :: Graph.t()) ::
          :ok | Error.t()
  defp validate_runner_override_entries(entries, %Graph{} = graph) do
    Enum.reduce_while(entries, :ok, fn {name, runner}, :ok ->
      case validate_runner_override(graph, name, runner) do
        :ok -> {:cont, :ok}
        %Error{} = error -> {:halt, error}
      end
    end)
  end

  @spec validate_runner_override(graph :: Graph.t(), name :: term(), runner :: term()) ::
          :ok | Error.t()
  defp validate_runner_override(%Graph{} = graph, name, runner) do
    declared = Map.get(graph.nodes_by_name, name)

    cond do
      is_nil(declared) ->
        invalid_override(%{node: name, expected: :graph_node})

      not is_atom(runner) or not Code.ensure_loaded?(runner) ->
        invalid_override(%{node: name, expected: :loaded_module})

      not typed_runner?(runner) ->
        invalid_override(%{node: name, expected: :typed_runner})

      not compatible_schema?(declared.runner, runner) ->
        invalid_override(%{node: name, expected: :compatible_input_schema})

      not function_exported?(runner, :run, 2) ->
        invalid_override(%{node: name, expected: :runner})

      true ->
        :ok
    end
  end

  @spec typed_runner?(runner :: module()) :: boolean()
  defp typed_runner?(runner) do
    Code.ensure_loaded?(runner) and function_exported?(runner, :__domovoy_core__, 1)
  end

  @spec compatible_schema?(declared :: module(), override :: module()) :: boolean()
  defp compatible_schema?(declared, override) do
    declared_input = declared.__domovoy_core__(:input)
    override_input = override.__domovoy_core__(:input)
    declared_fields = declared_input.__schema__(:fields)
    override_fields = override_input.__schema__(:fields)

    Enum.sort(declared_fields) == Enum.sort(override_fields) and
      Enum.all?(declared_fields, fn field ->
        declared_input.__schema__(:type, field) == override_input.__schema__(:type, field)
      end) and
      Enum.sort(declared.__domovoy_core__(:required)) ==
        Enum.sort(override.__domovoy_core__(:required)) and
      declared.__domovoy_core__(:extra?) == override.__domovoy_core__(:extra?)
  rescue
    _error -> false
  end

  @spec invalid_override(reason :: map()) :: Error.t()
  defp invalid_override(reason), do: %Error{type: :invalid_runner_override, reason: reason}
end
