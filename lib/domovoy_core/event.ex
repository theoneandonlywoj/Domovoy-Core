defmodule DomovoyCore.Event do
  @moduledoc """
  One change of the state of a run.

  A `DomovoyCore.Journal` keeps the events of a run in order, and
  `DomovoyCore.Journal.append/2` sends each one to the selected runtime's PubSub. An event
  holds the `DomovoyCore.Job` of the run as it was at the time, the time, the
  `kind` of the change, the `subject` that it is about, and a `payload` with
  string keys. The job names the run and holds its generation and attempt,
  so the payload holds only what changed. The subject is a node name, a
  vertex name, or the workflow name for a run event.

  `kinds/0` gives the kinds. The Engine emits node events for each attempt.
  It emits `:node_retried` with the next attempt's job before the fixed
  backoff starts. The payload holds `"backoff_ms"`.

  A terminal node failure stops new work. The Engine emits `:node_cancelled`
  for active nodes and nodes that wait for a retry. It emits `:node_skipped`
  for nodes that did not start. These events carry the jobs of their records.

  ## Examples

      iex> job = DomovoyCore.Job.new("dom-30") |> DomovoyCore.Job.at_generation(1)
      iex> event = DomovoyCore.Event.new(%{
      ...>   job: job,
      ...>   kind: :node_finished,
      ...>   subject: "worktree_diff",
      ...>   payload: %{"hit" => false},
      ...>   at: ~U[2026-09-13 10:00:01Z]
      ...> })
      iex> {:ok, document} = DomovoyCore.Event.dump(event)
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
        "at" => "2026-09-13T10:00:01Z",
        "kind" => "node_finished",
        "subject" => "worktree_diff",
        "payload" => %{"hit" => false},
        "metadata" => %{}
      }
      iex> DomovoyCore.Event.load(document)
      {:ok, event}

  A kind that `kinds/0` does not hold raises:

      iex> job = DomovoyCore.Job.new("dom-30")
      iex> DomovoyCore.Event.new(%{job: job, kind: :node_paused, subject: "sum"})
      ** (ArgumentError) kind of event about "sum" is not a kind of DomovoyCore.Event, got: :node_paused

      iex> DomovoyCore.Event.load(%{"version" => 2})
      {:error, DomovoyCore.Error.unsupported_version(2)}
  """

  alias DomovoyCore.Error
  alias DomovoyCore.Event
  alias DomovoyCore.Job

  @version 1

  @kinds [
    :run_started,
    :stage_started,
    :node_started,
    :node_finished,
    :node_failed,
    :node_retried,
    :node_cancelled,
    :node_skipped,
    :stage_finished,
    :stage_failed,
    :decision_awaited,
    :decided,
    :run_halted,
    :run_finished,
    :run_failed
  ]

  @typedoc "What changed."
  @type kind() ::
          :run_started
          | :stage_started
          | :node_started
          | :node_finished
          | :node_failed
          | :node_retried
          | :node_cancelled
          | :node_skipped
          | :stage_finished
          | :stage_failed
          | :decision_awaited
          | :decided
          | :run_halted
          | :run_finished
          | :run_failed

  @typedoc "The document that `dump/1` gives and `load/1` takes."
  @type document() :: %{required(String.t()) => any()}

  @type t() :: %Event{
          job: Job.t(),
          at: DateTime.t(),
          kind: kind(),
          subject: String.t(),
          payload: %{String.t() => any()},
          metadata: %{String.t() => any()}
        }

  @type new() :: %{
          required(:job) => Job.t(),
          required(:kind) => kind(),
          required(:subject) => String.t(),
          optional(:at) => DateTime.t(),
          optional(:payload) => %{String.t() => any()},
          optional(:metadata) => %{String.t() => any()}
        }

  defstruct job: nil,
            at: nil,
            kind: nil,
            subject: nil,
            payload: %{},
            metadata: %{}

  @doc """
  Gives the kinds of event, in the order of a run.
  """
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc """
  Makes an event. `at` is now by default. A kind that `kinds/0` does not
  hold raises an `ArgumentError`.
  """
  @spec new(args :: new()) :: t()
  def new(args) when is_map(args) do
    kind = Map.fetch!(args, :kind)
    subject = Map.fetch!(args, :subject)

    if kind not in @kinds do
      raise ArgumentError,
            "kind of event about #{inspect(subject)} is not a kind of DomovoyCore.Event, " <>
              "got: #{inspect(kind)}"
    end

    %Event{
      job: Map.fetch!(args, :job),
      at: Map.get_lazy(args, :at, &DateTime.utc_now/0),
      kind: kind,
      subject: subject,
      payload: Map.get(args, :payload) || %{},
      metadata: Map.get(args, :metadata) || %{}
    }
  end

  @doc """
  Translates `event` to the document that a journal keeps. The job goes in
  as `DomovoyCore.Job.dump/1` gives it.
  """
  @spec dump(event :: t()) :: {:ok, document()} | {:error, Error.t()}
  def dump(%Event{} = event) do
    with {:ok, job} <- Job.dump(event.job) do
      {:ok,
       %{
         "version" => @version,
         "job" => job,
         "at" => DateTime.to_iso8601(event.at),
         "kind" => Atom.to_string(event.kind),
         "subject" => event.subject,
         "payload" => event.payload,
         "metadata" => event.metadata
       }}
    end
  end

  @doc """
  Translates a document that `dump/1` gave back to an event.

  A `"version"` other than `#{@version}` gives `DomovoyCore.Error.unsupported_version/1`.
  A kind or a time that does not read gives `DomovoyCore.Error.load_error/1`.
  A job that does not load gives its own error.
  """
  @spec load(document :: any()) :: {:ok, t()} | {:error, Error.t()}
  def load(
        %{
          "version" => @version,
          "job" => job,
          "at" => at,
          "kind" => kind,
          "subject" => subject
        } =
          document
      )
      when is_binary(at) and is_binary(kind) and is_binary(subject) do
    with {:ok, job} <- Job.load(job),
         {:ok, kind} <- load_kind(kind),
         {:ok, at} <- load_time(at) do
      {:ok,
       %Event{
         job: job,
         at: at,
         kind: kind,
         subject: subject,
         payload: Map.get(document, "payload", %{}),
         metadata: Map.get(document, "metadata", %{})
       }}
    end
  end

  def load(%{"version" => @version}), do: {:error, Error.load_error(Event)}
  def load(%{"version" => version}), do: {:error, Error.unsupported_version(version)}
  def load(_document), do: {:error, Error.unsupported_version(nil)}

  @spec load_kind(name :: String.t()) :: {:ok, kind()} | {:error, Error.t()}
  defp load_kind(name) do
    case Enum.find(@kinds, &(Atom.to_string(&1) == name)) do
      nil -> {:error, Error.load_error(Event)}
      kind -> {:ok, kind}
    end
  end

  @spec load_time(document :: String.t()) :: {:ok, DateTime.t()} | {:error, Error.t()}
  defp load_time(document) do
    case DateTime.from_iso8601(document) do
      {:ok, time, _offset} -> {:ok, time}
      {:error, _reason} -> {:error, Error.load_error(Event)}
    end
  end
end
