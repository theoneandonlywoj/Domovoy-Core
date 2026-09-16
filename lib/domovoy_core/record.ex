defmodule DomovoyCore.Record do
  @moduledoc """
  One attempt of one node in one run.

  A record has an identity and an outcome. The identity is the `job` of the
  run and the name of the `node`. The job holds the generation and the
  attempt, so `key/1` gives the identity as
  `{job.id, node, generation, attempt}`, and a `DomovoyCore.Store` keeps one
  record under each key. The outcome is `status` and `result`. An `:ok`
  result is a `DomovoyCore.Value`. An `:error` result is a `DomovoyCore.Error`. A
  record with `:cancelled` or `:skipped` has a nil result. `started_at` and
  `finished_at` are UTC times. They are nil for records that no runner made,
  such as inputs.

  See `DomovoyCore.Job` for the generation and the attempt.

  ## Examples

  `new/1` needs `job`, `node` and `status`:

      iex> job = DomovoyCore.Job.new("dom-30")
      iex> value = DomovoyCore.Value.cast!(42, DomovoyCore.Type.Integer)
      iex> record = DomovoyCore.Record.new(%{job: job, node: "sum", status: :ok, result: value})
      iex> DomovoyCore.Record.key(record)
      {"dom-30", "sum", 0, 1}
      iex> DomovoyCore.Record.ok?(record)
      true
      iex> %DomovoyCore.Record{result: %DomovoyCore.Value{value: count}} = record
      iex> count
      42

  A status other than the four raises. An `:ok` without a value result also
  raises:

      iex> job = DomovoyCore.Job.new("dom-30")
      iex> DomovoyCore.Record.new(%{job: job, node: "sum", status: :done})
      ** (ArgumentError) status of record "sum" must be one of [:ok, :error, :cancelled, :skipped], got: :done

      iex> job = DomovoyCore.Job.new("dom-30")
      iex> DomovoyCore.Record.new(%{job: job, node: "sum", status: :ok})
      ** (ArgumentError) record "sum" with status :ok needs a %DomovoyCore.Value{} result

  `dump/1` gives the document that a store keeps, and `load/1` reads it:

      iex> job = DomovoyCore.Job.new("dom-30") |> DomovoyCore.Job.at_generation(1)
      iex> value = DomovoyCore.Value.cast!(42, DomovoyCore.Type.Integer)
      iex> record = DomovoyCore.Record.new(%{
      ...>   job: job,
      ...>   node: "sum",
      ...>   status: :ok,
      ...>   result: value,
      ...>   started_at: ~U[2026-09-13 10:00:00Z],
      ...>   finished_at: ~U[2026-09-13 10:00:01Z]
      ...> })
      iex> {:ok, document} = DomovoyCore.Record.dump(record)
      iex> document
      %{
        "version" => 1,
        "job" => %{
          "version" => 1,
          "id" => "dom-30",
          "generation" => 1,
          "attempt" => 1,
          "metadata" => %{}
        },
        "node" => "sum",
        "status" => "ok",
        "result" => %{
          "version" => 1,
          "type" => "Elixir.DomovoyCore.Type.Integer",
          "value" => 42,
          "metadata" => %{}
        },
        "started_at" => "2026-09-13T10:00:00Z",
        "finished_at" => "2026-09-13T10:00:01Z",
        "metadata" => %{}
      }
      iex> DomovoyCore.Record.load(document)
      {:ok, record}

      iex> DomovoyCore.Record.load(%{"version" => 2})
      {:error, DomovoyCore.Error.unsupported_version(2)}
  """

  alias DomovoyCore.Error
  alias DomovoyCore.Job
  alias DomovoyCore.Record
  alias DomovoyCore.Value

  @version 1
  @statuses [:ok, :error, :cancelled, :skipped]

  @typedoc "The outcome of an attempt."
  @type status() :: :ok | :error | :cancelled | :skipped

  @typedoc "The result of an attempt."
  @type result() :: Value.t() | Error.t() | nil

  @typedoc "The identity of a record in a store."
  @type key() :: {String.t(), String.t(), non_neg_integer(), pos_integer()}

  @typedoc "The document that `dump/1` gives and `load/1` takes."
  @type document() :: %{required(String.t()) => any()}

  @type t() :: %Record{
          job: Job.t(),
          node: String.t(),
          status: status(),
          result: result(),
          started_at: DateTime.t() | nil,
          finished_at: DateTime.t() | nil,
          metadata: %{String.t() => any()}
        }

  @type new() :: %{
          required(:job) => Job.t(),
          required(:node) => String.t(),
          required(:status) => status(),
          optional(:result) => result(),
          optional(:started_at) => DateTime.t() | nil,
          optional(:finished_at) => DateTime.t() | nil,
          optional(:metadata) => %{String.t() => any()}
        }

  defstruct job: nil,
            node: nil,
            status: nil,
            result: nil,
            started_at: nil,
            finished_at: nil,
            metadata: %{}

  @doc """
  Makes a record, or raises an `ArgumentError`.

  See the moduledoc for the fields and the checks.
  """
  @spec new(args :: new()) :: t()
  def new(args) when is_map(args) do
    record = %Record{
      job: Map.fetch!(args, :job),
      node: Map.fetch!(args, :node),
      status: Map.fetch!(args, :status),
      result: Map.get(args, :result),
      started_at: Map.get(args, :started_at),
      finished_at: Map.get(args, :finished_at),
      metadata: Map.get(args, :metadata) || %{}
    }

    check!(record)
  end

  @doc """
  Gives the identity of `record`: `{job.id, node, generation, attempt}`.
  """
  @spec key(record :: t()) :: key()
  def key(%Record{job: %Job{} = job, node: node}) do
    {job.id, node, job.generation, job.attempt}
  end

  @doc """
  Returns `true` when the status of `record` is `:ok`.
  """
  @spec ok?(record :: t()) :: boolean()
  def ok?(%Record{status: status}), do: status == :ok

  @doc """
  Translates `record` to the document that a store keeps.

  The document holds `"version"`, the job as `DomovoyCore.Job.dump/1` gives it,
  the node and the status as a string. It holds the result, the times as
  ISO 8601 strings and the metadata. `DomovoyCore.Value.dump/1` or
  `DomovoyCore.Error.dump/1` gives the result document.
  """
  @spec dump(record :: t()) :: {:ok, document()} | {:error, Error.t()}
  def dump(%Record{} = record) do
    with {:ok, job} <- Job.dump(record.job),
         {:ok, result} <- dump_result(record.result) do
      {:ok,
       %{
         "version" => @version,
         "job" => job,
         "node" => record.node,
         "status" => Atom.to_string(record.status),
         "result" => result,
         "started_at" => dump_time(record.started_at),
         "finished_at" => dump_time(record.finished_at),
         "metadata" => record.metadata
       }}
    end
  end

  @doc """
  Translates a document that `dump/1` gave back to a record.

  A `"version"` other than `#{@version}` gives `DomovoyCore.Error.unsupported_version/1`.
  A status or a time that does not read gives `DomovoyCore.Error.load_error/1`.
  A job or a result that does not load gives its own error.
  """
  @spec load(document :: any()) :: {:ok, t()} | {:error, Error.t()}
  def load(%{"version" => @version, "job" => job, "node" => node, "status" => status} = document)
      when is_binary(node) do
    with {:ok, job} <- Job.load(job),
         {:ok, status} <- load_status(status),
         {:ok, result} <- load_result(status, Map.get(document, "result")),
         {:ok, started_at} <- load_time(Map.get(document, "started_at")),
         {:ok, finished_at} <- load_time(Map.get(document, "finished_at")) do
      {:ok,
       %Record{
         job: job,
         node: node,
         status: status,
         result: result,
         started_at: started_at,
         finished_at: finished_at,
         metadata: Map.get(document, "metadata", %{})
       }}
    end
  end

  def load(%{"version" => @version}), do: {:error, Error.load_error(Record)}
  def load(%{"version" => version}), do: {:error, Error.unsupported_version(version)}
  def load(_document), do: {:error, Error.unsupported_version(nil)}

  @spec check!(record :: t()) :: t()
  defp check!(%Record{status: status, node: node}) when status not in @statuses do
    raise ArgumentError,
          "status of record #{inspect(node)} must be one of #{inspect(@statuses)}, got: #{inspect(status)}"
  end

  defp check!(%Record{status: :ok, result: %Value{}} = record), do: record

  defp check!(%Record{status: :ok, node: node}) do
    raise ArgumentError,
          "record #{inspect(node)} with status :ok needs a %DomovoyCore.Value{} result"
  end

  defp check!(%Record{status: :error, result: %Error{}} = record), do: record

  defp check!(%Record{status: :error, node: node}) do
    raise ArgumentError,
          "record #{inspect(node)} with status :error needs a %DomovoyCore.Error{} result"
  end

  defp check!(%Record{status: status, result: nil} = record)
       when status in [:cancelled, :skipped],
       do: record

  defp check!(%Record{status: status, node: node}) when status in [:cancelled, :skipped] do
    raise ArgumentError,
          "record #{inspect(node)} with status #{inspect(status)} needs a nil result"
  end

  @spec dump_result(result()) ::
          {:ok, map() | nil} | {:error, Error.t()}
  defp dump_result(nil), do: {:ok, nil}
  defp dump_result(%Value{} = value), do: Value.dump(value)
  defp dump_result(%Error{} = error), do: {:ok, Error.dump(error)}

  @spec dump_time(time :: DateTime.t() | nil) :: String.t() | nil
  defp dump_time(nil), do: nil
  defp dump_time(%DateTime{} = time), do: DateTime.to_iso8601(time)

  @spec load_status(document :: any()) :: {:ok, status()} | {:error, Error.t()}
  defp load_status("ok"), do: {:ok, :ok}
  defp load_status("error"), do: {:ok, :error}
  defp load_status("cancelled"), do: {:ok, :cancelled}
  defp load_status("skipped"), do: {:ok, :skipped}
  defp load_status(_document), do: {:error, Error.load_error(Record)}

  @spec load_result(status :: status(), document :: any()) ::
          {:ok, result()} | {:error, Error.t()}
  defp load_result(:ok, document), do: Value.load(document)
  defp load_result(:error, document), do: Error.load(document)
  defp load_result(status, nil) when status in [:cancelled, :skipped], do: {:ok, nil}
  defp load_result(_status, _document), do: {:error, Error.load_error(Record)}

  @spec load_time(document :: any()) :: {:ok, DateTime.t() | nil} | {:error, Error.t()}
  defp load_time(nil), do: {:ok, nil}

  defp load_time(document) when is_binary(document) do
    case DateTime.from_iso8601(document) do
      {:ok, time, _offset} -> {:ok, time}
      {:error, _reason} -> {:error, Error.load_error(Record)}
    end
  end

  defp load_time(_document), do: {:error, Error.load_error(Record)}
end
