defmodule DomovoyCore.Store do
  @moduledoc """
  The records of one run, behind an adapter.

  A store is opened per run. `open/3` takes an adapter module, the run id
  and the options of the adapter, and gives a `%DomovoyCore.Store{}`. Every
  other function takes that struct. The options always hold `workflow:`, the
  name of the workflow, because two workflows with one run id never share a
  record.

  A record sits under its key, `{run_id, node, generation, attempt}`, which
  `DomovoyCore.Record.key/1` reads off the job of the record. A second `put/2`
  with the same key replaces the first. A read needs a record
  with `status: :ok`:

    * `get/3` gives the `:ok` record with the highest attempt at exactly that
      generation. `DomovoyCore.Engine` asks this before it runs a node, and a hit
      means the node does not run again.
    * `latest/3` gives the newest `:ok` record at that generation or an
      earlier one. A node reads the value of an earlier stage through this,
      so a re-run at generation 2 still sees what generation 0 wrote.
    * `all/1` gives every record of the run, sorted by key.
    * `runs/2` lists the `{workflow, run_id}` pairs that the adapter knows.

  `DomovoyCore.Store.FileSystem` writes one JSON file per record under
  `<root>/<workflow>/<run_id>/`.

  Every failure is a `DomovoyCore.Error` with `type: :store_error`, and its
  reason names the adapter, the operation and the cause. It never holds a
  record or a value.

  """

  alias DomovoyCore.Error
  alias DomovoyCore.Job
  alias DomovoyCore.Record
  alias DomovoyCore.Store

  @typedoc "What an adapter keeps between calls."
  @type state() :: any()

  @typedoc "The name of a node."
  @type node_name() :: String.t()

  @typedoc "One run that an adapter knows."
  @type run() :: %{workflow: String.t(), run_id: String.t()}

  @typedoc "The result of a read of one record."
  @type read() :: {:ok, Record.t()} | :miss | {:error, Error.t()}

  @type t() :: %Store{
          adapter: module(),
          state: state(),
          run_id: String.t(),
          metadata: %{String.t() => any()}
        }

  defstruct [:adapter, :state, :run_id, metadata: %{}]

  @doc "Opens the store of `run_id`. `opts` holds `workflow:`."
  @callback open(run_id :: String.t(), opts :: keyword()) :: {:ok, state()} | {:error, Error.t()}

  @doc "Puts `record` under its key. A record under the same key is replaced."
  @callback put(state :: state(), record :: Record.t()) :: :ok | {:error, Error.t()}

  @doc "Gives the `:ok` record with the highest attempt at `generation`."
  @callback get(state :: state(), node :: node_name(), generation :: non_neg_integer()) :: read()

  @doc "Gives the newest `:ok` record at `generation` or an earlier one."
  @callback latest(state :: state(), node :: node_name(), generation :: non_neg_integer()) ::
              read()

  @doc "Gives every record of the run, sorted by key."
  @callback all(state :: state()) :: {:ok, [Record.t()]} | {:error, Error.t()}

  @doc "Lists the runs that the adapter knows under `opts`."
  @callback runs(opts :: keyword()) :: {:ok, [run()]} | {:error, Error.t()}

  @doc """
  Returns `true` when the adapter keeps records after its owner dies.

  `DomovoyCore.Store.FileSystem` returns `true`. Custom in-memory adapters
  should implement this callback and return `false`.
  """
  @callback durable?() :: boolean()

  @optional_callbacks durable?: 0

  @doc """
  Opens the store of `run_id` with `adapter` and gives the struct.
  """
  @spec open(adapter :: module(), run_id :: String.t(), opts :: keyword()) ::
          {:ok, t()} | {:error, Error.t()}
  def open(adapter, run_id, opts) when is_atom(adapter) and is_binary(run_id) and is_list(opts) do
    with {:ok, state} <- adapter.open(run_id, opts) do
      {:ok, %Store{adapter: adapter, state: state, run_id: run_id}}
    end
  end

  @doc """
  Puts `record` in `store`.
  """
  @spec put(store :: t(), record :: Record.t()) :: :ok | {:error, Error.t()}
  def put(%Store{adapter: adapter, state: state}, %Record{} = record) do
    adapter.put(state, record)
  end

  @doc """
  Gives the `:ok` record of `node` with the highest attempt at `generation`.
  """
  @spec get(store :: t(), node :: node_name(), generation :: non_neg_integer()) :: read()
  def get(%Store{adapter: adapter, state: state}, node, generation)
      when is_binary(node) and is_integer(generation) do
    adapter.get(state, node, generation)
  end

  @doc """
  Gives the newest `:ok` record of `node` at `generation` or an earlier one.
  """
  @spec latest(store :: t(), node :: node_name(), generation :: non_neg_integer()) :: read()
  def latest(%Store{adapter: adapter, state: state}, node, generation)
      when is_binary(node) and is_integer(generation) do
    adapter.latest(state, node, generation)
  end

  @doc """
  Gives every record of the run in `store`, sorted by key.
  """
  @spec all(store :: t()) :: {:ok, [Record.t()]} | {:error, Error.t()}
  def all(%Store{adapter: adapter, state: state}), do: adapter.all(state)

  @doc """
  Lists the runs that `adapter` knows under `opts`.
  """
  @spec runs(adapter :: module(), opts :: keyword()) :: {:ok, [run()]} | {:error, Error.t()}
  def runs(adapter, opts) when is_atom(adapter) and is_list(opts), do: adapter.runs(opts)

  @doc """
  Returns `true` when `adapter` keeps records after its owner dies.

  An adapter with `durable?/0` answers for itself. An adapter without it
  counts as durable. A custom in-memory adapter therefore implements
  `durable?/0` and returns `false`.

  ## Examples

      iex> DomovoyCore.Store.durable?(DomovoyCore.Store.FileSystem)
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
  Returns `true` when `module` is loaded and implements `DomovoyCore.Store`.

  ## Examples

      iex> DomovoyCore.Store.adapter?(DomovoyCore.Store.FileSystem)
      true
      iex> DomovoyCore.Store.adapter?(DomovoyCore.Type.Map)
      false
  """
  @spec adapter?(module :: any()) :: boolean()
  def adapter?(module) when is_atom(module) and not is_nil(module) do
    Code.ensure_loaded?(module) and
      module.module_info(:attributes)
      |> Keyword.get_values(:behaviour)
      |> List.flatten()
      |> Enum.member?(Store)
  end

  def adapter?(_module), do: false

  @doc """
  Sorts `records` by key and keeps the ones that read as a hit.

  An adapter calls this from `get/3` and `latest/3`. `records` are the
  candidates of one node. `generation` is the exact generation for `get/3`,
  or the highest one for `latest/3` with `:latest`. The newest `:ok` record
  wins.

  ## Examples

      iex> job = DomovoyCore.Job.new("r")
      iex> count = DomovoyCore.Value.cast!(1, DomovoyCore.Type.Integer)
      iex> first = DomovoyCore.Record.new(%{job: job, node: "count", status: :ok, result: count})
      iex> rerun = DomovoyCore.Job.next_generation(job)
      iex> second = DomovoyCore.Record.new(%{job: rerun, node: "count", status: :ok, result: count})
      iex> DomovoyCore.Store.pick([second, first], 0, :exact)
      {:ok, first}
      iex> DomovoyCore.Store.pick([second, first], 1, :latest)
      {:ok, second}
      iex> DomovoyCore.Store.pick([second], 0, :latest)
      :miss
  """
  @spec pick(records :: [Record.t()], generation :: non_neg_integer(), mode :: :exact | :latest) ::
          {:ok, Record.t()} | :miss
  def pick(records, generation, mode) when is_list(records) and mode in [:exact, :latest] do
    records
    |> Enum.filter(&(Record.ok?(&1) and generation_matches?(&1, generation, mode)))
    |> Enum.max_by(&{&1.job.generation, &1.job.attempt}, fn -> nil end)
    |> case do
      nil -> :miss
      %Record{} = record -> {:ok, record}
    end
  end

  @spec generation_matches?(
          record :: Record.t(),
          generation :: non_neg_integer(),
          mode :: :exact | :latest
        ) :: boolean()
  defp generation_matches?(%Record{job: %Job{generation: at}}, generation, :exact),
    do: at == generation

  defp generation_matches?(%Record{job: %Job{generation: at}}, generation, :latest),
    do: at <= generation
end
