defmodule DomovoyCore.Job do
  @moduledoc """
  The identity of one run.

  A job has an `id`, which is a `DomovoyCore.Name`, a `generation`, an `attempt`
  and a `metadata` map with string keys.

    * `generation` starts at `0`. Each `{:rerun, stage}` of a workflow raises
      it by one. The id does not change, so a Stage at generation `1` writes
      its own records, and the records of generation `0` stay in the store.
    * `attempt` starts at `1`. It counts the executions of one node at one
      generation. The incoming attempt is the first attempt for each node.
      Each retry increments it for that node.
    * `metadata` belongs to the caller, and the core never reads it.

  `DomovoyCore.Context`, `DomovoyCore.Record` and `DomovoyCore.Event` carry the job, so
  a runner and a reader of the journal see the keys that the caller put in the
  metadata.

  Different nodes can have the same attempt number. Each attempt has its own
  job and record. The Store key includes the node name and the attempt number,
  so it keeps earlier failed attempts after a retry succeeds.

  ## Examples

  `new/2` checks the id with `DomovoyCore.Name.check!/1`:

      iex> job = DomovoyCore.Job.new("dom-30", %{"issue_id" => "DOM-31"})
      iex> job
      %DomovoyCore.Job{id: "dom-30", generation: 0, attempt: 1, metadata: %{"issue_id" => "DOM-31"}}

      iex> DomovoyCore.Job.new("../x")
      ** (ArgumentError) "../x" is not a name: a name matches ~r/^[A-Za-z0-9_-]+$/

  `next_generation/1` raises the generation and puts the attempt back to `1`.
  `at_generation/2` and `at_attempt/2` set one count:

      iex> job = DomovoyCore.Job.new("dom-30")
      iex> next = job |> DomovoyCore.Job.at_attempt(3) |> DomovoyCore.Job.next_generation()
      iex> {next.id, next.generation, next.attempt}
      {"dom-30", 1, 1}
      iex> DomovoyCore.Job.at_generation(job, 4).generation
      4

  `dump/1` gives the document that a record or an event keeps, and `load/1`
  reads it:

      iex> job = DomovoyCore.Job.new("dom-30")
      iex> {:ok, document} = DomovoyCore.Job.dump(job)
      iex> document
      %{"version" => 1, "id" => "dom-30", "generation" => 0, "attempt" => 1, "metadata" => %{}}
      iex> DomovoyCore.Job.load(document)
      {:ok, job}

      iex> DomovoyCore.Job.load(%{"version" => 1, "id" => "a/b", "generation" => 0, "attempt" => 1})
      {:error, DomovoyCore.Error.load_error(DomovoyCore.Job)}
      iex> DomovoyCore.Job.load(%{"version" => 2})
      {:error, DomovoyCore.Error.unsupported_version(2)}
  """

  alias DomovoyCore.Error
  alias DomovoyCore.Job
  alias DomovoyCore.Name

  @version 1

  @typedoc "The document that `dump/1` gives and `load/1` takes."
  @type document() :: %{required(String.t()) => any()}

  @type t() :: %Job{
          id: Name.t(),
          generation: non_neg_integer(),
          attempt: pos_integer(),
          metadata: %{String.t() => any()}
        }

  defstruct id: nil,
            generation: 0,
            attempt: 1,
            metadata: %{}

  @doc """
  Makes a job with `id` and `metadata`, at generation `0` and attempt `1`.

  `id` must be a `DomovoyCore.Name`, or this function raises an `ArgumentError`.
  """
  @spec new(id :: Name.t(), metadata :: %{String.t() => any()}) :: t()
  def new(id, metadata \\ %{}) when is_map(metadata) do
    %Job{id: Name.check!(id), metadata: metadata}
  end

  @doc """
  Gives `job` at the next generation, with the attempt back at `1`.
  """
  @spec next_generation(job :: t()) :: t()
  def next_generation(%Job{generation: generation} = job) do
    %Job{job | generation: generation + 1, attempt: 1}
  end

  @doc """
  Gives `job` at `generation`.
  """
  @spec at_generation(job :: t(), generation :: non_neg_integer()) :: t()
  def at_generation(%Job{} = job, generation) when is_integer(generation) and generation >= 0 do
    %Job{job | generation: generation}
  end

  @doc """
  Gives `job` at `attempt`.
  """
  @spec at_attempt(job :: t(), attempt :: pos_integer()) :: t()
  def at_attempt(%Job{} = job, attempt) when is_integer(attempt) and attempt >= 1 do
    %Job{job | attempt: attempt}
  end

  @doc """
  Translates `job` to the document that a record or an event keeps.
  """
  @spec dump(job :: t()) :: {:ok, document()} | {:error, Error.t()}
  def dump(%Job{} = job) do
    {:ok,
     %{
       "version" => @version,
       "id" => job.id,
       "generation" => job.generation,
       "attempt" => job.attempt,
       "metadata" => job.metadata
     }}
  end

  @doc """
  Translates a document that `dump/1` gave back to a job.

  A `"version"` other than `#{@version}` gives `DomovoyCore.Error.unsupported_version/1`.
  An id that is not a `DomovoyCore.Name`, or a count that is not an integer,
  gives `DomovoyCore.Error.load_error/1`.
  """
  @spec load(document :: any()) :: {:ok, t()} | {:error, Error.t()}
  def load(
        %{"version" => @version, "id" => id, "generation" => generation, "attempt" => attempt} =
          document
      )
      when is_integer(generation) and generation >= 0 and is_integer(attempt) and attempt >= 1 do
    if Name.valid?(id) do
      {:ok,
       %Job{
         id: id,
         generation: generation,
         attempt: attempt,
         metadata: Map.get(document, "metadata", %{})
       }}
    else
      {:error, Error.load_error(Job)}
    end
  end

  def load(%{"version" => @version}), do: {:error, Error.load_error(Job)}
  def load(%{"version" => version}), do: {:error, Error.unsupported_version(version)}
  def load(_document), do: {:error, Error.unsupported_version(nil)}
end
