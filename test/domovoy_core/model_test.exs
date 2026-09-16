defmodule DomovoyCore.ModelTest do
  use ExUnit.Case, async: true

  alias DomovoyCore.Arrow
  alias DomovoyCore.Binding
  alias DomovoyCore.Choice
  alias DomovoyCore.Context
  alias DomovoyCore.Decider.Person
  alias DomovoyCore.Decision
  alias DomovoyCore.Engine.Order
  alias DomovoyCore.Error
  alias DomovoyCore.Graph
  alias DomovoyCore.Node
  alias DomovoyCore.Retry
  alias DomovoyCore.Runner
  alias DomovoyCore.Stage
  alias DomovoyCore.Test.AlwaysApproveDecider
  alias DomovoyCore.Test.Journal.Memory, as: MemoryJournal
  alias DomovoyCore.Test.Runner.Extra
  alias DomovoyCore.Test.Runner.Sum
  alias DomovoyCore.Test.Runner.Typed
  alias DomovoyCore.Test.Store.Memory, as: MemoryStore
  alias DomovoyCore.Test.Support
  alias DomovoyCore.Test.Validator.Positive
  alias DomovoyCore.Type
  alias DomovoyCore.Value
  alias DomovoyCore.Vertex
  alias DomovoyCore.Workflow
  alias Ecto.Changeset

  test "runner DSL exposes schema, requirements, validators, retries, and extras" do
    assert Typed.__domovoy_core__(:input) == Typed.Input
    assert Typed.Input.__schema__(:primary_key) == []
    assert Typed.Input.__schema__(:type, :count) == Type.Integer
    assert Typed.__domovoy_core__(:required) == [:count, :label]
    assert Typed.__domovoy_core__(:validators) == [Positive]

    assert Typed.__domovoy_core__(:retry) == %Retry{
             max_attempts: 3,
             backoff_ms: 5,
             timeout_ms: 500
           }

    refute Typed.__domovoy_core__(:extra?)
    assert Extra.__domovoy_core__(:extra?)
    assert Extra.Input.__schema__(:type, :extra) == Type.Map
  end

  test "runner changesets cast fields, apply defaults, and enforce required values" do
    changeset = Runner.changeset(Typed, %{"count" => 3, payload: false})
    assert changeset.valid?

    assert %Typed.Input{count: 3, label: "items", payload: false} =
             Changeset.apply_changes(changeset)

    for params <- [%{}, %{count: nil}, %{count: 1, label: "  "}] do
      refute Runner.changeset(Typed, params).valid?
    end

    invalid = Runner.changeset(Typed, %{count: "3", label: 7})
    assert invalid.errors[:count] == {"is invalid", validation: :cast, type: Type.Integer}
    assert invalid.errors[:label] == {"is invalid", validation: :cast, type: Type.String}
  end

  test "runner changesets reject unknown and duplicate keys without creating atoms" do
    key = "domovoy_unknown_#{System.unique_integer([:positive])}"
    assert_raise ArgumentError, fn -> String.to_existing_atom(key) end

    unknown = Runner.changeset(Typed, %{key => "secret", count: 1})
    refute unknown.valid?
    refute inspect(unknown.errors) =~ "secret"

    duplicate = Runner.changeset(Typed, %{:count => 1, "count" => 2})
    assert duplicate.errors[:count] == {"has duplicate parameters", []}

    extra = Runner.changeset(Extra, %{key => "kept", count: 2})
    assert %Extra.Input{count: 2, extra: %{^key => "kept"}} = Changeset.apply_changes(extra)
    assert_raise ArgumentError, fn -> String.to_existing_atom(key) end
  end

  test "validators retain casts and add context-sensitive diagnostics" do
    changeset = Runner.changeset(Typed, %{count: 3})
    checked = Positive.validate(changeset, %Context{metadata: %{"minimum" => 5}})
    refute checked.valid?

    assert checked.errors[:count] ==
             {"must be greater than %{number}",
              validation: :number, kind: :greater_than, number: 5}

    assert DomovoyCore.Validator.behaviour_info(:callbacks) == [validate: 2]
  end

  test "nodes normalize bindings and literals and merge retry defaults" do
    node =
      Node.new(%{
        name: "sum",
        runner: Sum,
        type: Type.Integer,
        bind: %{a: {"first", Type.Integer}},
        args: %{b: {2, Type.Integer}},
        after: ["ready"],
        retry: [max_attempts: 2],
        metadata: %{"role" => "test"},
        store?: false
      })

    assert node.bind.a == %Binding{from: "first", type: Type.Integer, metadata: %{}}
    assert node.args.b == {2, Type.Integer}
    assert node.after == ["ready"]
    assert node.retry.max_attempts == 2
    assert Node.get_metadata(node, "role") == "test"
    refute Node.store?(node)
  end

  test "nodes reject untyped values, invalid sources, and schema type mismatches" do
    base = %{name: "sum", runner: Sum, type: Type.Integer}

    assert_raise ArgumentError, fn -> Node.new(Map.put(base, :args, %{a: "secret"})) end

    assert_raise ArgumentError, fn ->
      Node.new(Map.put(base, :bind, %{a: {"../bad", Type.Integer}}))
    end

    assert_raise ArgumentError, fn ->
      Node.new(Map.put(base, :args, %{a: {"wrong", Type.String}}))
    end
  end

  test "arrows derive dependencies and adjacency maps" do
    target =
      Node.new(%{
        name: "target",
        runner: Sum,
        type: Type.Integer,
        bind: %{a: {"first", Type.Integer}, b: {"second", Type.Integer}}
      })

    assert MapSet.new(Arrow.from_node(target)) ==
             MapSet.new([Arrow.new("first", "target"), Arrow.new("second", "target")])

    arrows = Arrow.from_node(target) ++ [Arrow.new("target", "last")]
    assert Enum.sort(Arrow.predecessors(arrows)["target"]) == ["first", "second"]
    assert Arrow.successors(arrows)["target"] == ["last"]
  end

  test "graphs derive external inputs and deterministic topology" do
    graph =
      Graph.new([
        Support.node("d", %{a: {"b", Type.Integer}, b: {"c", Type.Integer}}),
        Support.node("c", %{a: {"a", Type.Integer}}),
        Support.node("b", %{a: {"a", Type.Integer}}),
        Support.node("a")
      ])

    assert Order.waves(graph) == {:ok, [["a"], ["b", "c"], ["d"]]}
    assert Order.order(graph) == {:ok, ["a", "b", "c", "d"]}

    external = Graph.new([Support.node("read", %{text: {"input", Type.String}})])
    assert external.inputs == %{"input" => Type.String}
    assert Order.waves(external) == {:ok, [["read"]]}
  end

  test "graphs reject duplicate names, cycles, missing control sources, and type conflicts" do
    %Node{} = a = Support.node("a")
    assert %Error{type: :duplicate_node_name} = Graph.new([a, a])

    cyclic =
      Graph.new([
        Support.node("a", %{a: {"b", Type.Integer}}),
        Support.node("b", %{a: {"a", Type.Integer}})
      ])

    assert %Error{type: :graph_has_cycle} = cyclic

    after_missing = %Node{a | name: "controlled", after: ["missing"]}
    assert %Error{type: :after_source_not_found} = Graph.new([after_missing])

    source = %Node{a | name: "source", type: Type.Integer}
    consumer = Support.node("consumer", %{text: {"source", Type.String}})
    assert %Error{type: :binding_type_mismatch} = Graph.new([source, consumer])
  end

  test "choices, decisions, and vertices expose control-flow semantics" do
    run = Choice.new(%{name: "go", description: "Go.", target: {:run, "finish"}})
    rerun = Choice.new(%{name: "again", description: "Again.", target: {:rerun, "prepare"}})
    halt = Choice.new(%{name: "stop", description: "Stop.", target: :halt})
    decision = Decision.new(%{name: "review", prompt: "Continue?", choices: [run, rerun, halt]})

    assert decision.decider == Person
    assert Person.decide(decision, %Context{}, []) == :await
    assert Enum.sort(Decision.choice_names(decision)) == ["again", "go", "stop"]
    assert Decision.target(decision, "again") == {:rerun, "prepare"}
    assert %Value{value: ^halt, type: Type.Choice} = Decision.answer(decision, "stop")
    assert %Error{type: :choice_not_offered} = Decision.choice(decision, "missing")
    assert Choice.rerun?(rerun)
    assert Choice.target_vertex(halt) == nil
    assert Vertex.kind(decision) == :decision
    assert Enum.sort(Vertex.targets(decision)) == ["finish", "prepare"]
  end

  test "deciders may be configured modules with options" do
    choice = Choice.new(%{name: "approve", description: "Go.", target: :halt})

    decision =
      Decision.new(%{
        name: "review",
        prompt: "Continue?",
        choices: [choice],
        decider: {AlwaysApproveDecider, marker: :test}
      })

    assert Decision.decider_parts(decision) == {AlwaysApproveDecider, marker: :test}
    assert AlwaysApproveDecider.decide(decision, %Context{}, marker: :test) == {:ok, "approve"}
    assert DomovoyCore.Decider.behaviour_info(:callbacks) == [decide: 3]
  end

  test "stages expose graph inputs and one optional successor" do
    graph = Graph.new([Support.node("sum", %{a: {"base", Type.Integer}})])
    stage = Stage.new(%{name: "prepare", graph: graph, next: "review", metadata: %{"x" => 1}})
    assert Stage.inputs(stage) == %{"base" => Type.Integer}
    assert Vertex.name(stage) == "prepare"
    assert Vertex.kind(stage) == :stage
    assert Vertex.targets(stage) == ["review"]
    assert Vertex.graph(stage) == graph

    assert_raise ArgumentError, fn ->
      Stage.new(%{name: "split", graph: graph, next: ["a", "b"]})
    end
  end

  test "workflow validates vertices, inputs, adapters, and graph dataflow" do
    workflow = Support.review_workflow()
    assert workflow.inputs == %{"base" => %{type: Type.Integer, default: 1}}
    assert Workflow.stage?(workflow, "prepare")
    assert Workflow.decision?(workflow, "review")
    assert Workflow.vertex(workflow, "finish").name == "finish"
    assert workflow.store == {DomovoyCore.Test.Store.Memory, []}
    assert workflow.journal == {DomovoyCore.Test.Journal.Memory, []}

    assert Workflow.new(%{
             name: workflow.name,
             vertices: workflow.vertices,
             start: "missing",
             inputs: %{"base" => [type: Type.Integer]},
             store: MemoryStore,
             journal: MemoryJournal
           }) == Error.vertex_not_in_workflow("missing", workflow.name)

    assert Workflow.new(%{
             name: "not a name",
             vertices: workflow.vertices,
             start: "prepare",
             inputs: %{"base" => [type: Type.Integer]},
             store: MemoryStore,
             journal: MemoryJournal
           }) == Error.invalid_workflow_name("not a name")

    assert %Error{type: :not_an_adapter} =
             Workflow.new(%{
               name: workflow.name,
               vertices: workflow.vertices,
               start: "prepare",
               inputs: %{"base" => [type: Type.Integer]},
               store: Graph,
               journal: MemoryJournal
             })
  end
end
