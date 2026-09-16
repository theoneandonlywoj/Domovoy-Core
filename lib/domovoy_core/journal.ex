defmodule DomovoyCore.Journal do
  @moduledoc """
  The events of one run, in order, behind an adapter.

  A journal is opened per run, like a `DomovoyCore.Store`. `open/4` takes a
  runtime reference, adapter module, run id and adapter options, with
  `workflow:` among them, and gives a `%DomovoyCore.Journal{}`. `open/4`
  requires `workflow:`. It gives a `journal_error` when `workflow:` is
  missing. `append/2` adds one `DomovoyCore.Event` at the end and then sends
  `{:domovoy_event, event}` to every subscriber on the runtime's PubSub.
  `events/1` gives every event in the order of the appends.

  The journal is append-only. Nothing in it changes or goes away. The state
  of a run is what its events say, so a later step folds them to rebuild a
  run.

  `DomovoyCore.Journal.FileSystem` appends one JSON line per event to
  `<root>/<workflow>/<run_id>/events.jsonl`.

  The store, the journal files and the registry all key on
  `{workflow, run_id}`. The PubSub topic matches them. `topic/2` gives the
  scoped topic `"run:<workflow>:<run_id>"`, so one run id under two workflow
  names gives two topics with no cross-talk.

  `append/2` commits the adapter write first, then broadcasts on the scoped
  topic. The broadcast is best effort. A failure logs a warning and keeps `:ok`.

  Every failure is a `DomovoyCore.Error` with `type: :journal_error`.

  """

  alias DomovoyCore.Error
  alias DomovoyCore.Event
  alias DomovoyCore.Journal
  alias DomovoyCore.Runtime

  require Logger

  @typedoc "What an adapter keeps between calls."
  @type state() :: any()

  @type t() :: %Journal{
          adapter: module(),
          state: state(),
          run_id: String.t(),
          workflow: String.t() | nil,
          runtime: Runtime.ref(),
          metadata: %{String.t() => any()}
        }

  defstruct [:adapter, :state, :run_id, :workflow, :runtime, metadata: %{}]

  @doc "Opens the journal of `run_id`. `opts` holds `workflow:`."
  @callback open(run_id :: String.t(), opts :: keyword()) :: {:ok, state()} | {:error, Error.t()}

  @doc "Adds `event` at the end."
  @callback append(state :: state(), event :: Event.t()) :: :ok | {:error, Error.t()}

  @doc "Gives every event, in the order of the appends."
  @callback events(state :: state()) :: {:ok, [Event.t()]} | {:error, Error.t()}

  @doc """
  Returns `true` when the adapter keeps events after its owner dies.

  `DomovoyCore.Journal.FileSystem` returns `true`. Custom in-memory adapters
  should implement this callback and return `false`.
  """
  @callback durable?() :: boolean()

  @optional_callbacks durable?: 0

  @doc """
  Opens the journal of `run_id` with `adapter` in `runtime` and gives the struct.

  This function requires `workflow:` in `opts` and keeps it on the struct,
  so `append/2` can send on the scoped topic. A missing `workflow:` gives a
  `journal_error` and opens nothing.

  """
  @spec open(
          runtime :: Runtime.ref(),
          adapter :: module(),
          run_id :: String.t(),
          opts :: keyword()
        ) ::
          {:ok, t()} | {:error, Error.t()}
  def open(runtime, adapter, run_id, opts)
      when is_atom(runtime) and is_atom(adapter) and is_binary(run_id) and is_list(opts) do
    case Keyword.fetch(opts, :workflow) do
      {:ok, workflow} when is_binary(workflow) ->
        with {:ok, state} <- adapter.open(run_id, opts) do
          {:ok,
           %Journal{
             adapter: adapter,
             state: state,
             run_id: run_id,
             workflow: workflow,
             runtime: runtime
           }}
        end

      _other ->
        {:error, Error.journal_error(__MODULE__, :open, :workflow_missing)}
    end
  end

  @doc """
  Adds `event` at the end of `journal`, then sends it on the runtime's PubSub.

  The message is `{:domovoy_event, event}` on `topic/2` of the run. The
  broadcast is best effort. A failure logs a warning and keeps `:ok`.
  """
  @spec append(journal :: t(), event :: Event.t()) :: :ok | {:error, Error.t()}
  def append(
        %Journal{
          adapter: adapter,
          state: state,
          run_id: run_id,
          workflow: workflow,
          runtime: runtime
        },
        %Event{} = event
      ) do
    with :ok <- adapter.append(state, event) do
      topic = topic(workflow, run_id)

      topic
      |> broadcast(runtime, event)
      |> log_broadcast_failure(topic)

      :ok
    end
  end

  @doc """
  Gives every event of `journal`, in the order of the appends.
  """
  @spec events(journal :: t()) :: {:ok, [Event.t()]} | {:error, Error.t()}
  def events(%Journal{adapter: adapter, state: state}), do: adapter.events(state)

  @doc """
  Returns `true` when `adapter` keeps events after its owner dies.

  An adapter with `durable?/0` answers for itself. An adapter without it
  counts as durable.

  ## Examples

      iex> DomovoyCore.Journal.durable?(DomovoyCore.Journal.FileSystem)
      true
  """
  @spec durable?(adapter :: module()) :: boolean()
  def durable?(adapter) when is_atom(adapter) do
    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :durable?, 0) do
      adapter.durable?()
    else
      true
    end
  end

  @doc """
  Gives the scoped PubSub topic of `workflow` and `run_id`.

  The registry and the FileSystem paths already key on
  `{workflow, run_id}`. This topic matches them, so one run id under two
  workflow names gives two topics with no cross-talk.

  ## Examples

      iex> DomovoyCore.Journal.topic("issue_to_pr", "dom-30")
      "run:issue_to_pr:dom-30"
  """
  @spec topic(workflow :: String.t(), run_id :: String.t()) :: String.t()
  def topic(workflow, run_id) when is_binary(workflow) and is_binary(run_id) do
    "run:" <> workflow <> ":" <> run_id
  end

  @doc """
  Returns `true` when `module` is loaded and implements `DomovoyCore.Journal`.

  ## Examples

      iex> DomovoyCore.Journal.adapter?(DomovoyCore.Journal.FileSystem)
      true
      iex> DomovoyCore.Journal.adapter?(DomovoyCore.Store.FileSystem)
      false
  """
  @spec adapter?(module :: any()) :: boolean()
  def adapter?(module) when is_atom(module) and not is_nil(module) do
    Code.ensure_loaded?(module) and
      module.module_info(:attributes)
      |> Keyword.get_values(:behaviour)
      |> List.flatten()
      |> Enum.member?(Journal)
  end

  def adapter?(_module), do: false

  @spec broadcast(topic :: String.t(), Runtime.ref(), event :: Event.t()) ::
          :ok | {:error, term()}
  defp broadcast(topic, runtime, %Event{} = event) do
    Phoenix.PubSub.broadcast(Runtime.pubsub(runtime), topic, {:domovoy_event, event})
  end

  @spec log_broadcast_failure(result :: :ok | {:error, term()}, topic :: String.t()) :: :ok
  defp log_broadcast_failure(:ok, _topic), do: :ok

  defp log_broadcast_failure({:error, reason}, topic) do
    Logger.warning(
      "Failed to broadcast journal event on topic #{inspect(topic)}: #{inspect(reason)}"
    )
  end
end
