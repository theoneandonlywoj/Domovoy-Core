defmodule DomovoyCore.Workflow.Server do
  @moduledoc """
  One process owner for one run of a workflow.

  The server holds one `%DomovoyCore.Run{}` and one task ref. It runs initialization
  and each step under the selected runtime's workflow task supervisor. It stays responsive
  while the task runs. It adds no input resolution, validation, or persistence.
  It drives the executor through `DomovoyCore.Run`.

  The registry key is `{workflow_name, run_id}`. The `run_id` stays stable.
  The generation and the attempt change, so the server never keys on the full
  job. The store, the journal files and the PubSub topic all key on the same
  pair, so one run id under two workflow names gives two isolated runs.

  The server sends no broadcast of its own. `DomovoyCore.Journal.append/2` sends
  `{:domovoy_event, event}` on `DomovoyCore.Journal.topic/2`. The server emits
  telemetry spans for start, resume, decide and drive.

  During initialization, `state/1` gives `{:error, :starting}`. It then gives a
  view with `workflow`, `run_id`, `status`, `cursor`, `generation` and `error`.
  It never gives the open store or journal. A caller that needs records opens
  the store by `run_id`.

  ## Examples

  The server starts processes and writes to disk, so this example is
  illustrative. It builds a small workflow with one stage and one decision:

      alias DomovoyCore.Workflow.Server
      prepare = DomovoyCore.Stage.new(%{name: "prepare", graph: DomovoyCore.Graph.new(), next: "review"})
      review = DomovoyCore.Decision.new(%{name: "review", prompt: "Go?", choices: [DomovoyCore.Choice.new(%{name: "approve", description: "Go.", target: :halt})]})
      workflow = DomovoyCore.Workflow.new!(%{name: "review_double", vertices: %{"prepare" => prepare, "review" => review}, start: "prepare", inputs: %{"count" => [type: DomovoyCore.Type.Integer]}})
      job = DomovoyCore.Job.new("dom-43")
      :ok = Server.subscribe(MyDomovoy, workflow.name, job.id)
      {:ok, pid} = Server.start(MyDomovoy, workflow, %{"count" => 3}, job: job)
      is_pid(pid)
      true
      receive do
        {:domovoy_event, %DomovoyCore.Event{kind: :decision_awaited}} -> :ok
      after
        5_000 -> :timeout
      end
      :ok
      view = Server.state(pid)
      view.workflow
      "review_double"
      Server.whereis(MyDomovoy, workflow.name, job.id) == pid
      true
      :ok = Server.stop(pid)
      :ok
  """

  use GenServer

  require Logger

  alias DomovoyCore.Error
  alias DomovoyCore.Job
  alias DomovoyCore.Journal
  alias DomovoyCore.Name
  alias DomovoyCore.Run
  alias DomovoyCore.Runtime
  alias DomovoyCore.Store
  alias DomovoyCore.Vertex
  alias DomovoyCore.Workflow
  alias DomovoyCore.Workflow.Server.Telemetry

  @drive_retry_ms 50

  @typedoc "The task that runs one step, or `nil` when the server idles."
  @type task_info() ::
          %{ref: reference(), pid: pid(), step_id: non_neg_integer(), started_at: integer()} | nil

  @typedoc "The view that `state/1` and `decide/3` give. It holds no store."
  @type view() :: %{
          workflow: String.t(),
          run_id: String.t(),
          status: atom(),
          cursor: String.t() | nil,
          generation: non_neg_integer(),
          error: Error.t() | nil
        }

  @typedoc "The server holds the workflow, the run, the task and the fence."
  @type state() :: %{
          runtime: Runtime.ref(),
          workflow: Workflow.t(),
          run: Run.t() | nil,
          task: task_info(),
          step_id: non_neg_integer(),
          input_fingerprint: String.t() | nil,
          pending_init: {map(), keyword()} | nil,
          drive_queued?: boolean(),
          retry_timer: {reference(), reference()} | nil
        }

  @typedoc "The init arg for a fresh run or for a replayed run."
  @type init_arg() ::
          {:start, Runtime.ref(), Workflow.t(), Run.inputs(), keyword()}
          | {:resume, Runtime.ref(), Workflow.t(), Run.t()}

  @doc """
  Starts the server for `workflow` with `inputs`.

  This function registers the server under `{workflow.name, job.id}`. It
  makes a job with a random id when `opts` holds no `:job`. `opts` holds
  `:job`, `:runners` and `:max_generations`. The server runs `Run.start/4`
  in a bounded task that `handle_continue/2` starts. `start_child/2` returns
  after `init/1`, so the `via` name is visible at once. The server then drives
  while the run stays `:ready`.

  A bad `:job` gives `{:error, %Error{type: :invalid_server_job}}`, not an
  exit.

  ## Examples

  This function starts a process, so this example is illustrative:

      DomovoyCore.Workflow.Server.start_link(MyDomovoy, workflow, %{"count" => 3}, job: job)
      {:ok, pid}
  """
  @spec start_link(
          runtime :: Runtime.ref(),
          workflow :: Workflow.t(),
          inputs :: Run.inputs(),
          opts :: keyword()
        ) ::
          GenServer.on_start()
  def start_link(runtime, %Workflow{} = workflow, inputs, opts \\ [])
      when is_atom(runtime) and is_map(inputs) and is_list(opts) do
    case ensure_job(opts) do
      {:ok, ensured} ->
        %Job{id: run_id} = Keyword.fetch!(ensured, :job)

        GenServer.start_link(__MODULE__, {:start, runtime, workflow, inputs, ensured},
          name: via(runtime, workflow.name, run_id)
        )

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  @doc """
  Starts the server or gives the server that already runs.

  This function makes a job with a random id when `opts` holds no `:job`.
  A second call with the same `{workflow.name, job.id}`, the same workflow
  name and equal inputs gives `{:ok, pid}` of the one server. A second call
  with other inputs or another workflow name gives `{:error, %Error{type:
  :run_input_mismatch}}`. A new `run_id` gives a new pid. The same `run_id`
  under another workflow name gives a new pid, with an isolated store,
  journal and PubSub topic. A resumed server skips the inputs check, because
  the replay holds no input map.

  ## Examples

  This function starts a process, so this example is illustrative:

      DomovoyCore.Workflow.Server.start(MyDomovoy, workflow, %{"count" => 3}, job: job)
      {:ok, pid}
  """
  @spec start(
          runtime :: Runtime.ref(),
          workflow :: Workflow.t(),
          inputs :: Run.inputs(),
          opts :: keyword()
        ) ::
          {:ok, pid()} | {:error, Error.t()}
  def start(runtime, %Workflow{} = workflow, inputs, opts \\ [])
      when is_atom(runtime) and is_map(inputs) and is_list(opts) do
    case ensure_job(opts) do
      {:ok, ensured} ->
        %Job{id: run_id} = Keyword.fetch!(ensured, :job)
        fingerprint = input_fingerprint(workflow, inputs)
        arg = {:start, runtime, workflow, inputs, ensured}
        start_or_find(runtime, workflow, fingerprint, run_id, arg)

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  @doc """
  Gives the server of a stored run, or starts it again.

  This function gives `{:ok, pid}` when the server still runs. Else it folds
  the journal with `Run.replay/4` and starts a fresh server with the replayed
  run. `opts` holds `:runners` and `:max_generations`. The caller resupplies
  them. `Run` does not persist overrides.

  A live server ignores `opts`. The server logs a warning when the caller
  passes `:runners` or `:max_generations` for a live run. A cold resume
  passes them to `Run.replay/4`.

  This function needs a durable adapter pair. A non-durable resume after
  owner death gives `run_not_durable`. A journal with no event gives
  `run_not_found`. A replay that opens no store gives its own error. Else
  the server drives while the run stays `:ready`.

  The telemetry span covers replay, event read and start as one cold resume.
  The `whereis/3` check and the live `state/1` read stay outside the span.
  A live resume logs when it drops opts and gives the pid with no span.

  ## Examples

  This function starts a process, so this example is illustrative:

      DomovoyCore.Workflow.Server.resume(MyDomovoy, workflow, "dom-43", runners: %{})
      {:ok, pid}
  """
  @spec resume(
          runtime :: Runtime.ref(),
          workflow :: Workflow.t(),
          run_id :: String.t(),
          opts :: keyword()
        ) ::
          {:ok, pid()} | {:error, Error.t()}
  def resume(runtime, %Workflow{} = workflow, run_id, opts \\ [])
      when is_atom(runtime) and is_binary(run_id) and is_list(opts) do
    case whereis(runtime, workflow.name, run_id) do
      pid when is_pid(pid) -> resume_found(runtime, workflow, run_id, opts, pid)
      nil -> resume_when_dead(runtime, workflow, run_id, opts)
    end
  end

  @doc """
  Gives the view of the run that the server holds.

  This function gives `{:error, :starting}` during initialization. The later
  view holds `workflow`, `run_id`, `status`, `cursor`, `generation` and
  `error`. It holds no store and no journal.

  This call stays responsive while a stage runs. The work runs in a task.

  ## Examples

  This function reads a process, so this example is illustrative:

      DomovoyCore.Workflow.Server.state(pid).status
      :awaiting_decision
  """
  @spec state(server :: GenServer.server()) :: view() | {:error, :starting}
  def state(server), do: GenServer.call(server, :state)

  @doc """
  Returns `true` when initialization, queueing, or one step is active.

  A caller that gets `run_busy` from `decide/3` reads `state/1` or waits for a
  `{:domovoy_event, event}` on the scoped topic. It answers after the run waits
  for a decision.

  ## Examples

  This function reads a process, so this example is illustrative:

      DomovoyCore.Workflow.Server.busy?(pid)
      true
  """
  @spec busy?(server :: GenServer.server()) :: boolean()
  def busy?(server), do: GenServer.call(server, :busy?)

  @doc false
  @spec config(server :: GenServer.server()) :: %{max_generations: pos_integer() | nil}
  def config(server), do: GenServer.call(server, :config)

  @doc """
  Takes the answer `choice_name` with `inputs`.

  This function gives `{:error, run_busy}` while the task runs or while the
  run still starts. The error holds `status` and `cursor`, so the caller can
  back off without a second call. Else it applies `Run.decide/4` in the
  server process. The store and journal writes block the server, so `state/1`
  waits too. Each write is one record plus one event, so the block stays
  short. It keeps the soft-error path of `Run`. The status stays put on a
  soft error.

  On success this function gives `{:ok, view}` with the post-decide cursor.
  The cursor is `:ready` before background stages end. The caller observes
  completion through `state/1` or PubSub.

  ## Examples

  This function writes to disk, so this example is illustrative:

      DomovoyCore.Workflow.Server.decide(pid, "approve", %{})
      {:ok, %{status: :ready}}
  """
  @spec decide(
          server :: GenServer.server(),
          choice_name :: String.t(),
          inputs :: Run.inputs()
        ) :: {:ok, view()} | {:error, Error.t()}
  def decide(server, choice_name, inputs \\ %{})
      when is_binary(choice_name) and is_map(inputs) do
    GenServer.call(server, {:decide, choice_name, inputs})
  end

  @doc """
  Stops the server and cancels its task.

  This function cancels the task and stops the server in one `GenServer`
  call, so no new task can spawn between the cancel and the stop. The
  supervisor drops the child. Disk state stays for `resume/4`.

  This function is idempotent. It gives `:ok` when the server is already
  dead.

  ## Examples

  This function stops a process, so this example is illustrative:

      DomovoyCore.Workflow.Server.stop(pid)
      :ok
  """
  @spec stop(server :: GenServer.server()) :: :ok
  def stop(server) do
    try do
      GenServer.call(server, :stop_graceful)
    catch
      :exit, {:noproc, _call} -> :ok
      :exit, {:normal, _call} -> :ok
      :exit, reason -> exit(reason)
    end

    :ok
  end

  @doc """
  Subscribes the caller to the events of `workflow_name` and `run_id`.

  The caller then matches `{:domovoy_event, %DomovoyCore.Event{}}`. It extracts
  the raw value with `Record` plus `Value` pattern matching. The topic is
  `DomovoyCore.Journal.topic/2`, so one run id under two workflow names gives
  no cross-talk.

  ## Examples

  This function reads PubSub, so this example is illustrative:

      DomovoyCore.Workflow.Server.subscribe(MyDomovoy, "issue_to_pr", "dom-43")
      :ok
  """
  @spec subscribe(Runtime.ref(), workflow_name :: String.t(), run_id :: String.t()) :: :ok
  def subscribe(runtime, workflow_name, run_id)
      when is_atom(runtime) and is_binary(workflow_name) and is_binary(run_id) do
    :ok = Phoenix.PubSub.subscribe(Runtime.pubsub(runtime), Journal.topic(workflow_name, run_id))
    :ok
  end

  @doc """
  Gives the pid of the server of `workflow_name` and `run_id`, or `nil`.

  ## Examples

  This function reads the registry, so this example is illustrative:

      DomovoyCore.Workflow.Server.whereis(MyDomovoy, "issue_to_pr", "dom-43")
      pid
  """
  @spec whereis(Runtime.ref(), workflow_name :: String.t(), run_id :: String.t()) :: pid() | nil
  def whereis(runtime, workflow_name, run_id)
      when is_atom(runtime) and is_binary(workflow_name) and is_binary(run_id) do
    case Registry.lookup(Runtime.workflow_registry(runtime), {workflow_name, run_id}) do
      [{pid, _value} | _rest] -> pid
      [] -> nil
    end
  end

  @spec child_spec(arg :: init_arg()) :: Supervisor.child_spec()
  def child_spec({:start, runtime, %Workflow{} = workflow, inputs, opts}) do
    %Job{id: run_id} = Keyword.fetch!(opts, :job)

    %{
      id: {__MODULE__, workflow.name, run_id},
      start: {__MODULE__, :start_link, [runtime, workflow, inputs, opts]},
      # The server holds durable state on disk. A crash must not restart it
      # with an empty run. `resume/4` starts it again from the journal, so
      # `:temporary` is correct and `:transient` would hide a bug.
      restart: :temporary
    }
  end

  def child_spec({:resume, runtime, %Workflow{} = workflow, %Run{} = run}) do
    %{
      id: {__MODULE__, workflow.name, run.job.id},
      start:
        {GenServer, :start_link,
         [
           __MODULE__,
           {:resume, runtime, workflow, run},
           [name: via(runtime, workflow.name, run.job.id)]
         ]},
      # See the `:start` clause for why `:temporary` is correct.
      restart: :temporary
    }
  end

  @impl true
  @spec init(arg :: init_arg()) :: {:ok, state()} | {:ok, state(), {:continue, atom()}}
  def init({:start, runtime, %Workflow{} = workflow, inputs, opts}) do
    %Job{} = Keyword.fetch!(opts, :job)
    Process.flag(:trap_exit, true)

    state = %{
      runtime: runtime,
      workflow: workflow,
      run: nil,
      task: nil,
      step_id: 0,
      input_fingerprint: input_fingerprint(workflow, inputs),
      pending_init: {inputs, opts},
      drive_queued?: false,
      retry_timer: nil
    }

    {:ok, state, {:continue, :init}}
  end

  def init({:resume, runtime, %Workflow{} = workflow, %Run{} = run}) do
    Process.flag(:trap_exit, true)

    state = %{
      runtime: runtime,
      workflow: workflow,
      run: run,
      task: nil,
      step_id: 0,
      input_fingerprint: Map.get(run.metadata, "input_fingerprint"),
      pending_init: nil,
      drive_queued?: false,
      retry_timer: nil
    }

    case run.status do
      :ready -> {:ok, state, {:continue, :drive}}
      _other -> {:ok, state}
    end
  end

  @impl true
  @spec handle_continue(action :: atom(), state :: state()) :: {:noreply, state()}
  def handle_continue(:init, %{pending_init: {inputs, opts}, workflow: workflow} = state) do
    case spawn_init(state.runtime, workflow, inputs, opts, state.step_id) do
      {:ok, task} -> {:noreply, drive_started(state, task)}
      {:error, :max_children} -> {:noreply, queue_drive(state)}
      {:error, reason} -> {:noreply, fail_crashed_step(state, reason)}
    end
  end

  def handle_continue(:drive, %{} = state) do
    {:noreply, drive_maybe(state)}
  end

  @impl true
  @spec handle_call(request :: term(), from :: GenServer.from(), state :: state()) ::
          {:reply, term(), state()} | {:stop, term(), term(), state()}
  def handle_call(:state, _from, %{run: nil} = state) do
    {:reply, {:error, :starting}, state}
  end

  def handle_call(:state, _from, %{run: %Run{} = run} = state) do
    {:reply, view(run), state}
  end

  def handle_call(:busy?, _from, %{run: %Run{}, task: nil, drive_queued?: false} = state) do
    {:reply, false, state}
  end

  def handle_call(:busy?, _from, %{} = state) do
    {:reply, true, state}
  end

  def handle_call(:config, _from, %{run: %Run{} = run} = state) do
    {:reply, %{max_generations: run.max_generations}, state}
  end

  def handle_call(:config, _from, %{workflow: _workflow} = state) do
    {:reply, %{max_generations: nil}, state}
  end

  def handle_call({:check_start, workflow_name, fingerprint}, _from, %{} = state) do
    reply =
      if workflow_name == state.workflow.name and fingerprint == state.input_fingerprint do
        :ok
      else
        {:error, Error.run_input_mismatch(state.workflow.name, run_id(state))}
      end

    {:reply, reply, state}
  end

  def handle_call(:stop_graceful, _from, %{} = state) do
    state = cancel_task(state)
    {:stop, :normal, :ok, state}
  end

  def handle_call({:decide, _choice, _inputs}, _from, %{task: %{ref: _ref}} = state) do
    {:reply, {:error, busy_error(state)}, state}
  end

  def handle_call({:decide, _choice, _inputs}, _from, %{drive_queued?: true} = state) do
    {:reply, {:error, busy_error(state)}, state}
  end

  def handle_call({:decide, _choice, _inputs}, _from, %{run: nil} = state) do
    error = Error.run_busy(state.workflow.name, run_id(state), :starting, state.workflow.start)
    {:reply, {:error, error}, state}
  end

  def handle_call(
        {:decide, choice, inputs},
        _from,
        %{workflow: workflow, run: %Run{} = run, task: nil} = state
      ) do
    start_meta = %{
      workflow: workflow.name,
      run_id: run.job.id,
      generation: run.job.generation,
      cursor: run.cursor
    }

    {reply, next_run} =
      :telemetry.span([:domovoy_core, :workflow, :decide], start_meta, fn ->
        next = Run.decide(workflow, run, choice, inputs)

        stop_meta =
          Telemetry.stop_meta(
            workflow.name,
            run.job.id,
            next.status,
            next.job.generation,
            next.cursor
          )

        reply =
          case next.error do
            nil -> {:ok, view(next)}
            %Error{} = error -> {:error, error}
          end

        {{reply, next}, stop_meta}
      end)

    state = %{state | run: next_run}

    case reply do
      {:ok, _view} -> {:reply, reply, drive_maybe(state)}
      {:error, _error} -> {:reply, reply, state}
    end
  end

  @impl true
  @spec handle_info(message :: term(), state :: state()) :: {:noreply, state()}
  def handle_info(
        {:domovoy_workflow_step, msg_step_id, %Run{} = next_run},
        %{task: %{ref: ref, step_id: step_id}} = state
      )
      when msg_step_id == step_id do
    Process.demonitor(ref, [:flush])
    state = %{state | run: next_run, task: nil, step_id: state.step_id + 1}
    {:noreply, drive_maybe(state)}
  end

  def handle_info(
        {:domovoy_workflow_init, msg_step_id, %Run{} = run},
        %{task: %{ref: ref, step_id: step_id}} = state
      )
      when msg_step_id == step_id do
    Process.demonitor(ref, [:flush])

    state = %{
      state
      | run: run,
        task: nil,
        step_id: state.step_id + 1,
        pending_init: nil,
        input_fingerprint: Map.get(run.metadata, "input_fingerprint", state.input_fingerprint)
    }

    {:noreply, drive_maybe(state)}
  end

  def handle_info({:domovoy_workflow_init, _msg_step_id, %Run{}}, %{} = state) do
    {:noreply, state}
  end

  def handle_info({:domovoy_workflow_step, _msg_step_id, %Run{}}, %{} = state) do
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %{ref: ref}} = state) do
    case reason do
      :normal ->
        {:noreply, %{state | task: nil, step_id: state.step_id + 1}}

      _abnormal ->
        {:noreply, fail_crashed_step(state, reason)}
    end
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, %{} = state) do
    {:noreply, state}
  end

  def handle_info({:retry_drive, token}, %{retry_timer: {timer, token}} = state) do
    _ = Process.cancel_timer(timer)
    {:noreply, state |> Map.put(:retry_timer, nil) |> drive_maybe()}
  end

  def handle_info({:retry_drive, _token}, %{} = state) do
    {:noreply, state}
  end

  def handle_info({:EXIT, _pid, _reason}, %{} = state) do
    {:noreply, state}
  end

  def handle_info(_message, %{} = state) do
    {:noreply, state}
  end

  @spec view(run :: Run.t()) :: view()
  defp view(%Run{} = run) do
    %{
      workflow: run.workflow,
      run_id: run.job.id,
      status: run.status,
      cursor: run.cursor,
      generation: run.job.generation,
      error: run.error
    }
  end

  @spec run_id(state :: state()) :: String.t()
  defp run_id(%{run: %Run{job: %Job{id: id}}}), do: id

  defp run_id(%{pending_init: {_inputs, opts}}) when is_list(opts) do
    %Job{id: id} = Keyword.fetch!(opts, :job)
    id
  end

  @spec busy_error(state :: state()) :: Error.t()
  defp busy_error(%{workflow: workflow, run: nil} = state) do
    Error.run_busy(workflow.name, run_id(state), :starting, workflow.start)
  end

  defp busy_error(%{workflow: workflow, run: %Run{} = run}) do
    Error.run_busy(workflow.name, run.job.id, run.status, run.cursor)
  end

  @spec drive_maybe(state :: state()) :: state()
  defp drive_maybe(%{task: nil, run: nil, pending_init: {inputs, opts}} = state) do
    case spawn_init(state.runtime, state.workflow, inputs, opts, state.step_id) do
      {:ok, task} -> drive_started(state, task)
      {:error, :max_children} -> queue_drive(state)
      {:error, reason} -> fail_crashed_step(state, reason)
    end
  end

  defp drive_maybe(%{task: nil, run: %Run{status: :ready}} = state) do
    case spawn_step(state.runtime, state.workflow, state.run, state.step_id) do
      {:ok, task} -> drive_started(state, task)
      {:error, :max_children} -> queue_drive(state)
      {:error, reason} -> fail_crashed_step(state, reason)
    end
  end

  defp drive_maybe(%{} = state), do: state

  @spec spawn_init(
          runtime :: Runtime.ref(),
          workflow :: Workflow.t(),
          inputs :: Run.inputs(),
          opts :: keyword(),
          step_id :: non_neg_integer()
        ) :: {:ok, task_info()} | {:error, term()}
  defp spawn_init(runtime, %Workflow{} = workflow, inputs, opts, step_id) do
    %Job{id: run_id} = Keyword.fetch!(opts, :job)
    owner = self()
    start_meta = Telemetry.start_meta(workflow.name, run_id, workflow.start)

    case Task.Supervisor.start_child(Runtime.workflow_task_supervisor(runtime), fn ->
           run_init_task(owner, step_id, runtime, workflow, inputs, opts, start_meta)
         end) do
      {:ok, pid} ->
        {:ok,
         %{
           ref: Process.monitor(pid),
           pid: pid,
           step_id: step_id,
           started_at: System.monotonic_time()
         }}

      {:error, :max_children} ->
        {:error, :max_children}

      {:error, {:max_children, _limit}} ->
        {:error, :max_children}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec spawn_step(
          Runtime.ref(),
          workflow :: Workflow.t(),
          run :: Run.t(),
          step_id :: non_neg_integer()
        ) ::
          {:ok, task_info()} | {:error, term()}
  defp spawn_step(runtime, %Workflow{} = workflow, %Run{} = run, step_id) do
    kind = vertex_kind(workflow, run.cursor)
    owner = self()

    start_meta =
      Telemetry.drive_start_meta(workflow.name, run.job.id, run.job.generation, run.cursor, kind)

    case Task.Supervisor.start_child(Runtime.workflow_task_supervisor(runtime), fn ->
           run_step_task(owner, step_id, workflow, run, kind, start_meta)
         end) do
      {:ok, pid} ->
        {:ok,
         %{
           ref: Process.monitor(pid),
           pid: pid,
           step_id: step_id,
           started_at: System.monotonic_time()
         }}

      {:error, :max_children} ->
        {:error, :max_children}

      {:error, {:max_children, _limit}} ->
        {:error, :max_children}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec run_init_task(
          owner :: pid(),
          step_id :: non_neg_integer(),
          runtime :: Runtime.ref(),
          workflow :: Workflow.t(),
          inputs :: Run.inputs(),
          opts :: keyword(),
          start_meta :: Telemetry.meta()
        ) :: :ok
  defp run_init_task(owner, step_id, runtime, workflow, inputs, opts, start_meta) do
    Process.link(owner)
    Process.put(:domovoy_workflow_step, {owner, step_id})

    :telemetry.span([:domovoy_core, :workflow, :start], start_meta, fn ->
      started = Run.start(runtime, workflow, inputs, opts)

      stop_meta =
        Telemetry.stop_meta(
          workflow.name,
          started.job.id,
          started.status,
          started.job.generation,
          started.cursor
        )

      send(owner, {:domovoy_workflow_init, step_id, started})
      {:ok, stop_meta}
    end)
  end

  @spec run_step_task(
          owner :: pid(),
          step_id :: non_neg_integer(),
          workflow :: Workflow.t(),
          run :: Run.t(),
          kind :: atom(),
          start_meta :: Telemetry.meta()
        ) :: :ok
  defp run_step_task(owner, step_id, workflow, run, kind, start_meta) do
    Process.link(owner)
    Process.put(:domovoy_workflow_step, {owner, step_id})

    :telemetry.span([:domovoy_core, :workflow, :drive], start_meta, fn ->
      next = Run.step(workflow, run)

      stop_meta =
        Telemetry.drive_stop_meta(
          workflow.name,
          run.job.id,
          next.status,
          next.job.generation,
          run.cursor,
          kind
        )

      send(owner, {:domovoy_workflow_step, step_id, next})
      {:ok, stop_meta}
    end)
  end

  @spec drive_started(state :: state(), task :: task_info()) :: state()
  defp drive_started(%{drive_queued?: true} = state, task) do
    emit_queue_event(:dequeued, state)
    %{state | task: task, drive_queued?: false, retry_timer: nil}
  end

  defp drive_started(%{} = state, task) do
    %{state | task: task, drive_queued?: false, retry_timer: nil}
  end

  @spec queue_drive(state :: state()) :: state()
  defp queue_drive(%{drive_queued?: true, retry_timer: {_timer, _token}} = state), do: state

  defp queue_drive(%{} = state) do
    token = make_ref()
    timer = Process.send_after(self(), {:retry_drive, token}, @drive_retry_ms)
    emit_queue_event(:queued, state)
    %{state | drive_queued?: true, retry_timer: {timer, token}}
  end

  @spec emit_queue_event(event :: :queued | :dequeued, state :: state()) :: :ok
  defp emit_queue_event(event, %{workflow: workflow, run: %Run{} = run}) do
    :telemetry.execute(
      [:domovoy_core, :workflow, :drive, event],
      %{},
      Telemetry.drive_start_meta(
        workflow.name,
        run.job.id,
        run.job.generation,
        run.cursor,
        vertex_kind(workflow, run.cursor)
      )
    )
  end

  defp emit_queue_event(event, %{workflow: workflow, pending_init: {_inputs, opts}}) do
    %Job{} = job = Keyword.fetch!(opts, :job)

    :telemetry.execute(
      [:domovoy_core, :workflow, :drive, event],
      %{},
      Telemetry.drive_start_meta(
        workflow.name,
        job.id,
        job.generation,
        workflow.start,
        vertex_kind(workflow, workflow.start)
      )
    )
  end

  @spec fail_crashed_step(state :: state(), reason :: term()) :: state()
  defp fail_crashed_step(%{workflow: workflow, run: %Run{} = run} = state, reason) do
    cause = normalize_cause(reason)
    {failed, append_result} = Run.crash(run, cause)
    error = failed.error

    Logger.error("Workflow step task crashed: #{Error.message(error)} reason=#{inspect(reason)}")

    case append_result do
      {:error, %Error{} = journal_error} ->
        Logger.warning("Failed to journal step crash: #{Error.message(journal_error)}")

      :ok ->
        :ok
    end

    :telemetry.execute(
      [:domovoy_core, :workflow, :drive, :exception],
      %{duration: drive_duration(state)},
      Telemetry.drive_stop_meta(
        workflow.name,
        run.job.id,
        :failed,
        run.job.generation,
        run.cursor,
        vertex_kind(workflow, run.cursor)
      )
      |> Map.put(:error, Error.message(error))
    )

    %{state | run: failed, task: nil, step_id: state.step_id + 1}
  end

  defp fail_crashed_step(%{} = state, _reason) do
    %{pending_init: {_inputs, opts}, workflow: workflow} = state
    %Job{} = job = Keyword.fetch!(opts, :job)
    error = Error.run_step_crashed(workflow.name, job.id, :initialization_failed)

    run = %Run{
      job: job,
      workflow: workflow.name,
      cursor: workflow.start,
      status: :failed,
      error: error
    }

    %{state | run: run, task: nil, pending_init: nil, step_id: state.step_id + 1}
  end

  @spec drive_duration(state :: state()) :: non_neg_integer()
  defp drive_duration(%{task: %{started_at: started_at}}) do
    System.monotonic_time() - started_at
  end

  defp drive_duration(_state), do: 0

  @spec cancel_task(state :: state()) :: state()
  defp cancel_task(%{task: nil} = state) do
    state
    |> cancel_retry_timer()
    |> Map.put(:drive_queued?, false)
    |> Map.put(:step_id, state.step_id + 1)
  end

  defp cancel_task(%{task: %{pid: pid, ref: ref}} = state) do
    state = cancel_retry_timer(state)
    send(pid, {:domovoy_cancel_workflow_step, self(), state.step_id})

    unless await_task_down(ref, pid, 5_000) do
      try do
        Task.Supervisor.terminate_child(Runtime.workflow_task_supervisor(state.runtime), pid)
      catch
        _, _reason -> :ok
      end

      _stopped? = await_task_down(ref, pid, 5_000)
    end

    Process.demonitor(ref, [:flush])
    %{state | task: nil, step_id: state.step_id + 1, drive_queued?: false}
  end

  @spec await_task_down(ref :: reference(), pid :: pid(), timeout :: non_neg_integer()) ::
          boolean()
  defp await_task_down(ref, pid, timeout) do
    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> true
    after
      timeout -> false
    end
  end

  @spec cancel_retry_timer(state :: state()) :: state()
  defp cancel_retry_timer(%{retry_timer: nil} = state), do: state

  defp cancel_retry_timer(%{retry_timer: {timer, token}} = state) do
    _ = Process.cancel_timer(timer)

    receive do
      {:retry_drive, ^token} -> :ok
    after
      0 -> :ok
    end

    %{state | retry_timer: nil}
  end

  @spec start_or_find(
          runtime :: Runtime.ref(),
          workflow :: Workflow.t(),
          fingerprint :: String.t(),
          run_id :: String.t(),
          arg :: init_arg()
        ) :: {:ok, pid()} | {:error, Error.t()}
  defp start_or_find(runtime, %Workflow{} = workflow, fingerprint, run_id, arg) do
    case DynamicSupervisor.start_child(Runtime.workflow_supervisor(runtime), {__MODULE__, arg}) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        check_live_start(runtime, workflow, fingerprint, run_id, pid, arg)

      {:error, reason} ->
        {:error, Error.server_start_failed(workflow.name, run_id, normalize_cause(reason))}
    end
  end

  @spec check_live_start(
          runtime :: Runtime.ref(),
          workflow :: Workflow.t(),
          fingerprint :: String.t(),
          run_id :: String.t(),
          pid :: pid(),
          arg :: init_arg()
        ) :: {:ok, pid()} | {:error, Error.t()}
  defp check_live_start(runtime, %Workflow{} = workflow, fingerprint, run_id, pid, arg) do
    case GenServer.call(pid, {:check_start, workflow.name, fingerprint}) do
      :ok -> {:ok, pid}
      {:error, %Error{} = error} -> {:error, error}
    end
  catch
    :exit, _reason ->
      case DynamicSupervisor.start_child(Runtime.workflow_supervisor(runtime), {__MODULE__, arg}) do
        {:ok, new_pid} ->
          {:ok, new_pid}

        {:error, {:already_started, live_pid}} ->
          {:ok, live_pid}

        {:error, reason} ->
          {:error, Error.server_start_failed(workflow.name, run_id, normalize_cause(reason))}
      end
  end

  @spec resume_found(
          runtime :: Runtime.ref(),
          workflow :: Workflow.t(),
          run_id :: String.t(),
          opts :: keyword(),
          pid :: pid()
        ) :: {:ok, pid()} | {:error, Error.t()}
  defp resume_found(runtime, %Workflow{} = workflow, run_id, opts, pid) do
    case live_view(pid) do
      {:ok, _live} ->
        warn_live_opts(opts, workflow.name, run_id)
        {:ok, pid}

      :dead ->
        resume_when_dead(runtime, workflow, run_id, opts)
    end
  end

  @spec resume_when_dead(
          Runtime.ref(),
          workflow :: Workflow.t(),
          run_id :: String.t(),
          opts :: keyword()
        ) ::
          {:ok, pid()} | {:error, Error.t()}
  defp resume_when_dead(runtime, %Workflow{} = workflow, run_id, opts) do
    case durable?(workflow) do
      false ->
        {:error, Error.run_not_durable(workflow.name, run_id)}

      true ->
        start_meta = Telemetry.resume_start_meta(workflow.name, run_id)

        :telemetry.span([:domovoy_core, :workflow, :resume], start_meta, fn ->
          resume_span(runtime, workflow, run_id, opts)
        end)
    end
  end

  @spec resume_span(Runtime.ref(), Workflow.t(), String.t(), keyword()) ::
          {{:ok, pid()} | {:error, Error.t()}, Telemetry.meta()}
  defp resume_span(runtime, %Workflow{} = workflow, run_id, opts) do
    case replay_and_start(runtime, workflow, run_id, opts) do
      {:ok, pid, %Run{} = replayed} ->
        stop_meta =
          Telemetry.stop_meta(
            workflow.name,
            run_id,
            replayed.status,
            replayed.job.generation,
            replayed.cursor
          )

        {{:ok, pid}, stop_meta}

      {:error, %Error{} = error} ->
        {{:error, error}, Telemetry.stop_meta(workflow.name, run_id, :error, nil, nil)}
    end
  end

  @spec replay_and_start(Runtime.ref(), Workflow.t(), String.t(), keyword()) ::
          {:ok, pid(), Run.t()} | {:error, Error.t()}
  defp replay_and_start(runtime, %Workflow{} = workflow, run_id, opts) do
    replay_opts = Keyword.take(opts, [:runners, :max_generations])
    replayed = Run.replay(runtime, workflow, run_id, replay_opts)

    if replayed.store == nil or replayed.journal == nil do
      {:error, replayed.error || Error.run_not_found(workflow.name, run_id)}
    else
      resume_with_events(runtime, workflow, run_id, replayed)
    end
  end

  @spec resume_with_events(Runtime.ref(), Workflow.t(), String.t(), Run.t()) ::
          {:ok, pid(), Run.t()} | {:error, Error.t()}
  defp resume_with_events(runtime, %Workflow{} = workflow, run_id, %Run{} = replayed) do
    case Journal.events(replayed.journal) do
      {:error, %Error{} = error} ->
        {:error, error}

      {:ok, []} ->
        {:error, Error.run_not_found(workflow.name, run_id)}

      {:ok, _events} ->
        start_resumed(runtime, workflow, replayed)
    end
  end

  @spec start_resumed(Runtime.ref(), Workflow.t(), Run.t()) ::
          {:ok, pid(), Run.t()} | {:error, Error.t()}
  defp start_resumed(runtime, %Workflow{} = workflow, %Run{} = replayed) do
    arg = {:resume, runtime, workflow, replayed}

    case DynamicSupervisor.start_child(Runtime.workflow_supervisor(runtime), {__MODULE__, arg}) do
      {:ok, pid} ->
        {:ok, pid, replayed}

      {:error, {:already_started, pid}} ->
        {:ok, pid, replayed}

      {:error, reason} ->
        {:error,
         Error.server_start_failed(workflow.name, replayed.job.id, normalize_cause(reason))}
    end
  end

  @spec durable?(workflow :: Workflow.t()) :: boolean()
  defp durable?(%Workflow{store: {store_mod, _store_opts}, journal: {journal_mod, _journal_opts}}) do
    Store.durable?(store_mod) and Journal.durable?(journal_mod)
  end

  @spec live_view(pid :: pid()) :: {:ok, view() | :starting} | :dead
  defp live_view(pid) do
    case GenServer.call(pid, :state) do
      {:error, :starting} -> {:ok, :starting}
      view -> {:ok, view}
    end
  catch
    :exit, _reason -> :dead
  end

  @spec warn_live_opts(opts :: keyword(), workflow_name :: String.t(), run_id :: String.t()) ::
          :ok
  defp warn_live_opts(opts, workflow_name, run_id) do
    case Keyword.take(opts, [:runners, :max_generations]) do
      [] ->
        :ok

      taken ->
        Logger.warning(
          "Resume of live run #{workflow_name}/#{run_id} ignores opts #{inspect(Keyword.keys(taken))}"
        )

        :ok
    end
  end

  @spec vertex_kind(workflow :: Workflow.t(), cursor :: String.t() | nil) ::
          :stage | :decision | :unknown
  defp vertex_kind(%Workflow{} = workflow, cursor) when is_binary(cursor) do
    case Workflow.vertex(workflow, cursor) do
      nil -> :unknown
      vertex -> Vertex.kind(vertex)
    end
  end

  defp vertex_kind(%Workflow{}, _cursor), do: :unknown

  @spec via(Runtime.ref(), workflow_name :: String.t(), run_id :: String.t()) ::
          {:via, Registry, term()}
  defp via(runtime, workflow_name, run_id)
       when is_atom(runtime) and is_binary(workflow_name) and is_binary(run_id) do
    {:via, Registry, {Runtime.workflow_registry(runtime), {workflow_name, run_id}}}
  end

  @spec ensure_job(opts :: keyword()) :: {:ok, keyword()} | {:error, Error.t()}
  defp ensure_job(opts) when is_list(opts) do
    case Keyword.get(opts, :job) do
      %Job{} -> {:ok, opts}
      nil -> {:ok, Keyword.put(opts, :job, Job.new(Name.random()))}
      other -> {:error, Error.invalid_server_job(other)}
    end
  end

  @spec input_fingerprint(workflow :: Workflow.t(), inputs :: Run.inputs()) :: String.t()
  defp input_fingerprint(%Workflow{} = workflow, inputs) do
    case Run.input_fingerprint(workflow, inputs) do
      {:ok, fingerprint} ->
        fingerprint

      {:error, %Error{}} ->
        encoded = :erlang.term_to_binary(inputs, [:deterministic, {:minor_version, 1}])

        :crypto.hash(:sha256, encoded)
        |> Base.encode16(case: :lower)
    end
  end

  @impl true
  @spec terminate(reason :: term(), state :: state()) :: :ok
  def terminate(_reason, %{} = state) do
    _state = cancel_task(state)
    :ok
  end

  @spec normalize_cause(reason :: term()) :: atom() | String.t()
  defp normalize_cause(reason) when is_atom(reason), do: reason

  defp normalize_cause(reason) do
    reason
    |> inspect(limit: 20, printable_limit: 1_000)
    |> String.slice(0, 2_000)
  end
end
