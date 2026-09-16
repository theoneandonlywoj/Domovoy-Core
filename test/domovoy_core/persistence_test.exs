defmodule DomovoyCore.PersistenceTest do
  use ExUnit.Case, async: false

  alias DomovoyCore.Error
  alias DomovoyCore.Event
  alias DomovoyCore.Job
  alias DomovoyCore.Journal
  alias DomovoyCore.Journal.FileSystem, as: JournalFileSystem
  alias DomovoyCore.Record
  alias DomovoyCore.Store
  alias DomovoyCore.Store.FileSystem, as: StoreFileSystem
  alias DomovoyCore.Test.Journal.Memory, as: MemoryJournal
  alias DomovoyCore.Test.Store.Memory, as: MemoryStore
  alias DomovoyCore.Test.Support
  alias DomovoyCore.Type.Integer, as: IntegerType
  alias DomovoyCore.Value

  @runtime DomovoyCore.Test.PersistenceRuntime

  setup do
    start_supervised!({DomovoyCore.Runtime, name: @runtime})
    root = Support.temporary_root("persistence")
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root}
  end

  test "store facade identifies adapters and durability" do
    assert Store.adapter?(StoreFileSystem)
    assert Store.adapter?(MemoryStore)
    refute Store.adapter?(JournalFileSystem)
    refute Store.adapter?(nil)
    assert Store.durable?(StoreFileSystem)
    refute Store.durable?(MemoryStore)
  end

  test "memory store implements exact/latest selection and sorted all" do
    job = Job.new("memory-store")
    {:ok, store} = Store.open(MemoryStore, job.id, workflow: "memory")
    zero = record(job, "count", 0, 1, 10)
    failed = error_record(job, "count", 0, 2)
    two = record(job, "count", 2, 1, 30)

    for item <- [two, failed, zero], do: assert(Store.put(store, item) == :ok)

    assert Store.get(store, "count", 0) == {:ok, zero}
    assert Store.get(store, "count", 1) == :miss
    assert Store.latest(store, "count", 1) == {:ok, zero}
    assert Store.latest(store, "count", 2) == {:ok, two}
    assert Store.all(store) == {:ok, [zero, failed, two]}
    assert Store.runs(MemoryStore, []) == {:ok, []}
  end

  test "filesystem store persists records, replaces keys, and isolates workflows", %{root: root} do
    job = Job.new("filesystem-store")
    opts = [workflow: "first", root: root]
    {:ok, store} = Store.open(StoreFileSystem, job.id, opts)
    first = record(job, "sum", 0, 1, 1)
    replacement = record(job, "sum", 0, 1, 2)
    assert Store.put(store, first) == :ok
    assert Store.put(store, replacement) == :ok

    {:ok, reopened} = Store.open(StoreFileSystem, job.id, opts)
    assert Store.get(reopened, "sum", 0) == {:ok, replacement}
    assert Store.all(reopened) == {:ok, [replacement]}
    assert StoreFileSystem.file_name(replacement) == "sum-g0-a1.json"

    {:ok, other} = Store.open(StoreFileSystem, job.id, workflow: "second", root: root)
    assert Store.get(other, "sum", 0) == :miss

    assert Store.runs(StoreFileSystem, root: root) ==
             {:ok,
              [
                %{workflow: "first", run_id: job.id},
                %{workflow: "second", run_id: job.id}
              ]}
  end

  test "filesystem store reports corrupt records", %{root: root} do
    job = Job.new("corrupt-store")
    {:ok, store} = Store.open(StoreFileSystem, job.id, workflow: "flow", root: root)
    File.write!(Path.join(store.state.directory, "sum-g0-a1.json"), "not json")

    assert {:error, %Error{type: :store_error, reason: %{operation: :get}}} =
             Store.get(store, "sum", 0)
  end

  test "filesystem defaults use the .domovoy persistence tree" do
    assert StoreFileSystem.root([]) == Path.expand(".domovoy/runs")
  end

  test "journal facade requires workflow and broadcasts domovoy events" do
    job = Job.new("journal-broadcast")

    assert {:error, %Error{type: :journal_error}} =
             Journal.open(@runtime, MemoryJournal, job.id, [])

    {:ok, journal} = Journal.open(@runtime, MemoryJournal, job.id, workflow: "flow")

    :ok =
      Phoenix.PubSub.subscribe(
        DomovoyCore.Runtime.pubsub(@runtime),
        Journal.topic("flow", job.id)
      )

    event = event(job, :run_started, "flow")
    assert Journal.append(journal, event) == :ok
    assert_receive {:domovoy_event, ^event}
    assert Journal.events(journal) == {:ok, [event]}
    assert Journal.topic("flow", job.id) == "run:flow:journal-broadcast"
  end

  test "journal append emits telemetry for every event kind" do
    parent = self()
    handler = :"journal-telemetry-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach_many(
        handler,
        Event.telemetry_events(),
        fn event, measurements, metadata, _config ->
          send(parent, {event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    job = Job.new("journal-telemetry")
    {:ok, journal} = Journal.open(@runtime, MemoryJournal, job.id, workflow: "flow")

    for kind <- Event.kinds() do
      event = event(job, kind, "sum")
      assert Journal.append(journal, event) == :ok

      assert_receive {[:domovoy_core, :event, ^kind], %{},
                      %{
                        workflow: "flow",
                        run_id: "journal-telemetry",
                        generation: 0,
                        attempt: 1,
                        kind: ^kind,
                        subject: "sum",
                        payload: %{"cursor" => "x"}
                      }}
    end
  end

  test "journal identifies adapters and durability" do
    assert Journal.adapter?(JournalFileSystem)
    assert Journal.adapter?(MemoryJournal)
    refute Journal.adapter?(StoreFileSystem)
    assert Journal.durable?(JournalFileSystem)
    refute Journal.durable?(MemoryJournal)
  end

  test "filesystem journal appends ordered JSON lines and reopens", %{root: root} do
    job = Job.new("filesystem-journal")
    opts = [workflow: "flow", root: root]
    {:ok, journal} = Journal.open(@runtime, JournalFileSystem, job.id, opts)
    started = event(job, :run_started, "flow")
    finished = event(job, :run_finished, "last")
    assert Journal.append(journal, started) == :ok
    assert Journal.append(journal, finished) == :ok

    {:ok, reopened} = Journal.open(@runtime, JournalFileSystem, job.id, opts)
    assert Journal.events(reopened) == {:ok, [started, finished]}
    assert reopened.state.path == Path.join([root, "flow", job.id, "events.jsonl"])
    assert length(reopened.state.path |> File.read!() |> String.split("\n", trim: true)) == 2

    {:ok, other} =
      Journal.open(@runtime, JournalFileSystem, job.id, workflow: "other", root: root)

    assert Journal.events(other) == {:ok, []}
  end

  test "filesystem journal reports invalid JSON and unsupported events", %{root: root} do
    {:ok, state} = JournalFileSystem.open("bad-journal", workflow: "flow", root: root)
    File.write!(state.path, "not json\n")

    assert {:error, %Error{type: :journal_error, reason: %{operation: :events}}} =
             JournalFileSystem.events(state)

    File.write!(state.path, JSON.encode!(%{"version" => 2}) <> "\n")

    assert {:error, %Error{type: :journal_error, reason: %{operation: :events}}} =
             JournalFileSystem.events(state)
  end

  @spec record(Job.t(), String.t(), non_neg_integer(), pos_integer(), integer()) :: Record.t()
  defp record(job, node, generation, attempt, raw) do
    at = job |> Job.at_generation(generation) |> Job.at_attempt(attempt)
    Record.new(%{job: at, node: node, status: :ok, result: Value.cast!(raw, IntegerType)})
  end

  @spec error_record(Job.t(), String.t(), non_neg_integer(), pos_integer()) :: Record.t()
  defp error_record(job, node, generation, attempt) do
    at = job |> Job.at_generation(generation) |> Job.at_attempt(attempt)
    Record.new(%{job: at, node: node, status: :error, result: %Error{type: :failed}})
  end

  @spec event(Job.t(), Event.kind(), String.t()) :: Event.t()
  defp event(job, kind, subject),
    do: Event.new(%{job: job, kind: kind, subject: subject, payload: %{"cursor" => "x"}})
end
