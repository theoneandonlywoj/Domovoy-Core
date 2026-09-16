defmodule DomovoyCore.Error do
  @moduledoc """
  The one error struct of the DomovoyCore core.

  An error has four fields:

    * `type` — an atom that names what failed, such as `:cast_error` or
      `:graph_has_cycle`. Every constructor sets it. A caller matches on the
      type and does not read a message.
    * `reason` — a term that says why. For an error of this module it is a
      map of names, such as `%{node_name: "double", dependency_name: "count"}`.
      A runner may put a string or the `errors` of a changeset there.
    * `retryable?` — `true` when a later attempt may succeed. The default is
      `false`.
     * `metadata` — a map with string keys that the core never reads. A UI
       reads it. Each constructor of this module leaves it empty.

  ## The redaction rule

  `reason` and `metadata` hold names: the name of a node, of a field, of a
  dependency, a type module, a path, the `errors` of a changeset. They never
  hold an input struct, a resolved parameter, a `DomovoyCore.Value` or a config
  map. An error names what failed and never carries the value that failed.
  Therefore a failed run with an API key among its inputs writes that key to
  no file.

  A constructor that gets a value keeps what names it. `cast_error/3` keeps
  the type module and, for a map, the keys of the map. Every later
  constructor follows the same rule.

  ## `new/1`

  `new/1` takes a map. It lifts `:type`, `:reason` and `:retryable?` into the
  fields of the struct. Any other key of the map goes into `metadata` as it
  is. That is the shape the runners and the plugin error modules built before
  the fields existed. They move their names into `reason` in later steps, and
  from then on `new/1` puts nothing into `metadata`.
  """

  alias DomovoyCore.Error
  alias DomovoyCore.Graph
  alias DomovoyCore.Node
  alias DomovoyCore.Type
  alias DomovoyCore.Vertex

  @enforce_keys [:type]
  defstruct type: nil,
            reason: nil,
            retryable?: false,
            metadata: %{}

  @typedoc "An error with a type, a reason, a retry flag and opaque metadata."
  @type t() :: %Error{
          type: atom(),
          reason: term(),
          retryable?: boolean(),
          metadata: map()
        }

  @fields [:type, :reason, :retryable?, :metadata]

  @doc """
  Creates a new `DomovoyCore.Error` from `fields`.

  `:type` is required. `:reason` defaults to `nil` and `:retryable?` to
  `false`. Any other key goes into `metadata`; see the module documentation.

  ## Examples

      DomovoyCore.Error.new(%{type: :runner_failed, reason: "exit 1"})
      %DomovoyCore.Error{type: :runner_failed, reason: "exit 1"}

      DomovoyCore.Error.new(%{type: :timeout, retryable?: true})
      %DomovoyCore.Error{type: :timeout, retryable?: true}

      DomovoyCore.Error.new(%{type: :runner_failed, node_name: "sum"})
      %DomovoyCore.Error{type: :runner_failed, metadata: %{node_name: "sum"}}
  """
  @spec new(fields :: map()) :: Error.t()
  def new(%{type: type} = fields) when is_atom(type) do
    {known, rest} = Map.split(fields, @fields)

    %Error{
      type: type,
      reason: Map.get(known, :reason),
      retryable?: Map.get(known, :retryable?, false),
      metadata: known |> Map.get(:metadata, %{}) |> Map.merge(rest)
    }
  end

  @doc """
  Renders `type` and `reason` as one line of text, for a log or a message to
  a person.

  ## Examples

      DomovoyCore.Error.message(DomovoyCore.Error.graph_has_cycle(["a", "b"]))
      ~s(graph_has_cycle: %{node: ["a", "b"]})

      DomovoyCore.Error.message(DomovoyCore.Error.new(%{type: :timeout, retryable?: true}))
      "timeout"
  """
  @spec message(error :: Error.t()) :: String.t()
  def message(%Error{type: type, reason: nil}), do: Atom.to_string(type)
  def message(%Error{type: type, reason: reason}), do: "#{type}: #{inspect(reason)}"

  @doc """
  Builds a `cast_error` error for a value that `module` refused.

  The error keeps the type module and, when the value is a map, the sorted
  keys of the map. It never keeps the value. A config map that a type refused
  may hold an API key, and an error travels to a log and to a file. `details`
  is the keyword that the type gave with `{:error, keyword}`. It holds names,
  paths and keys, and each entry goes into `reason`.

  ## Examples

      DomovoyCore.Error.cast_error("not an int", DomovoyCore.Type.Integer)
      %DomovoyCore.Error{type: :cast_error, reason: %{module: DomovoyCore.Type.Integer}}

      DomovoyCore.Error.cast_error(
        %{"api_key" => "lin_api_secret", "team" => "DOM"},
        DomovoyCore.Type.Map
      )
      %DomovoyCore.Error{
        type: :cast_error,
        reason: %{module: DomovoyCore.Type.Map, keys: ["api_key", "team"]}
      }

      DomovoyCore.Error.cast_error("/no/such/dir", DomovoyCore.Type.Directory, path: "/no/such/dir")
      %DomovoyCore.Error{
        type: :cast_error,
        reason: %{module: DomovoyCore.Type.Directory, path: "/no/such/dir"}
      }
  """
  @spec cast_error(raw_value :: any(), module :: module(), details :: keyword()) :: Error.t()
  def cast_error(raw_value, module, details \\ []) when is_atom(module) and is_list(details) do
    reason = %{module: module} |> Map.merge(keys(raw_value)) |> Map.merge(Map.new(details))

    %Error{type: :cast_error, reason: reason}
  end

  @doc """
  Builds an error when a document holds a `"version"` that `DomovoyCore.Value.load/1`
  does not know.

  ## Examples

      DomovoyCore.Error.unsupported_version(2)
      %DomovoyCore.Error{type: :unsupported_version, reason: %{version: 2, supported: [1]}}
  """
  @spec unsupported_version(version :: any()) :: Error.t()
  def unsupported_version(version) do
    %Error{type: :unsupported_version, reason: %{version: version, supported: [1]}}
  end

  @doc """
  Builds an error when a document names a module that is not loaded or that
  does not implement `DomovoyCore.Type`.

  ## Examples

      DomovoyCore.Error.not_a_type("Elixir.DomovoyCore.Name")
      %DomovoyCore.Error{type: :not_a_type, reason: %{module: "Elixir.DomovoyCore.Name"}}
  """
  @spec not_a_type(module_name :: String.t()) :: Error.t()
  def not_a_type(module_name) do
    %Error{type: :not_a_type, reason: %{module: module_name}}
  end

  @doc """
  Builds an error when `load/1` of a type refuses the stored value.

  ## Examples

      DomovoyCore.Error.load_error(DomovoyCore.Type.Map)
      %DomovoyCore.Error{type: :load_error, reason: %{module: DomovoyCore.Type.Map}}
  """
  @spec load_error(module :: module()) :: Error.t()
  def load_error(module) do
    %Error{type: :load_error, reason: %{module: module}}
  end

  @doc """
  Builds an error when `dump/1` of a type refuses the value.

  ## Examples

      DomovoyCore.Error.dump_error(DomovoyCore.Type.Map)
      %DomovoyCore.Error{type: :dump_error, reason: %{module: DomovoyCore.Type.Map}}
  """
  @spec dump_error(module :: module()) :: Error.t()
  def dump_error(module) do
    %Error{type: :dump_error, reason: %{module: module}}
  end

  @doc """
  Builds an error when the `store` or the `journal` of a workflow names a
  module that does not implement `behaviour`.

  ## Examples

      DomovoyCore.Error.not_an_adapter(DomovoyCore.Type.Map, DomovoyCore.Store, "issue_to_pr")
      %DomovoyCore.Error{
        type: :not_an_adapter,
        reason: %{module: DomovoyCore.Type.Map, behaviour: DomovoyCore.Store, workflow: "issue_to_pr"}
      }
  """
  @spec not_an_adapter(module :: module(), behaviour :: module(), workflow_name :: String.t()) ::
          Error.t()
  def not_an_adapter(module, behaviour, workflow_name) do
    %Error{
      type: :not_an_adapter,
      reason: %{module: module, behaviour: behaviour, workflow: workflow_name}
    }
  end

  @doc """
  Builds an error when a store adapter cannot do `operation`.

  `cause` names what went wrong: a posix atom, a path, or the error of a
  document. It never holds a record or a value.

  ## Examples

      DomovoyCore.Error.store_error(DomovoyCore.Store.FileSystem, :put, :enoent)
      %DomovoyCore.Error{
        type: :store_error,
        reason: %{module: DomovoyCore.Store.FileSystem, operation: :put, cause: :enoent}
      }
  """
  @spec store_error(module :: module(), operation :: atom(), cause :: any()) :: Error.t()
  def store_error(module, operation, cause) do
    %Error{type: :store_error, reason: %{module: module, operation: operation, cause: cause}}
  end

  @doc """
  Builds an error when a journal adapter cannot do `operation`.

  `cause` names what went wrong, as in `store_error/3`.

  ## Examples

      DomovoyCore.Error.journal_error(DomovoyCore.Journal.FileSystem, :append, :eacces)
      %DomovoyCore.Error{
        type: :journal_error,
        reason: %{module: DomovoyCore.Journal.FileSystem, operation: :append, cause: :eacces}
      }
  """
  @spec journal_error(module :: module(), operation :: atom(), cause :: any()) :: Error.t()
  def journal_error(module, operation, cause) do
    %Error{type: :journal_error, reason: %{module: module, operation: operation, cause: cause}}
  end

  @doc """
  Translates `error` to the map that a record or an event document holds.

  The map has string keys and holds only what JSON can hold. An atom becomes
  a string. A tuple becomes a list. A keyword list becomes an object. A map
  gets string keys. A nested `DomovoyCore.Error` becomes its own map. Any other
  struct becomes the name of its module, so a value that a constructor kept
  by mistake never reaches a file. `dump/1` never fails.

  ## Examples

      DomovoyCore.Error.dump(DomovoyCore.Error.cast_error("x", DomovoyCore.Type.Integer))
      %{
        "type" => "cast_error",
        "reason" => %{"module" => "Elixir.DomovoyCore.Type.Integer"},
        "retryable?" => false,
        "metadata" => %{}
      }

      error = DomovoyCore.Error.new(%{type: :leak, reason: {:input, %DomovoyCore.Job{}}})
      DomovoyCore.Error.dump(error)["reason"]
      ["input", "DomovoyCore.Job"]
  """
  @spec dump(error :: Error.t()) :: %{String.t() => any()}
  def dump(%Error{type: type, reason: reason, retryable?: retryable?, metadata: metadata}) do
    %{
      "type" => Atom.to_string(type),
      "reason" => document(reason),
      "retryable?" => retryable?,
      "metadata" => document(metadata)
    }
  end

  @doc """
  Translates a map that `dump/1` gave back to a `DomovoyCore.Error`.

  `type` comes back as an atom. `reason` and `metadata` come back as the
  document holds them, so an atom that `dump/1` wrote is a string here. A
  `"type"` that names no atom of this VM gives `load_error/1`.

  ## Examples

      DomovoyCore.Error.load(%{"type" => "timeout", "reason" => nil, "retryable?" => true})
      {:ok, %DomovoyCore.Error{type: :timeout, retryable?: true}}

      DomovoyCore.Error.load(%{"type" => "no_such_error_type_anywhere"})
      {:error, %DomovoyCore.Error{type: :load_error, reason: %{module: DomovoyCore.Error}}}
  """
  @spec load(document :: any()) :: {:ok, Error.t()} | {:error, Error.t()}
  def load(%{"type" => type} = document) when is_binary(type) do
    {:ok,
     %Error{
       type: String.to_existing_atom(type),
       reason: Map.get(document, "reason"),
       retryable?: Map.get(document, "retryable?", false),
       metadata: Map.get(document, "metadata", %{})
     }}
  rescue
    ArgumentError -> {:error, load_error(Error)}
  end

  def load(_document), do: {:error, load_error(Error)}

  @spec document(term :: any()) :: any()
  defp document(%Error{} = error), do: dump(error)
  defp document(%module{}), do: module |> Atom.to_string() |> String.replace_prefix("Elixir.", "")
  defp document(term) when is_boolean(term) or is_nil(term), do: term
  defp document(term) when is_atom(term), do: Atom.to_string(term)
  defp document(term) when is_tuple(term), do: term |> Tuple.to_list() |> document()
  defp document(term) when is_map(term), do: Map.new(term, &document_entry/1)

  defp document(term) when is_list(term) do
    if Keyword.keyword?(term) and term != [],
      do: Map.new(term, &document_entry/1),
      else: Enum.map(term, &document/1)
  end

  defp document(term), do: term

  @spec document_entry(entry :: {any(), any()}) :: {String.t(), any()}
  defp document_entry({key, value}) when is_binary(key), do: {key, document(value)}
  defp document_entry({key, value}) when is_atom(key), do: {Atom.to_string(key), document(value)}
  defp document_entry({key, value}), do: {inspect(key), document(value)}

  @doc """
  Builds a `type_mismatch` error when a dependency record has the wrong value type.

  The reason names the node that received the record, the dependency that
  supplied it, the type the node expects for that dependency, and the type the
  record holds.

  ## Examples

      DomovoyCore.Error.type_mismatch(
        "double",
        "count",
        DomovoyCore.Type.Integer,
        DomovoyCore.Type.String
      )
      %DomovoyCore.Error{
        type: :type_mismatch,
        reason: %{
          node_name: "double",
          dependency_name: "count",
          expected_type: DomovoyCore.Type.Integer,
          actual_type: DomovoyCore.Type.String
        }
      }
  """
  @spec type_mismatch(
          node_name :: Node.name(),
          dependency_name :: Node.name(),
          expected_type :: Type.t(),
          actual_type :: Type.t() | nil
        ) :: Error.t()
  def type_mismatch(node_name, dependency_name, expected_type, actual_type) do
    %Error{
      type: :type_mismatch,
      reason: %{
        node_name: node_name,
        dependency_name: dependency_name,
        expected_type: expected_type,
        actual_type: actual_type
      }
    }
  end

  @doc """
  Builds an error when a graph holds a cycle.

  `remaining_names` are the nodes that `DomovoyCore.Engine.Order` could not put in
  the order. Each of them waits for another node in the list.

  ## Examples

      DomovoyCore.Error.graph_has_cycle(["a", "b"])
      %DomovoyCore.Error{type: :graph_has_cycle, reason: %{node: ["a", "b"]}}
  """
  @spec graph_has_cycle(remaining_names :: [Node.name()]) :: Error.t()
  def graph_has_cycle(remaining_names) when is_list(remaining_names) do
    %Error{type: :graph_has_cycle, reason: %{node: Enum.sort(remaining_names)}}
  end

  @doc """
  Builds an error when a graph names a dependency that nothing gives.

  The Engine gives this error when neither the caller nor the store holds a
  record for `node_name`. The reason holds the names of the nodes and the
  inputs of the graph, so a reader sees what the graph does hold.

  ## Examples

      graph = DomovoyCore.Graph.new([
        DomovoyCore.Node.new(%{
          name: "double",
          runner: MyApp.Runner.Delay,
          type: DomovoyCore.Type.Integer,
          bind: %{min_delay_ms: {"count", DomovoyCore.Type.Integer}}
        })
      ])
      DomovoyCore.Error.node_not_in_graph("count", graph)
      %DomovoyCore.Error{
        type: :node_not_in_graph,
        reason: %{node_name: "count", node_names: ["double"], inputs: ["count"]}
      }
  """
  @spec node_not_in_graph(node_name :: Node.name(), graph :: Graph.t()) :: Error.t()
  def node_not_in_graph(node_name, %Graph{} = graph) do
    %Error{
      type: :node_not_in_graph,
      reason: %{
        node_name: node_name,
        node_names: graph.nodes_by_name |> Map.keys() |> Enum.sort(),
        inputs: graph.inputs |> Map.keys() |> Enum.sort()
      }
    }
  end

  @doc """
  Builds an error when a workflow names a vertex that it does not hold.

  ## Examples

      DomovoyCore.Error.vertex_not_in_workflow("review", "issue_to_pr")
      %DomovoyCore.Error{
        type: :vertex_not_in_workflow,
        reason: %{vertex_name: "review", workflow_name: "issue_to_pr"}
      }
  """
  @spec vertex_not_in_workflow(vertex_name :: Vertex.name(), workflow_name :: String.t()) ::
          Error.t()
  def vertex_not_in_workflow(vertex_name, workflow_name) do
    %Error{
      type: :vertex_not_in_workflow,
      reason: %{vertex_name: vertex_name, workflow_name: workflow_name}
    }
  end

  @doc """
  Builds an error when the key of a vertex in a workflow is not the name of
  that vertex.

  ## Examples

      DomovoyCore.Error.vertex_name_mismatch("plan", "prepare", "issue_to_pr")
      %DomovoyCore.Error{
        type: :vertex_name_mismatch,
        reason: %{key: "plan", vertex_name: "prepare", workflow_name: "issue_to_pr"}
      }
  """
  @spec vertex_name_mismatch(
          key :: Vertex.name(),
          vertex_name :: Vertex.name(),
          workflow_name :: String.t()
        ) :: Error.t()
  def vertex_name_mismatch(key, vertex_name, workflow_name) do
    %Error{
      type: :vertex_name_mismatch,
      reason: %{key: key, vertex_name: vertex_name, workflow_name: workflow_name}
    }
  end

  @doc """
  Builds an error when the name of a workflow is not a `DomovoyCore.Name`.

  The name of a workflow becomes a directory name in a store, so it holds
  letters, digits, `_` and `-` only.

  ## Examples

      DomovoyCore.Error.invalid_workflow_name("issue to pr")
      %DomovoyCore.Error{type: :invalid_workflow_name, reason: %{name: "issue to pr"}}
  """
  @spec invalid_workflow_name(name :: String.t()) :: Error.t()
  def invalid_workflow_name(name) do
    %Error{type: :invalid_workflow_name, reason: %{name: name}}
  end

  @doc """
  Builds an error when a `{:rerun, target}` names a vertex that is not a Stage.

  Only a Stage can run again. A Decision that the cursor reaches again is asked
  again, so a re-run of a Decision adds nothing.

  ## Examples

      DomovoyCore.Error.rerun_target_not_a_stage("review", "issue_to_pr")
      %DomovoyCore.Error{
        type: :rerun_target_not_a_stage,
        reason: %{vertex_name: "review", workflow_name: "issue_to_pr"}
      }
  """
  @spec rerun_target_not_a_stage(vertex_name :: Vertex.name(), workflow_name :: String.t()) ::
          Error.t()
  def rerun_target_not_a_stage(vertex_name, workflow_name) do
    %Error{
      type: :rerun_target_not_a_stage,
      reason: %{vertex_name: vertex_name, workflow_name: workflow_name}
    }
  end

  @doc """
  Builds an error when one name of a workflow collides with another name.

  `kind` says what the name collides with: `:node` names another node of
  another Stage, `:workflow_input` names a key of the inputs of the workflow,
  and `:choice_input` names a key of the inputs of a choice. Two nodes of one
  workflow never share one name, and a node name never equals an input key,
  because both name a record in one store.

  ## Examples

      DomovoyCore.Error.name_collision("double", :node, "issue_to_pr")
      %DomovoyCore.Error{
        type: :name_collision,
        reason: %{name: "double", kind: :node, workflow_name: "issue_to_pr"}
      }
  """
  @spec name_collision(name :: String.t(), kind :: atom(), workflow_name :: String.t()) ::
          Error.t()
  def name_collision(name, kind, workflow_name) do
    %Error{
      type: :name_collision,
      reason: %{name: name, kind: kind, workflow_name: workflow_name}
    }
  end

  @doc """
  Builds an error when a Stage reads a graph input that no prior vertex gives.

  A graph input is available when the workflow declares it, or when a Stage
  that runs before it on the path writes a node with that name, or when a
  Decision before it offers it as a choice input.

  ## Examples

      DomovoyCore.Error.stage_input_unbound("report", "count", "issue_to_pr")
      %DomovoyCore.Error{
        type: :stage_input_unbound,
        reason: %{stage_name: "report", input_name: "count", workflow_name: "issue_to_pr"}
      }
  """
  @spec stage_input_unbound(
          stage_name :: Vertex.name(),
          input_name :: Node.name(),
          workflow_name :: String.t()
        ) :: Error.t()
  def stage_input_unbound(stage_name, input_name, workflow_name) do
    %Error{
      type: :stage_input_unbound,
      reason: %{
        stage_name: stage_name,
        input_name: input_name,
        workflow_name: workflow_name
      }
    }
  end

  @doc """
  Builds an error when a decider of a `DomovoyCore.Decision` fails.

  `cause` is the term the decider gave back.

  ## Examples

      DomovoyCore.Error.decider_failed("review", :threshold_missing)
      %DomovoyCore.Error{
        type: :decider_failed,
        reason: %{decision_name: "review", cause: :threshold_missing}
      }
  """
  @spec decider_failed(decision_name :: Node.name(), cause :: any()) :: Error.t()
  def decider_failed(decision_name, cause) do
    %Error{
      type: :decider_failed,
      reason: %{decision_name: decision_name, cause: cause}
    }
  end

  @doc """
  Builds an error when a decider is not a module that exports `decide/3`, or a
  tuple of such a module and its options.

  ## Examples

      DomovoyCore.Error.invalid_decider("review", "NotAModule")
      %DomovoyCore.Error{
        type: :invalid_decider,
        reason: %{decision_name: "review", decider: "NotAModule"}
      }
  """
  @spec invalid_decider(decision_name :: Vertex.name(), decider :: any()) :: Error.t()
  def invalid_decider(decision_name, decider) do
    %Error{
      type: :invalid_decider,
      reason: %{decision_name: decision_name, decider: decider}
    }
  end

  @doc """
  Builds an error when a value for one input of a choice does not match the
  type that the choice declares, or when the choice declares no such input.

  ## Examples

      DomovoyCore.Error.invalid_choice_inputs("review_plan", "plan_context")
      %DomovoyCore.Error{
        type: :invalid_choice_inputs,
        reason: %{decision_name: "review_plan", input_name: "plan_context"}
      }
  """
  @spec invalid_choice_inputs(decision_name :: Vertex.name(), input_name :: Node.name()) ::
          Error.t()
  def invalid_choice_inputs(decision_name, input_name) do
    %Error{
      type: :invalid_choice_inputs,
      reason: %{decision_name: decision_name, input_name: input_name}
    }
  end

  @doc """
  Builds an error when a value for one input of a workflow does not match the
  type that the workflow declares, or when the workflow declares no such
  input.

  `reason` says what went wrong: `:not_declared`, or the reason of the cast
  error.

  ## Examples

      DomovoyCore.Error.invalid_workflow_input("issue_id", :not_declared)
      %DomovoyCore.Error{
        type: :invalid_workflow_input,
        reason: %{input_name: "issue_id", cause: :not_declared}
      }
  """
  @spec invalid_workflow_input(input_name :: Node.name(), reason :: any()) :: Error.t()
  def invalid_workflow_input(input_name, reason) do
    %Error{
      type: :invalid_workflow_input,
      reason: %{input_name: input_name, cause: reason}
    }
  end

  @doc """
  Builds an error when a re-run would rise the generation past the limit of
  the run.

  ## Examples

      DomovoyCore.Error.rerun_limit_exceeded("issue_to_pr", 10)
      %DomovoyCore.Error{
        type: :rerun_limit,
        reason: %{workflow_name: "issue_to_pr", max_generations: 10}
      }
  """
  @spec rerun_limit_exceeded(workflow_name :: String.t(), max_generations :: pos_integer()) ::
          Error.t()
  def rerun_limit_exceeded(workflow_name, max_generations) do
    %Error{
      type: :rerun_limit,
      reason: %{workflow_name: workflow_name, max_generations: max_generations}
    }
  end

  @doc """
  Builds an error when a person picks a choice that a Decision does not offer.

  ## Examples

      DomovoyCore.Error.choice_not_offered("review_plan", "retry", ["proceed", "revise"])
      %DomovoyCore.Error{
        type: :choice_not_offered,
        reason: %{
          decision_name: "review_plan",
          choice_name: "retry",
          offered: ["proceed", "revise"]
        }
      }
  """
  @spec choice_not_offered(
          decision_name :: Vertex.name(),
          choice_name :: String.t(),
          offered :: [String.t()]
        ) :: Error.t()
  def choice_not_offered(decision_name, choice_name, offered) do
    %Error{
      type: :choice_not_offered,
      reason: %{decision_name: decision_name, choice_name: choice_name, offered: offered}
    }
  end

  @doc """
  Builds an error when a caller answers a run that does not wait for a
  Decision.

  ## Examples

      DomovoyCore.Error.run_not_awaiting_decision("issue_to_pr", "plan", :ready)
      %DomovoyCore.Error{
        type: :run_not_awaiting_decision,
        reason: %{workflow_name: "issue_to_pr", cursor: "plan", status: :ready}
      }
  """
  @spec run_not_awaiting_decision(
          workflow_name :: String.t(),
          cursor :: Vertex.name() | nil,
          status :: atom()
        ) :: Error.t()
  def run_not_awaiting_decision(workflow_name, cursor, status) do
    %Error{
      type: :run_not_awaiting_decision,
      reason: %{workflow_name: workflow_name, cursor: cursor, status: status}
    }
  end

  @doc """
  Builds an error when a caller answers a run that still runs a Stage.

  The server runs one Stage at a time in a task. A decision that arrives
  while the task runs waits for no answer. The caller reads the state again
  later and answers when the run waits. The reason holds the status and the
  cursor, so the caller can back off without a second call. The status and
  the cursor default to `nil`, so a caller that knows no run state still
  builds the error.

  ## Examples

      DomovoyCore.Error.run_busy("issue_to_pr", "dom-30")
      %DomovoyCore.Error{
        type: :run_busy,
        reason: %{workflow_name: "issue_to_pr", run_id: "dom-30", status: nil, cursor: nil}
      }

      DomovoyCore.Error.run_busy("issue_to_pr", "dom-30", :ready, "prepare")
      %DomovoyCore.Error{
        type: :run_busy,
        reason: %{workflow_name: "issue_to_pr", run_id: "dom-30", status: :ready, cursor: "prepare"}
      }
  """
  @spec run_busy(
          workflow_name :: String.t(),
          run_id :: String.t(),
          status :: atom() | nil,
          cursor :: String.t() | nil
        ) :: Error.t()
  def run_busy(workflow_name, run_id, status \\ nil, cursor \\ nil) do
    %Error{
      type: :run_busy,
      reason: run_reason(workflow_name, run_id) |> Map.merge(%{status: status, cursor: cursor})
    }
  end

  @doc """
  Builds an error when a resume asks for a run that no durable adapter holds.

  A run on a non-durable custom store lives in the process that opened it. The death
  of that process drops the records and the events. A resume then finds an
  empty journal and must not invent a run. The caller starts again instead.
  A mixed adapter pair is durable only when both adapters keep data after
  their owner dies.

  ## Examples

      DomovoyCore.Error.run_not_durable("issue_to_pr", "dom-30")
      %DomovoyCore.Error{
        type: :run_not_durable,
        reason: %{workflow_name: "issue_to_pr", run_id: "dom-30"}
      }
  """
  @spec run_not_durable(workflow_name :: String.t(), run_id :: String.t()) :: Error.t()
  def run_not_durable(workflow_name, run_id) do
    %Error{type: :run_not_durable, reason: run_reason(workflow_name, run_id)}
  end

  @doc """
  Builds an error when a resume names a run that the journal does not hold.

  A journal with no event holds no run. The resume finds no cursor and no
  status. The caller checks the run id and tries again.

  ## Examples

      DomovoyCore.Error.run_not_found("issue_to_pr", "dom-30")
      %DomovoyCore.Error{
        type: :run_not_found,
        reason: %{workflow_name: "issue_to_pr", run_id: "dom-30"}
      }
  """
  @spec run_not_found(workflow_name :: String.t(), run_id :: String.t()) :: Error.t()
  def run_not_found(workflow_name, run_id) do
    %Error{type: :run_not_found, reason: run_reason(workflow_name, run_id)}
  end

  @doc """
  Builds an error when the supervisor refuses a new workflow server.

  `cause` names what the supervisor gave, such as `:max_children`. It never
  holds a workflow or its inputs. A non-atom cause keeps its `inspect/1`
  text, because a supervisor reason is not user input.

  ## Examples

      DomovoyCore.Error.server_start_failed("issue_to_pr", "dom-30", :max_children)
      %DomovoyCore.Error{
        type: :server_start_failed,
        reason: %{workflow_name: "issue_to_pr", run_id: "dom-30", cause: :max_children}
      }
  """
  @spec server_start_failed(
          workflow_name :: String.t(),
          run_id :: String.t(),
          cause :: term()
        ) :: Error.t()
  def server_start_failed(workflow_name, run_id, cause) do
    %Error{
      type: :server_start_failed,
      reason: run_reason(workflow_name, run_id) |> Map.put(:cause, cause)
    }
  end

  @doc """
  Builds an error when a step task of the server exits without a result.

  The server fails the run, so the run does not park in `:ready` with no
  task. `cause` holds the exit reason of the task. It never holds a record
  or a value.

  ## Examples

      DomovoyCore.Error.run_step_crashed("issue_to_pr", "dom-30", :killed)
      %DomovoyCore.Error{
        type: :run_step_crashed,
        reason: %{workflow_name: "issue_to_pr", run_id: "dom-30", cause: :killed}
      }
  """
  @spec run_step_crashed(
          workflow_name :: String.t(),
          run_id :: String.t(),
          cause :: term()
        ) :: Error.t()
  def run_step_crashed(workflow_name, run_id, cause) do
    %Error{
      type: :run_step_crashed,
      reason: run_reason(workflow_name, run_id) |> Map.put(:cause, cause)
    }
  end

  @doc """
  Builds an error when a second start names one run with other inputs.

  The first start owns the run. The second call gives this error and starts
  nothing. The reason names the run only, never the inputs, so no value
  reaches a log.

  ## Examples

      DomovoyCore.Error.run_input_mismatch("issue_to_pr", "dom-30")
      %DomovoyCore.Error{
        type: :run_input_mismatch,
        reason: %{workflow_name: "issue_to_pr", run_id: "dom-30"}
      }
  """
  @spec run_input_mismatch(workflow_name :: String.t(), run_id :: String.t()) :: Error.t()
  def run_input_mismatch(workflow_name, run_id) do
    %Error{type: :run_input_mismatch, reason: run_reason(workflow_name, run_id)}
  end

  @doc """
  Builds an error when server opts hold a bad `:job`.

  The caller gives a `%DomovoyCore.Job{}` or no `:job`. Any other value gives
  this error before the server starts.

  ## Examples

      DomovoyCore.Error.invalid_server_job(:not_a_job)
      %DomovoyCore.Error{type: :invalid_server_job, reason: %{cause: :not_a_job}}
  """
  @spec invalid_server_job(cause :: term()) :: Error.t()
  def invalid_server_job(cause) do
    %Error{type: :invalid_server_job, reason: %{cause: cause}}
  end

  @spec run_reason(workflow_name :: String.t(), run_id :: String.t()) :: %{
          workflow_name: String.t(),
          run_id: String.t()
        }
  defp run_reason(workflow_name, run_id) do
    %{workflow_name: workflow_name, run_id: run_id}
  end

  @spec keys(raw_value :: any()) :: %{optional(:keys) => [any()]}
  defp keys(raw_value) when is_map(raw_value) do
    %{keys: raw_value |> Map.delete(:__struct__) |> Map.keys() |> Enum.sort()}
  end

  defp keys(_raw_value), do: %{}
end
