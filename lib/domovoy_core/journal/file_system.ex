defmodule DomovoyCore.Journal.FileSystem do
  @moduledoc """
  `DomovoyCore.Journal` adapter on one JSON line per event.

  `open/2` makes the directory `<root>/<workflow>/<run_id>/`, with `root:` as
  in `DomovoyCore.Store.FileSystem`. `append/2` adds one line to `events.jsonl`
  in that directory, as `DomovoyCore.Event.dump/1` gives it, with
  `File.write/3` in `:append` mode. `events/1` reads every line back. A line
  that does not decode, or a document of another version, gives an error.
  A run without the file has no events yet.

  ## Examples

  This adapter writes to disk, so the example is illustrative:

      iex> root = Path.join(System.tmp_dir!(), "domovoy-journal-doc")
      iex> File.rm_rf!(root)
      iex> {:ok, state} = DomovoyCore.Journal.FileSystem.open("dom-30", workflow: "issue_to_pr", root: root)
      iex> job = DomovoyCore.Job.new("dom-30")
      iex> event = DomovoyCore.Event.new(%{job: job, kind: :run_started, subject: "issue_to_pr"})
      iex> DomovoyCore.Journal.FileSystem.append(state, event)
      :ok
      iex> {:ok, [^event]} = DomovoyCore.Journal.FileSystem.events(state)
      iex> Path.basename(state.path)
      "events.jsonl"
  """

  @behaviour DomovoyCore.Journal

  alias DomovoyCore.Error
  alias DomovoyCore.Event
  alias DomovoyCore.Store

  @file_name "events.jsonl"

  @typedoc "The path of the events file."
  @type state() :: %{path: String.t()}

  @impl DomovoyCore.Journal
  @spec open(run_id :: String.t(), opts :: keyword()) :: {:ok, state()} | {:error, Error.t()}
  def open(run_id, opts) when is_binary(run_id) do
    workflow = Keyword.fetch!(opts, :workflow)
    directory = opts |> Store.FileSystem.root() |> Path.join(workflow) |> Path.join(run_id)

    case File.mkdir_p(directory) do
      :ok -> {:ok, %{path: Path.join(directory, @file_name)}}
      {:error, reason} -> {:error, error(:open, directory, reason)}
    end
  end

  @impl DomovoyCore.Journal
  @spec append(state :: state(), event :: Event.t()) :: :ok | {:error, Error.t()}
  def append(%{path: path}, %Event{} = event) do
    with {:ok, document} <- Event.dump(event),
         {:ok, line} <- encode(document, path) do
      case File.write(path, line <> "\n", [:append]) do
        :ok -> :ok
        {:error, reason} -> {:error, error(:append, path, reason)}
      end
    end
  end

  @impl DomovoyCore.Journal
  @spec events(state :: state()) :: {:ok, [Event.t()]} | {:error, Error.t()}
  def events(%{path: path}) do
    case File.read(path) do
      {:ok, content} -> content |> String.split("\n", trim: true) |> load_lines(path, [])
      {:error, :enoent} -> {:ok, []}
      {:error, reason} -> {:error, error(:events, path, reason)}
    end
  end

  @impl DomovoyCore.Journal
  @spec durable?() :: boolean()
  def durable?, do: true

  @spec encode(document :: map(), path :: String.t()) :: {:ok, String.t()} | {:error, Error.t()}
  defp encode(document, path) do
    {:ok, JSON.encode!(document)}
  rescue
    Protocol.UndefinedError -> {:error, error(:append, path, :not_json)}
  end

  @spec load_lines(lines :: [String.t()], path :: String.t(), events :: [Event.t()]) ::
          {:ok, [Event.t()]} | {:error, Error.t()}
  defp load_lines([], _path, events), do: {:ok, Enum.reverse(events)}

  defp load_lines([line | rest], path, events) do
    with {:ok, document} <- decode(line, path),
         {:ok, event} <- load(document, path) do
      load_lines(rest, path, [event | events])
    end
  end

  @spec decode(line :: String.t(), path :: String.t()) :: {:ok, any()} | {:error, Error.t()}
  defp decode(line, path) do
    case JSON.decode(line) do
      {:ok, document} -> {:ok, document}
      {:error, _reason} -> {:error, error(:events, path, :not_json)}
    end
  end

  @spec load(document :: any(), path :: String.t()) :: {:ok, Event.t()} | {:error, Error.t()}
  defp load(document, path) do
    case Event.load(document) do
      {:ok, event} -> {:ok, event}
      {:error, error} -> {:error, error(:events, path, error)}
    end
  end

  @spec error(operation :: atom(), path :: String.t(), reason :: any()) :: Error.t()
  defp error(operation, path, reason) do
    Error.journal_error(__MODULE__, operation, %{path: path, reason: reason})
  end
end
