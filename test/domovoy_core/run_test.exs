defmodule DomovoyCore.RunTest do
  use ExUnit.Case, async: false

  alias DomovoyCore.Error
  alias DomovoyCore.Event
  alias DomovoyCore.Job
  alias DomovoyCore.Journal
  alias DomovoyCore.Record
  alias DomovoyCore.Run
  alias DomovoyCore.Store
  alias DomovoyCore.Test.Support
  alias DomovoyCore.Value

  @runtime DomovoyCore.Test.RunRuntime

  setup do
    start_supervised!({DomovoyCore.Runtime, name: @runtime})
    :ok
  end

  test "starts, awaits a person, then finishes after an approved decision" do
    workflow = Support.review_workflow()
    job = Job.new("tutorial-1")
    run = Run.start(@runtime, workflow, %{"base" => 5}, job: job)

    assert {run.status, run.cursor, run.job.generation, run.runtime} ==
             {:ready, "prepare", 0, @runtime}

    run = Run.run_to_decision(workflow, run)
    assert {run.status, run.cursor} == {:awaiting_decision, "review"}
    {:ok, %Record{result: %Value{value: 5}}} = Store.get(run.store, "total", 0)

    refused = Run.decide(workflow, run, "missing", %{})
    assert {refused.status, refused.error.type} == {:awaiting_decision, :choice_not_offered}

    run = Run.decide(workflow, run, "approve", %{})
    run = Run.run_to_decision(workflow, run)
    assert {run.status, run.cursor} == {:finished, nil}

    {:ok, events} = Journal.events(run.journal)

    assert Enum.map(events, & &1.kind) == [
             :run_started,
             :stage_started,
             :node_started,
             :node_finished,
             :stage_finished,
             :decision_awaited,
             :decided,
             :stage_started,
             :stage_finished,
             :run_finished
           ]
  end

  test "reruns raise generation and write choice inputs at the new generation" do
    workflow = Support.review_workflow()
    run = Run.start(@runtime, workflow, %{"base" => 7}, job: Job.new("tutorial-2"))
    run = Run.run_to_decision(workflow, run)
    run = Run.decide(workflow, run, "revise", %{"base" => 10})
    assert {run.status, run.cursor, run.job.generation} == {:ready, "prepare", 1}

    run = Run.run_to_decision(workflow, run)
    {:ok, first} = Store.get(run.store, "total", 0)
    {:ok, second} = Store.get(run.store, "total", 1)
    assert {first.result.value, second.result.value} == {7, 10}
  end

  test "halt finishes the run and journals run_halted" do
    workflow = Support.review_workflow()
    run = Run.start(@runtime, workflow, %{"base" => 3}, job: Job.new("tutorial-3"))
    run = Run.run_to_decision(workflow, run)
    run = Run.decide(workflow, run, "stop", %{})
    {:ok, events} = Journal.events(run.journal)
    assert {run.status, List.last(events).kind} == {:finished, :run_halted}
  end

  test "replays journaled state through a named runtime" do
    workflow = Support.review_workflow()
    started = Run.start(@runtime, workflow, %{"base" => 4}, job: Job.new("replay-1"))
    started = Run.run_to_decision(workflow, started)
    replayed = Run.replay(@runtime, workflow, started.job.id)

    assert {replayed.status, replayed.cursor, replayed.runtime} ==
             {:awaiting_decision, "review", @runtime}
  end

  test "apply folds events without I/O" do
    job = Job.new("snapshot")

    snapshot =
      Run.apply(
        %Run{job: job},
        Event.new(%{
          job: job,
          kind: :run_started,
          subject: "review_workflow",
          payload: %{"cursor" => "prepare"}
        })
      )

    assert {snapshot.workflow, snapshot.status, snapshot.cursor} ==
             {"review_workflow", :ready, "prepare"}
  end

  test "rerun limits fail the run without changing the stored generation" do
    workflow = Support.review_workflow()

    run =
      Run.start(@runtime, workflow, %{"base" => 1},
        job: Job.new("limit"),
        max_generations: 1
      )

    run = Run.run_to_decision(workflow, run)
    run = Run.decide(workflow, run, "revise", %{"base" => 2})
    run = Run.run_to_decision(workflow, run)
    failed = Run.decide(workflow, run, "revise", %{"base" => 3})
    assert failed.status == :failed
    assert failed.error.type == :rerun_limit
    assert failed.job.generation == 1
  end

  test "unknown workflow inputs fail start without opening adapters" do
    workflow = Support.review_workflow()
    run = Run.start(@runtime, workflow, %{"secret" => 1}, job: Job.new("bad-input"))
    assert run.status == :failed
    assert %Error{type: :invalid_workflow_input} = run.error
    assert run.store == nil
  end
end
