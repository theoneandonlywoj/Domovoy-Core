defmodule DomovoyCore.EngineTest do
  use ExUnit.Case, async: false

  alias DomovoyCore.Context
  alias DomovoyCore.Engine
  alias DomovoyCore.Error
  alias DomovoyCore.Graph
  alias DomovoyCore.Job
  alias DomovoyCore.Journal
  alias DomovoyCore.Node
  alias DomovoyCore.Record
  alias DomovoyCore.Runtime
  alias DomovoyCore.Store
  alias DomovoyCore.Test.Journal.Memory, as: MemoryJournal
  alias DomovoyCore.Test.Runner.Crash
  alias DomovoyCore.Test.Runner.Fail
  alias DomovoyCore.Test.Runner.FailUntilAttempt
  alias DomovoyCore.Test.Runner.SumOverride
  alias DomovoyCore.Test.Runner.Wait
  alias DomovoyCore.Test.Store.Memory, as: MemoryStore
  alias DomovoyCore.Test.Support
  alias DomovoyCore.Type.Integer, as: IntegerType
  alias DomovoyCore.Value

  @runtime DomovoyCore.Test.EngineRuntime

  setup do
    start_supervised!({DomovoyCore.Runtime, name: @runtime})
    :ok
  end

  test "runs a graph and returns one record per node" do
    context = context("straight")

    graph =
      Graph.new([
        Support.node("double", %{a: {"count", IntegerType}}),
        Support.node("increment", %{a: {"count", IntegerType}}, %{add: {1, IntegerType}}),
        Support.node("total", %{a: {"double", IntegerType}, b: {"increment", IntegerType}})
      ])

    assert {:ok, records} = Engine.run(graph, %{"count" => value(20)}, context)
    assert %Record{result: %Value{value: 20}} = records["double"]
    assert %Record{result: %Value{value: 21}} = records["increment"]
    assert %Record{result: %Value{value: 41}} = records["total"]
    assert %DateTime{} = records["total"].started_at
    assert %DateTime{} = records["total"].finished_at
    assert_receive {:ran, "total", %Job{id: "straight"}}
  end

  test "reuses exact-generation store hits and skips runner work" do
    job = Job.new("hits", %{"notify" => self()})
    {:ok, store} = Store.open(MemoryStore, job.id, workflow: "engine")
    hit = record(job, "double", 40)
    assert Store.put(store, hit) == :ok
    context = %Context{job: job, workflow: "engine", store: store, runtime: @runtime}
    graph = Graph.new([Support.node("double", %{a: {"count", IntegerType}})])

    assert {:ok, %{"double" => ^hit}} = Engine.run(graph, %{"count" => value(20)}, context)
    refute_received {:ran, "double", _}
  end

  test "retries retryable failures and keeps earlier attempts" do
    job = Job.new("retry", %{"notify" => self()})
    {:ok, store} = Store.open(MemoryStore, job.id, workflow: "engine")
    {:ok, journal} = Journal.open(@runtime, MemoryJournal, job.id, workflow: "engine")

    context = %Context{
      job: job,
      workflow: "engine",
      store: store,
      journal: journal,
      runtime: @runtime
    }

    graph =
      Graph.new([
        Node.new(%{
          name: "until",
          runner: FailUntilAttempt,
          type: IntegerType,
          args: %{succeed_on_attempt: {2, IntegerType}},
          retry: [max_attempts: 3, backoff_ms: 1]
        })
      ])

    assert {:ok, %{"until" => %Record{result: %Value{value: 2}, job: %Job{attempt: 2}}}} =
             Engine.run(graph, %{}, context)

    assert_receive {:attempt, "until", %Job{attempt: 1}}
    assert_receive {:attempt, "until", %Job{attempt: 2}}
    {:ok, stored} = Store.all(store)
    assert Enum.map(stored, &{&1.job.attempt, &1.status}) == [{1, :error}, {2, :ok}]
    {:ok, events} = Journal.events(journal)

    assert Enum.map(events, & &1.kind) == [
             :node_started,
             :node_failed,
             :node_retried,
             :node_started,
             :node_finished
           ]
  end

  test "cancels active work and skips unstarted successors after a terminal failure" do
    context = context("fail")

    graph =
      Graph.new([
        Node.new(%{name: "boom", runner: Fail, type: IntegerType}),
        Support.node("after", %{}, %{}, after: ["boom"]),
        Node.new(%{name: "wait", runner: Wait, type: IntegerType})
      ])

    task = Task.async(fn -> Engine.run(graph, %{}, context) end)
    assert_receive {:runner_started, "wait", pid}
    send(pid, {:continue, 1})

    assert {:error, %Error{type: :deliberate_failure}, records} = Task.await(task)
    assert records["boom"].status == :error
    assert records["after"].status == :skipped
    assert records["wait"].status in [:ok, :cancelled]
    assert Task.Supervisor.children(Runtime.engine_task_supervisor(@runtime)) == []
  end

  test "does not persist records when store? is false" do
    job = Job.new("secret", %{"notify" => self()})
    {:ok, store} = Store.open(MemoryStore, job.id, workflow: "engine")
    context = %Context{job: job, workflow: "engine", store: store, runtime: @runtime}

    graph =
      Graph.new([
        Support.node("secret", %{a: {"count", IntegerType}}, %{}, store?: false)
      ])

    assert {:ok, %{"secret" => %Record{result: %Value{value: 8}}}} =
             Engine.run(graph, %{"count" => value(8)}, context)

    assert Store.get(store, "secret", 0) == :miss
  end

  test "replaces a runner when the override matches the typed contract" do
    context = context("override")
    graph = Graph.new([Support.node("sum")])

    assert {:ok, %{"sum" => %Record{result: %Value{value: 99}}}} =
             Engine.run(graph, %{}, context, runners: %{"sum" => SumOverride})

    assert_receive {:overridden, %Context{node: "sum"}}
  end

  test "normalizes a raised runner without raising in the caller" do
    context = context("crash")
    graph = Graph.new([Node.new(%{name: "crash", runner: Crash, type: IntegerType})])

    assert {:error, %Error{type: :runner_failed, retryable?: true},
            %{"crash" => %Record{status: :error}}} = Engine.run(graph, %{}, context)
  end

  test "rejects an unknown graph input only after graph construction succeeds" do
    context = context("missing")
    graph = Graph.new([Support.node("sum", %{a: {"count", IntegerType}})])

    assert {:error, %Error{}, %{}} = Engine.run(graph, %{}, context)
  end

  @spec context(String.t()) :: Context.t()
  defp context(run_id) do
    %Context{
      job: Job.new(run_id, %{"notify" => self()}),
      workflow: "engine",
      runtime: @runtime
    }
  end

  @spec value(integer()) :: Value.t()
  defp value(raw), do: Value.cast!(raw, IntegerType)

  @spec record(Job.t(), String.t(), integer()) :: Record.t()
  defp record(%Job{} = job, node, raw) do
    Record.new(%{job: job, node: node, status: :ok, result: value(raw)})
  end
end
