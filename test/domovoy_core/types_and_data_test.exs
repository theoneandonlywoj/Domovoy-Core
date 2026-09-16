defmodule DomovoyCore.TypesAndDataTest do
  use ExUnit.Case, async: true

  alias DomovoyCore.Choice
  alias DomovoyCore.Error
  alias DomovoyCore.Event
  alias DomovoyCore.Job
  alias DomovoyCore.Record
  alias DomovoyCore.Retry
  alias DomovoyCore.Test.Type.Celsius
  alias DomovoyCore.Type
  alias DomovoyCore.Value

  test "built-in types cast strict values and reject other shapes" do
    assert Type.Integer.cast(42) == {:ok, 42}
    assert Type.Integer.cast("42") == :error
    assert Type.String.cast("") == {:ok, ""}
    assert Type.String.cast(42) == :error
    assert Type.Boolean.cast(false) == {:ok, false}
    assert Type.Boolean.cast(0) == :error
    assert Type.Map.cast(%{a: 1}) == {:ok, %{a: 1}}
    assert Type.Map.cast(a: 1) == :error
    assert Type.Any.cast({:ok, 1}) == {:ok, {:ok, 1}}
  end

  test "directory expands existing paths and reports missing paths" do
    assert Type.Directory.cast(".") == {:ok, File.cwd!()}
    assert {:error, path: path} = Type.Directory.cast("no-such-directory")
    assert Path.type(path) == :absolute
    assert Type.Directory.cast(42) == :error
  end

  test "custom types receive and produce metadata" do
    assert Celsius.cast(212) == {:ok, 212}

    assert Celsius.cast(212, %{"unit" => "fahrenheit"}) ==
             {:ok, 100, %{"unit" => "celsius"}}

    assert Value.cast(212, Celsius, %{"unit" => "fahrenheit", "source" => "test"}) ==
             {:ok,
              %Value{
                value: 100,
                type: Celsius,
                metadata: %{"unit" => "celsius", "source" => "test"}
              }}

    assert Type.type?(Celsius)
    refute Type.type?(DomovoyCore.Name)
    refute Type.type?("DomovoyCore.Type.String")
  end

  test "type document helpers preserve JSON values and reject opaque terms" do
    assert Type.document(%{state: :ready, nested: [%{ok?: true}]}) ==
             {:ok, %{"state" => "ready", "nested" => [%{"ok?" => true}]}}

    assert Type.document({:ok, 1}) == :error
    assert Type.atom_keys(%{"id" => "x", "other" => 1}, [:id]) == %{:id => "x", "other" => 1}
    assert Type.datetime("2026-09-13T10:00:00Z") == {:ok, ~U[2026-09-13 10:00:00Z]}
    assert Type.datetime("yesterday") == :error
    assert Type.load_each([1, 2], &{:ok, &1 * 2}) == {:ok, [2, 4]}
  end

  test "values cast, merge metadata, and redact failed raw values" do
    assert Value.cast(7, Type.Integer, %{"source" => "test"}) ==
             {:ok, %Value{value: 7, type: Type.Integer, metadata: %{"source" => "test"}}}

    assert Value.cast("secret", Type.Integer) ==
             {:error, %Error{type: :cast_error, reason: %{module: Type.Integer}}}

    error = assert_raise ArgumentError, fn -> Value.cast!("secret", Type.Integer) end
    refute Exception.message(error) =~ "secret"
  end

  test "values round-trip through JSON and reject invalid type documents" do
    value = Value.cast!(%{"count" => 1}, Type.Map, %{"source" => "test"})
    assert {:ok, document} = Value.dump(value)
    assert document |> JSON.encode!() |> JSON.decode!() |> Value.load() == {:ok, value}

    assert Value.load(%{document | "version" => 2}) == {:error, Error.unsupported_version(2)}

    assert Value.load(%{document | "type" => "Elixir.DomovoyCore.Name"}) ==
             {:error, Error.not_a_type("Elixir.DomovoyCore.Name")}

    tuple = Value.cast!({:ok, 1}, Type.Any)
    assert Value.dump(tuple) == {:error, Error.dump_error(Type.Any)}
  end

  test "choice values preserve targets and typed inputs on disk" do
    choice =
      Choice.new(%{
        name: "revise",
        description: "Again.",
        target: {:rerun, "prepare"},
        inputs: %{"reason" => Type.String},
        metadata: %{"shortcut" => "r"}
      })

    value = Value.cast!(choice, Type.Choice)
    assert {:ok, document} = Value.dump(value)
    assert document |> JSON.encode!() |> JSON.decode!() |> Value.load() == {:ok, value}
    assert Type.Choice.cast(%{choice | description: ""}) == :error
  end

  test "errors build safe messages and round-trip without leaking structs" do
    error = Error.new(%{type: :runner_failed, reason: {:exit, 1}, retryable?: true, path: "/x"})
    assert error.metadata == %{path: "/x"}
    assert Error.message(error) == "runner_failed: {:exit, 1}"

    document = error |> Error.dump() |> JSON.encode!() |> JSON.decode!()
    assert {:ok, loaded} = Error.load(document)
    assert loaded.type == :runner_failed
    assert loaded.retryable?

    secret = Value.cast!("api-key", Type.String)
    record = Record.new(%{job: Job.new("safe"), node: "value", status: :ok, result: secret})
    dumped = Error.dump(Error.new(%{type: :leak, reason: record, node: %DomovoyCore.Node{}}))
    assert dumped["reason"] == "DomovoyCore.Record"
    assert dumped["metadata"] == %{"node" => "DomovoyCore.Node"}
    refute JSON.encode!(dumped) =~ "api-key"
  end

  test "jobs validate names and advance generations and attempts" do
    job = Job.new("dom-30", %{"issue" => "DOM-30"})
    assert job == %Job{id: "dom-30", generation: 0, attempt: 1, metadata: %{"issue" => "DOM-30"}}
    assert job |> Job.at_attempt(3) |> Job.next_generation() == %Job{job | generation: 1}
    assert Job.at_generation(job, 2).generation == 2
    assert_raise ArgumentError, fn -> Job.new("not/a/name") end

    assert {:ok, document} = Job.dump(Job.at_attempt(job, 2))

    assert document |> JSON.encode!() |> JSON.decode!() |> Job.load() ==
             {:ok, Job.at_attempt(job, 2)}
  end

  test "records enforce status/result pairs, keys, and persistence" do
    job = Job.new("record") |> Job.at_generation(2) |> Job.at_attempt(3)
    value = Value.cast!(7, Type.Integer)
    record = Record.new(%{job: job, node: "sum", status: :ok, result: value})
    assert Record.key(record) == {"record", "sum", 2, 3}
    assert Record.ok?(record)

    assert {:ok, document} = Record.dump(record)
    assert document |> JSON.encode!() |> JSON.decode!() |> Record.load() == {:ok, record}

    failed = Record.new(%{job: job, node: "sum", status: :error, result: %Error{type: :bad}})
    assert {:ok, failed_document} = Record.dump(failed)

    assert {:ok, %Record{status: :error, result: %Error{type: :bad}}} =
             Record.load(failed_document)

    assert_raise ArgumentError, fn ->
      Record.new(%{job: job, node: "sum", status: :ok, result: %Error{type: :bad}})
    end
  end

  test "events accept known kinds and round-trip in order-safe documents" do
    job = Job.new("event")

    for kind <- Event.kinds() do
      assert %Event{kind: ^kind} = Event.new(%{job: job, kind: kind, subject: "subject"})
    end

    event =
      Event.new(%{
        job: job,
        kind: :decided,
        subject: "review",
        payload: %{"choice" => "approve"},
        at: ~U[2026-09-13 10:00:01.500000Z]
      })

    assert {:ok, document} = Event.dump(event)
    assert document |> JSON.encode!() |> JSON.decode!() |> Event.load() == {:ok, event}
    assert Event.load(%{document | "kind" => "unknown"}) == {:error, Error.load_error(Event)}
  end

  test "retry policies merge defaults and reject invalid limits" do
    defaults = %Retry{max_attempts: 4, backoff_ms: 20, timeout_ms: 100}
    assert Retry.new([max_attempts: 2], defaults) == %Retry{defaults | max_attempts: 2}
    assert Retry.new(%Retry{max_attempts: 2}, defaults) == %Retry{max_attempts: 2}

    for opts <- [[max_attempts: 0], [backoff_ms: -1], [timeout_ms: 0], [unknown: 1]] do
      assert_raise ArgumentError, fn -> Retry.new(opts) end
    end
  end
end
