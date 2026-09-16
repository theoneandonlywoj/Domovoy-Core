defmodule DomovoyCore.Store.FileSystem do
  @moduledoc """
  `DomovoyCore.Store` adapter on one JSON file per record.

  `open/2` makes the directory `<root>/<workflow>/<run_id>/`. `root` is the
  `root:` option, `.domovoy/runs` by default, expanded against the working
  directory. A record goes to `<node>-g<generation>-a<attempt>.json` in that
  directory, as `DomovoyCore.Record.dump/1` gives it. The adapter writes a
  temporary file next to it and then calls `File.rename/2`, so a write that
  stops half way leaves no partial record file. A read that finds a file it
  cannot decode, or a document of another version, gives an error and does
  not skip the file.

  `runs/1` lists the `<workflow>/<run_id>` directories under `root`. A file
  directly under `root`, such as a run file of an earlier version, is not a
  run and is ignored. Nothing is migrated.

  Every name in a path matches `DomovoyCore.Name`. This adapter cleans nothing.

  ## Examples

  This adapter writes to disk, so the example is illustrative:

      iex> root = Path.join(System.tmp_dir!(), "domovoy-store-doc")
      iex> File.rm_rf!(root)
      iex> {:ok, state} = DomovoyCore.Store.FileSystem.open("dom-30", workflow: "issue_to_pr", root: root)
      iex> job = DomovoyCore.Job.new("dom-30")
      iex> count = DomovoyCore.Value.cast!(1, DomovoyCore.Type.Integer)
      iex> record = DomovoyCore.Record.new(%{job: job, node: "count", status: :ok, result: count})
      iex> DomovoyCore.Store.FileSystem.put(state, record)
      :ok
      iex> "count-g0-a1.json" in File.ls!(state.directory)
      true
      iex> {:ok, runs} = DomovoyCore.Store.FileSystem.runs(root: root)
      iex> %{workflow: "issue_to_pr", run_id: "dom-30"} in runs
      true
  """

  @behaviour DomovoyCore.Store

  alias DomovoyCore.Error
  alias DomovoyCore.Job
  alias DomovoyCore.Record
  alias DomovoyCore.Store

  @default_root ".domovoy/runs"
  @extension ".json"

  @typedoc "The directory of the run."
  @type state() :: %{directory: String.t(), run_id: String.t()}

  @impl DomovoyCore.Store
  @spec open(run_id :: String.t(), opts :: keyword()) :: {:ok, state()} | {:error, Error.t()}
  def open(run_id, opts) when is_binary(run_id) do
    workflow = Keyword.fetch!(opts, :workflow)
    directory = opts |> root() |> Path.join(workflow) |> Path.join(run_id)

    case File.mkdir_p(directory) do
      :ok -> {:ok, %{directory: directory, run_id: run_id}}
      {:error, reason} -> {:error, error(:open, directory, reason)}
    end
  end

  @impl DomovoyCore.Store
  @spec put(state :: state(), record :: Record.t()) :: :ok | {:error, Error.t()}
  def put(%{directory: directory}, %Record{} = record) do
    path = Path.join(directory, file_name(record))

    with {:ok, document} <- Record.dump(record),
         {:ok, json} <- encode(document, path) do
      write(path, json)
    end
  end

  @impl DomovoyCore.Store
  @spec get(state :: state(), node :: Store.node_name(), generation :: non_neg_integer()) ::
          Store.read()
  def get(%{directory: directory}, node, generation) do
    with {:ok, records} <- read_node(directory, node, "#{node}-g#{generation}-a*", :get) do
      Store.pick(records, generation, :exact)
    end
  end

  @impl DomovoyCore.Store
  @spec latest(state :: state(), node :: Store.node_name(), generation :: non_neg_integer()) ::
          Store.read()
  def latest(%{directory: directory}, node, generation) do
    with {:ok, records} <- read_node(directory, node, "#{node}-g*-a*", :latest) do
      Store.pick(records, generation, :latest)
    end
  end

  @impl DomovoyCore.Store
  @spec all(state :: state()) :: {:ok, [Record.t()]} | {:error, Error.t()}
  def all(%{directory: directory}) do
    with {:ok, records} <- read_all(directory, "*-g*-a*", :all) do
      {:ok, Enum.sort_by(records, &Record.key/1)}
    end
  end

  @impl DomovoyCore.Store
  @spec runs(opts :: keyword()) :: {:ok, [Store.run()]} | {:error, Error.t()}
  def runs(opts) do
    runs =
      opts
      |> root()
      |> Path.join("*/*")
      |> Path.wildcard()
      |> Enum.filter(&File.dir?/1)
      |> Enum.map(&run_of_path/1)
      |> Enum.sort()

    {:ok, runs}
  end

  @impl DomovoyCore.Store
  @spec durable?() :: boolean()
  def durable?, do: true

  @doc """
  Gives the root directory of `opts`, expanded.

  ## Examples

      iex> DomovoyCore.Store.FileSystem.root(root: "/tmp/runs")
      "/tmp/runs"
      iex> DomovoyCore.Store.FileSystem.root([]) == Path.expand(".domovoy/runs")
      true
  """
  @spec root(opts :: keyword()) :: String.t()
  def root(opts), do: opts |> Keyword.get(:root, @default_root) |> Path.expand()

  @doc """
  Gives the name of the file of `record`.

  ## Examples

      iex> job = DomovoyCore.Job.new("r") |> DomovoyCore.Job.at_generation(2) |> DomovoyCore.Job.at_attempt(3)
      iex> count = DomovoyCore.Value.cast!(1, DomovoyCore.Type.Integer)
      iex> record = DomovoyCore.Record.new(%{job: job, node: "count", status: :ok, result: count})
      iex> DomovoyCore.Store.FileSystem.file_name(record)
      "count-g2-a3.json"
  """
  @spec file_name(record :: Record.t()) :: String.t()
  def file_name(%Record{job: %Job{} = job, node: node}) do
    "#{node}-g#{job.generation}-a#{job.attempt}#{@extension}"
  end

  @spec encode(document :: map(), path :: String.t()) :: {:ok, String.t()} | {:error, Error.t()}
  defp encode(document, path) do
    {:ok, JSON.encode!(document)}
  rescue
    Protocol.UndefinedError -> {:error, error(:put, path, :not_json)}
  end

  # A temporary file next to the final one, then a rename. The name of the
  # temporary file never matches the glob of a record file.
  @spec write(path :: String.t(), json :: String.t()) :: :ok | {:error, Error.t()}
  defp write(path, json) do
    temporary = path <> ".tmp-" <> Integer.to_string(System.unique_integer([:positive]))

    with :ok <- write_temporary(temporary, json) do
      rename(temporary, path)
    end
  end

  @spec write_temporary(temporary :: String.t(), json :: String.t()) :: :ok | {:error, Error.t()}
  defp write_temporary(temporary, json) do
    case File.write(temporary, json) do
      :ok -> :ok
      {:error, reason} -> {:error, error(:put, temporary, reason)}
    end
  end

  @spec rename(temporary :: String.t(), path :: String.t()) :: :ok | {:error, Error.t()}
  defp rename(temporary, path) do
    case File.rename(temporary, path) do
      :ok ->
        :ok

      {:error, reason} ->
        File.rm(temporary)
        {:error, error(:put, path, reason)}
    end
  end

  @spec read_node(
          directory :: String.t(),
          node :: Store.node_name(),
          glob :: String.t(),
          operation :: atom()
        ) :: {:ok, [Record.t()]} | {:error, Error.t()}
  defp read_node(directory, node, glob, operation) do
    with {:ok, records} <- read_all(directory, glob, operation) do
      {:ok, Enum.filter(records, &(&1.node == node))}
    end
  end

  @spec read_all(directory :: String.t(), glob :: String.t(), operation :: atom()) ::
          {:ok, [Record.t()]} | {:error, Error.t()}
  defp read_all(directory, glob, operation) do
    directory
    |> Path.join(glob <> @extension)
    |> Path.wildcard()
    |> Enum.reduce_while({:ok, []}, fn path, {:ok, records} ->
      case read(path, operation) do
        {:ok, record} -> {:cont, {:ok, [record | records]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  @spec read(path :: String.t(), operation :: atom()) :: {:ok, Record.t()} | {:error, Error.t()}
  defp read(path, operation) do
    with {:ok, content} <- read_file(path, operation),
         {:ok, document} <- decode(content, path, operation) do
      load(document, path, operation)
    end
  end

  @spec read_file(path :: String.t(), operation :: atom()) ::
          {:ok, String.t()} | {:error, Error.t()}
  defp read_file(path, operation) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, error(operation, path, reason)}
    end
  end

  @spec decode(content :: String.t(), path :: String.t(), operation :: atom()) ::
          {:ok, any()} | {:error, Error.t()}
  defp decode(content, path, operation) do
    case JSON.decode(content) do
      {:ok, document} -> {:ok, document}
      {:error, _reason} -> {:error, error(operation, path, :not_json)}
    end
  end

  @spec load(document :: any(), path :: String.t(), operation :: atom()) ::
          {:ok, Record.t()} | {:error, Error.t()}
  defp load(document, path, operation) do
    case Record.load(document) do
      {:ok, record} -> {:ok, record}
      {:error, error} -> {:error, error(operation, path, error)}
    end
  end

  @spec run_of_path(path :: String.t()) :: Store.run()
  defp run_of_path(path) do
    %{workflow: path |> Path.dirname() |> Path.basename(), run_id: Path.basename(path)}
  end

  @spec error(operation :: atom(), path :: String.t(), reason :: any()) :: Error.t()
  defp error(operation, path, reason) do
    Error.store_error(__MODULE__, operation, %{path: path, reason: reason})
  end
end
