defmodule DomovoyCore.RuntimeTest do
  use ExUnit.Case, async: false

  alias DomovoyCore.Event
  alias DomovoyCore.Job
  alias DomovoyCore.Journal
  alias DomovoyCore.Runtime
  alias DomovoyCore.Test.Journal.Memory, as: MemoryJournal
  alias DomovoyCore.Test.Support
  alias DomovoyCore.Workflow.Server

  @left DomovoyCore.Test.RuntimeLeft
  @right DomovoyCore.Test.RuntimeRight

  test "requires a name and positive child limits" do
    assert_raise ArgumentError, fn -> Runtime.start_link([]) end
    assert_raise ArgumentError, fn -> Runtime.start_link(name: "runtime") end

    assert_raise ArgumentError, fn ->
      Runtime.start_link(name: DomovoyCore.Test.InvalidLimit, workflow_task_max_children: 0)
    end
  end

  test "child specs are unique per runtime name" do
    left = Runtime.child_spec(name: @left)
    right = Runtime.child_spec(name: @right)

    assert left.id == {Runtime, @left}
    assert right.id == {Runtime, @right}
    refute left.id == right.id
    assert left.type == :supervisor
  end

  test "starts isolated process children and has no application callback" do
    start_supervised!({Runtime, name: @left})

    assert Process.whereis(@left)
    assert Process.whereis(Runtime.pubsub(@left))
    assert Process.whereis(Runtime.workflow_registry(@left))
    assert Process.whereis(Runtime.engine_task_supervisor(@left))
    assert Process.whereis(Runtime.workflow_task_supervisor(@left))
    assert Process.whereis(Runtime.workflow_supervisor(@left))
    assert length(Supervisor.which_children(@left)) == 5
    assert Application.spec(:domovoy_core, :mod) in [nil, []]
    refute Keyword.has_key?(DomovoyCore.MixProject.application(), :mod)
  end

  test "named runtimes isolate pubsub and workflow registries" do
    start_supervised!({Runtime, name: @left})
    start_supervised!({Runtime, name: @right})

    job = Job.new("shared-id")
    event = Event.new(%{job: job, kind: :run_started, subject: "flow"})
    {:ok, left_journal} = Journal.open(@left, MemoryJournal, job.id, workflow: "flow")
    {:ok, right_journal} = Journal.open(@right, MemoryJournal, job.id, workflow: "flow")

    :ok = Phoenix.PubSub.subscribe(Runtime.pubsub(@left), Journal.topic("flow", job.id))
    assert Journal.append(left_journal, event) == :ok
    assert_receive {:domovoy_event, ^event}

    :ok = Phoenix.PubSub.subscribe(Runtime.pubsub(@right), Journal.topic("flow", job.id))
    refute_received {:domovoy_event, ^event}
    assert Journal.append(right_journal, event) == :ok
    assert_receive {:domovoy_event, ^event}

    workflow = Support.review_workflow(name: "left_flow")
    {:ok, left_server} = Server.start(@left, workflow, %{"base" => 1}, job: job)
    refute Server.whereis(@right, workflow.name, job.id)
    assert Server.whereis(@left, workflow.name, job.id) == left_server
    :ok = Server.stop(left_server)
  end
end
