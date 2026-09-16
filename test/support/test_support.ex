defmodule DomovoyCore.Test.Type.Celsius do
  @moduledoc false
  use DomovoyCore.Type

  @impl Ecto.Type
  def type, do: :integer

  @impl DomovoyCore.Type
  def cast(raw, %{"unit" => "fahrenheit"}) when is_number(raw),
    do: {:ok, round((raw - 32) * 5 / 9), %{"unit" => "celsius"}}

  def cast(raw, _metadata) when is_number(raw), do: {:ok, raw}
  def cast(_raw, _metadata), do: {:error, expected: :number}
end

defmodule DomovoyCore.Test.Validator.Positive do
  @moduledoc false
  @behaviour DomovoyCore.Validator

  @impl DomovoyCore.Validator
  def validate(changeset, context) do
    Ecto.Changeset.validate_number(
      changeset,
      :count,
      greater_than: Map.get(context.metadata, "minimum", 0)
    )
  end
end

defmodule DomovoyCore.Test.Validator.TraceFirst do
  @moduledoc false
  @behaviour DomovoyCore.Validator

  @impl DomovoyCore.Validator
  def validate(changeset, context) do
    send(context.job.metadata["notify"], :runner_validator_first)
    changeset
  end
end

defmodule DomovoyCore.Test.Validator.TraceSecond do
  @moduledoc false
  @behaviour DomovoyCore.Validator

  @impl DomovoyCore.Validator
  def validate(changeset, context) do
    send(context.job.metadata["notify"], :runner_validator_second)
    changeset
  end
end

defmodule DomovoyCore.Test.Validator.TraceNode do
  @moduledoc false
  @behaviour DomovoyCore.Validator

  @impl DomovoyCore.Validator
  def validate(changeset, context) do
    send(context.job.metadata["notify"], :node_validator)
    changeset
  end
end

defmodule DomovoyCore.Test.Runner.Sum do
  @moduledoc false
  use DomovoyCore.Runner

  input do
    field(:a, DomovoyCore.Type.Integer)
    field(:b, DomovoyCore.Type.Integer)
    field(:add, DomovoyCore.Type.Integer, default: 0)
    field(:text, DomovoyCore.Type.String, default: "")
  end

  @impl DomovoyCore.Runner
  def run(input, context) do
    if pid = context.job.metadata["notify"], do: send(pid, {:ran, context.node, context.job})
    {:ok, (input.a || 0) + (input.b || 0) + input.add + String.length(input.text)}
  end
end

defmodule DomovoyCore.Test.Runner.SumOverride do
  @moduledoc false
  use DomovoyCore.Runner

  input do
    field(:a, DomovoyCore.Type.Integer)
    field(:b, DomovoyCore.Type.Integer)
    field(:add, DomovoyCore.Type.Integer, default: 0)
    field(:text, DomovoyCore.Type.String, default: "")
  end

  @impl DomovoyCore.Runner
  def run(_input, context) do
    send(context.job.metadata["notify"], {:overridden, context})
    {:ok, 99}
  end
end

defmodule DomovoyCore.Test.Runner.Extra do
  @moduledoc false
  use DomovoyCore.Runner, extra?: true

  input do
    field(:count, DomovoyCore.Type.Integer, default: 1)
  end

  @impl DomovoyCore.Runner
  def run(input, _context), do: {:ok, input.extra}
end

defmodule DomovoyCore.Test.Runner.Typed do
  @moduledoc false
  use DomovoyCore.Runner, retry: [max_attempts: 3, backoff_ms: 5, timeout_ms: 500]

  input do
    field(:count, DomovoyCore.Type.Integer)
    field(:label, DomovoyCore.Type.String, default: "items")
    field(:payload, DomovoyCore.Type.Any)
  end

  required([:count, :label])
  validators([DomovoyCore.Test.Validator.Positive])

  @impl DomovoyCore.Runner
  def run(input, context), do: {:ok, input.count, %{context: context}}
end

defmodule DomovoyCore.Test.Runner.Trace do
  @moduledoc false
  use DomovoyCore.Runner

  input do
    field(:count, DomovoyCore.Type.Integer)
  end

  required([:count])

  validators([
    DomovoyCore.Test.Validator.TraceFirst,
    DomovoyCore.Test.Validator.TraceSecond
  ])

  @impl DomovoyCore.Runner
  def run(input, context) do
    send(context.job.metadata["notify"], {:runner, input, context})
    {:ok, input.count}
  end
end

defmodule DomovoyCore.Test.Runner.FailUntilAttempt do
  @moduledoc false
  use DomovoyCore.Runner, retry: [max_attempts: 3, backoff_ms: 1]

  input do
    field(:succeed_on_attempt, DomovoyCore.Type.Integer)
  end

  required([:succeed_on_attempt])

  @impl DomovoyCore.Runner
  def run(input, context) do
    send(context.job.metadata["notify"], {:attempt, context.node, context.job})

    if context.job.attempt >= input.succeed_on_attempt,
      do: {:ok, context.job.attempt},
      else: {:error, :configured_failure}
  end
end

defmodule DomovoyCore.Test.Runner.Fail do
  @moduledoc false
  use DomovoyCore.Runner, retry: [max_attempts: 3]

  input do
  end

  @impl DomovoyCore.Runner
  def run(_input, _context),
    do: {:error, %DomovoyCore.Error{type: :deliberate_failure, retryable?: false}}
end

defmodule DomovoyCore.Test.Runner.Crash do
  @moduledoc false
  use DomovoyCore.Runner

  input do
  end

  @impl DomovoyCore.Runner
  def run(_input, _context), do: raise("deliberate runner failure")
end

defmodule DomovoyCore.Test.Runner.Wait do
  @moduledoc false
  use DomovoyCore.Runner

  input do
  end

  @impl DomovoyCore.Runner
  def run(_input, context) do
    receiver = context.job.metadata["notify"]
    send(receiver, {:runner_started, context.node, self()})

    receive do
      {:continue, value} -> {:ok, value}
      :fail -> {:error, :deliberate_failure}
    end
  end
end

defmodule DomovoyCore.Test.AlwaysApproveDecider do
  @moduledoc false
  @behaviour DomovoyCore.Decider

  @impl DomovoyCore.Decider
  def decide(_decision, _context, _opts), do: {:ok, "approve"}
end

defmodule DomovoyCore.Test.Tables do
  @moduledoc false
  use Agent

  @spec start_link(term()) :: Agent.on_start()
  def start_link(_opts \\ []) do
    Agent.start_link(fn -> %{} end, name: __MODULE__)
  end

  @spec table(atom(), String.t(), String.t(), :set | :ordered_set) :: :ets.tid()
  def table(kind, workflow, run_id, type) do
    key = {kind, workflow, run_id}

    Agent.get_and_update(__MODULE__, fn tables ->
      case tables do
        %{^key => tid} ->
          {tid, tables}

        %{} ->
          tid = :ets.new(__MODULE__, [type, :public])
          {tid, Map.put(tables, key, tid)}
      end
    end)
  end
end

defmodule DomovoyCore.Test.Store.Memory do
  @moduledoc false
  @behaviour DomovoyCore.Store

  alias DomovoyCore.Test.Tables

  @impl DomovoyCore.Store
  def open(run_id, opts) do
    workflow = Keyword.get(opts, :workflow, "")
    {:ok, Tables.table(:store, workflow, run_id, :set)}
  end

  @impl DomovoyCore.Store
  def put(table, record) do
    true = :ets.insert(table, {DomovoyCore.Record.key(record), record})
    :ok
  end

  @impl DomovoyCore.Store
  def get(table, node, generation),
    do: table |> records(node) |> DomovoyCore.Store.pick(generation, :exact)

  @impl DomovoyCore.Store
  def latest(table, node, generation),
    do: table |> records(node) |> DomovoyCore.Store.pick(generation, :latest)

  @impl DomovoyCore.Store
  def all(table) do
    records = table |> :ets.tab2list() |> Enum.map(&elem(&1, 1))
    {:ok, Enum.sort_by(records, &DomovoyCore.Record.key/1)}
  end

  @impl DomovoyCore.Store
  def runs(_opts), do: {:ok, []}

  @impl DomovoyCore.Store
  def durable?, do: false

  @spec records(:ets.tid(), String.t()) :: [DomovoyCore.Record.t()]
  defp records(table, node) do
    table
    |> :ets.tab2list()
    |> Enum.map(&elem(&1, 1))
    |> Enum.filter(&(&1.node == node))
  end
end

defmodule DomovoyCore.Test.Journal.Memory do
  @moduledoc false
  @behaviour DomovoyCore.Journal

  alias DomovoyCore.Test.Tables

  @impl DomovoyCore.Journal
  def open(run_id, opts) do
    workflow = Keyword.get(opts, :workflow, "")
    {:ok, Tables.table(:journal, workflow, run_id, :ordered_set)}
  end

  @impl DomovoyCore.Journal
  def append(table, event) do
    true = :ets.insert(table, {System.unique_integer([:monotonic, :positive]), event})
    :ok
  end

  @impl DomovoyCore.Journal
  def events(table), do: {:ok, Enum.map(:ets.tab2list(table), &elem(&1, 1))}

  @impl DomovoyCore.Journal
  def durable?, do: false
end

defmodule DomovoyCore.Test.Support do
  @moduledoc false

  alias DomovoyCore.Choice
  alias DomovoyCore.Decision
  alias DomovoyCore.Graph
  alias DomovoyCore.Journal.FileSystem, as: FileSystemJournal
  alias DomovoyCore.Node
  alias DomovoyCore.Stage
  alias DomovoyCore.Store.FileSystem, as: FileSystemStore
  alias DomovoyCore.Test.Journal.Memory, as: MemoryJournal
  alias DomovoyCore.Test.Runner.Sum
  alias DomovoyCore.Test.Store.Memory, as: MemoryStore
  alias DomovoyCore.Type.Integer, as: IntegerType
  alias DomovoyCore.Workflow
  alias DomovoyCore.Workflow.Server

  @spec node(String.t(), map(), map(), keyword()) :: Node.t()
  def node(name, bind \\ %{}, args \\ %{}, opts \\ []) do
    opts
    |> Map.new()
    |> Map.merge(%{name: name, runner: Sum, type: IntegerType, bind: bind, args: args})
    |> Node.new()
  end

  @spec review_workflow(keyword()) :: Workflow.t()
  def review_workflow(opts \\ []) do
    prepare =
      Stage.new(%{
        name: "prepare",
        graph: Graph.new([node("total", %{a: {"base", IntegerType}})]),
        next: "review"
      })

    review =
      Decision.new(%{
        name: "review",
        prompt: "Continue?",
        choices: [
          Choice.new(%{name: "approve", description: "Continue.", target: {:run, "finish"}}),
          Choice.new(%{
            name: "revise",
            description: "Run again.",
            target: {:rerun, "prepare"},
            inputs: %{"base" => IntegerType}
          }),
          Choice.new(%{name: "stop", description: "Stop.", target: :halt})
        ]
      })

    finish = Stage.new(%{name: "finish", graph: Graph.new()})

    Workflow.new!(%{
      name: Keyword.get(opts, :name, "review_workflow"),
      vertices: %{"prepare" => prepare, "review" => review, "finish" => finish},
      start: "prepare",
      inputs: %{"base" => %{type: IntegerType, default: 1}},
      store: Keyword.get(opts, :store, MemoryStore),
      journal: Keyword.get(opts, :journal, MemoryJournal)
    })
  end

  @spec filesystem_workflow(String.t(), keyword()) :: Workflow.t()
  def filesystem_workflow(root, opts \\ []) do
    review_workflow(
      name: Keyword.get(opts, :name, "review_workflow"),
      store: {FileSystemStore, root: root},
      journal: {FileSystemJournal, root: root}
    )
  end

  @spec temporary_root(String.t()) :: String.t()
  def temporary_root(prefix) do
    Path.join(System.tmp_dir!(), "domovoy-#{prefix}-#{System.unique_integer([:positive])}")
  end

  @spec await_state(GenServer.server(), atom(), pos_integer()) :: Server.view()
  def await_state(server, status, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    await_state_until(server, status, deadline)
  end

  @spec await_state_until(GenServer.server(), atom(), integer()) :: Server.view()
  defp await_state_until(server, status, deadline) do
    case Server.state(server) do
      %{status: ^status} = state ->
        state

      _other ->
        if System.monotonic_time(:millisecond) >= deadline do
          raise ExUnit.AssertionError, message: "server did not reach #{inspect(status)}"
        else
          Process.sleep(10)
          await_state_until(server, status, deadline)
        end
    end
  end
end
