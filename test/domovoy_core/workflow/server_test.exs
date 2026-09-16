defmodule DomovoyCore.Workflow.ServerTest do
  use ExUnit.Case, async: false

  alias DomovoyCore.Error
  alias DomovoyCore.Event
  alias DomovoyCore.Job
  alias DomovoyCore.Name
  alias DomovoyCore.Record
  alias DomovoyCore.Store
  alias DomovoyCore.Test.Support
  alias DomovoyCore.Value
  alias DomovoyCore.Workflow.Server

  @runtime DomovoyCore.Test.ServerRuntime

  setup do
    start_supervised!({DomovoyCore.Runtime, name: @runtime})
    :ok
  end

  test "starts, awaits a decision, answers, and finishes under the named runtime" do
    workflow = Support.review_workflow(name: "server_start")
    job = Job.new(Name.random())
    :ok = Server.subscribe(@runtime, workflow.name, job.id)
    {:ok, server} = Server.start(@runtime, workflow, %{"base" => 5}, job: job)

    assert_receive {:domovoy_event, %Event{kind: :decision_awaited, job: %Job{id: id}}}
                   when id == job.id,
                   2_000

    view = Support.await_state(server, :awaiting_decision)

    assert {view.status, view.cursor, view.generation, Server.busy?(server)} ==
             {:awaiting_decision, "review", 0, false}

    {:ok, store} = Store.open(workflow.store |> elem(0), job.id, workflow: workflow.name)
    {:ok, %Record{result: %Value{value: 5}}} = Store.get(store, "total", 0)

    assert {:ok, %{status: :ready, cursor: "finish"}} = Server.decide(server, "approve", %{})

    assert_receive {:domovoy_event, %Event{kind: :run_finished, job: %Job{id: finished}}}
                   when finished == job.id,
                   2_000

    view = Support.await_state(server, :finished)
    assert {view.status, view.cursor, Server.busy?(server)} == {:finished, nil, false}
    assert Server.whereis(@runtime, workflow.name, job.id) == server
    :ok = Server.stop(server)
  end

  test "returns the live owner for a second start with equal inputs" do
    workflow = Support.review_workflow(name: "server_idempotent")
    job = Job.new(Name.random())
    {:ok, first} = Server.start(@runtime, workflow, %{"base" => 2}, job: job)
    {:ok, second} = Server.start(@runtime, workflow, %{"base" => 2}, job: job)
    assert first == second

    assert {:error, %Error{type: :run_input_mismatch}} =
             Server.start(@runtime, workflow, %{"base" => 9}, job: job)

    :ok = Server.stop(first)
  end

  test "resume of a non-durable run after stop is refused" do
    workflow = Support.review_workflow(name: "server_not_durable")
    job = Job.new(Name.random())
    {:ok, server} = Server.start(@runtime, workflow, %{"base" => 1}, job: job)
    Support.await_state(server, :awaiting_decision)
    :ok = Server.stop(server)

    assert {:error, %Error{type: :run_not_durable}} =
             Server.resume(@runtime, workflow, job.id)
  end

  test "resume of a filesystem run continues from journaled state" do
    root = Support.temporary_root("server")
    on_exit(fn -> File.rm_rf(root) end)
    workflow = Support.filesystem_workflow(root)
    job = Job.new(Name.random())
    :ok = Server.subscribe(@runtime, workflow.name, job.id)
    {:ok, server} = Server.start(@runtime, workflow, %{"base" => 4}, job: job)
    Support.await_state(server, :awaiting_decision)
    :ok = Server.stop(server)

    {:ok, resumed} = Server.resume(@runtime, workflow, job.id)
    view = Support.await_state(resumed, :awaiting_decision)
    assert {view.status, view.cursor, view.generation} == {:awaiting_decision, "review", 0}
    :ok = Server.stop(resumed)
  end

  test "stop is idempotent and decide is refused while busy" do
    workflow = Support.review_workflow(name: "server_stop")
    job = Job.new(Name.random())
    {:ok, server} = Server.start(@runtime, workflow, %{"base" => 1}, job: job)
    assert Server.stop(server) == :ok
    assert Server.stop(server) == :ok
  end

  test "emits workflow telemetry for start and decide" do
    parent = self()
    handler = :"server-telemetry-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach_many(
        handler,
        [
          [:domovoy_core, :workflow, :start, :stop],
          [:domovoy_core, :workflow, :decide, :stop]
        ],
        fn event, _measurements, metadata, _config ->
          send(parent, {event, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    workflow = Support.review_workflow(name: "server_telemetry")
    job = Job.new(Name.random())
    {:ok, server} = Server.start(@runtime, workflow, %{"base" => 1}, job: job)
    Support.await_state(server, :awaiting_decision)
    assert_receive {[:domovoy_core, :workflow, :start, :stop], %{run_id: id}} when id == job.id
    assert {:ok, _} = Server.decide(server, "stop", %{})
    Support.await_state(server, :finished)
    assert_receive {[:domovoy_core, :workflow, :decide, :stop], %{outcome: :finished}}
    :ok = Server.stop(server)
  end
end
