defmodule DomovoyCore.Choice do
  @moduledoc """
  One answer that a `DomovoyCore.Decision` offers.

  A choice is not a bare string. A person needs to know what a choice does
  before they pick it, so a choice carries its own text. It holds five fields:

    * `name` — what the person types or clicks, and what the record of the
      answer holds. It is short, and it is unique inside one Decision.
    * `description` — one to three sentences. It says what happens after the
      person picks this choice. An interface shows it next to the name.
    * `target` — where the cursor goes. `:halt` ends the workflow.
      `{:rerun, stage}` sends the cursor back and raises the re-run count.
      `{:run, vertex}` moves the cursor forward.
    * `inputs` — the typed values that this choice adds when a person picks
      it. The key is the name of an input. The value is the `DomovoyCore.Type`
      that checks it. `DomovoyCore.Run.decide/4` casts each value that the person
      sends, and the record goes to the store at the new generation. The map
      is empty when the choice adds no value.
    * `metadata` — what an interface needs and what the core never reads: a
      keyboard shortcut, an icon, an order, a colour, or the name of the input
      that the text of the person goes to.

  The choice holds the target because a Decision must route somewhere, and the
  name of a choice is the only thing that names that route. A separate map of
  a name to a target would let the two lists disagree.

  ## Examples

      iex> DomovoyCore.Choice.new(%{
      ...>   name: "proceed",
      ...>   description: "The plan is correct. DomovoyCore implements it.",
      ...>   target: {:run, "implement"}
      ...> })
      %DomovoyCore.Choice{
        name: "proceed",
        description: "The plan is correct. DomovoyCore implements it.",
        target: {:run, "implement"},
        inputs: %{},
        metadata: %{}
      }

  A re-run points back at a Stage, and it can carry one typed input:

      iex> DomovoyCore.Choice.new(%{
      ...>   name: "revise",
      ...>   description: "Say what to change. DomovoyCore writes the plan again.",
      ...>   target: {:rerun, "plan"},
      ...>   inputs: %{"plan_context" => DomovoyCore.Type.String},
      ...>   metadata: %{"shortcut" => "r", "input" => "plan_context"}
      ...> }).inputs
      %{"plan_context" => DomovoyCore.Type.String}

  A missing field raises a `KeyError`. A target of another shape raises too:

      iex> DomovoyCore.Choice.new(%{name: "stop", description: "Ends.", target: "implement"})
      ** (ArgumentError) target of choice "stop" must be {:run, name}, {:rerun, name} or :halt, got: "implement"

  An input value that is not a `DomovoyCore.Type` raises too:

      iex> DomovoyCore.Choice.new(%{
      ...>   name: "stop",
      ...>   description: "Ends.",
      ...>   target: :halt,
      ...>   inputs: %{"note" => DomovoyCore.Name}
      ...> })
      ** (ArgumentError) input "note" of choice "stop" must name a DomovoyCore.Type, got: DomovoyCore.Name
  """

  alias DomovoyCore.Choice
  alias DomovoyCore.Type
  alias DomovoyCore.Vertex

  @type name() :: String.t()
  @type metadata() :: %{String.t() => any()}
  @type target() :: {:run, Vertex.name()} | {:rerun, Vertex.name()} | :halt

  @typedoc "The typed inputs that this choice adds. The map is empty by default."
  @type inputs() :: %{String.t() => Type.t()}

  @type t() :: %Choice{
          name: name(),
          description: String.t(),
          target: target(),
          inputs: inputs(),
          metadata: metadata()
        }

  @type new() :: %{
          required(:name) => name(),
          required(:description) => String.t(),
          required(:target) => target(),
          optional(:inputs) => inputs(),
          optional(:metadata) => metadata()
        }

  defstruct name: nil,
            description: nil,
            target: :halt,
            inputs: %{},
            metadata: %{}

  @doc """
  Makes a Choice. `:name`, `:description` and `:target` are necessary.
  `:inputs` and `:metadata` are empty by default.

  Raises an `ArgumentError` when an input value is not a module that
  implements `DomovoyCore.Type`.
  """
  @spec new(new()) :: Choice.t()
  def new(args) when is_map(args) do
    name = Map.fetch!(args, :name)
    target = Map.fetch!(args, :target)
    inputs = check_inputs(Map.get(args, :inputs, %{}), name)

    if not target?(target) do
      raise ArgumentError,
            "target of choice #{inspect(name)} must be {:run, name}, {:rerun, name} or :halt, " <>
              "got: #{inspect(target)}"
    end

    %Choice{
      name: name,
      description: Map.fetch!(args, :description),
      target: target,
      inputs: inputs,
      metadata: Map.get(args, :metadata) || %{}
    }
  end

  @spec check_inputs(inputs :: inputs(), name :: Choice.name()) :: inputs()
  defp check_inputs(inputs, name) when is_map(inputs) do
    inputs
    |> Enum.each(fn {input_name, type} ->
      if not Type.type?(type) do
        raise ArgumentError,
              "input #{inspect(input_name)} of choice #{inspect(name)} must name a " <>
                "DomovoyCore.Type, got: #{inspect(type)}"
      end
    end)

    inputs
  end

  @doc """
  Returns `true` when `target` has one of the three shapes of a target.

  ## Examples

      iex> DomovoyCore.Choice.target?({:run, "implement"})
      true
      iex> DomovoyCore.Choice.target?({:rerun, "plan"})
      true
      iex> DomovoyCore.Choice.target?(:halt)
      true
      iex> DomovoyCore.Choice.target?({:jump, "plan"})
      false
  """
  @spec target?(target :: any()) :: boolean()
  def target?({:run, name}) when is_binary(name), do: true
  def target?({:rerun, name}) when is_binary(name), do: true
  def target?(:halt), do: true
  def target?(_target), do: false

  @doc """
  Returns `true` when the target of `choice` sends the cursor back.

  ## Examples

      iex> choice = DomovoyCore.Choice.new(%{name: "revise", description: "Again.", target: {:rerun, "plan"}})
      iex> DomovoyCore.Choice.rerun?(choice)
      true
  """
  @spec rerun?(choice :: Choice.t()) :: boolean()
  def rerun?(%Choice{target: {:rerun, _name}}), do: true
  def rerun?(%Choice{}), do: false

  @doc """
  Gives the vertex that the target of `choice` names, or `nil` for `:halt`.

  ## Examples

      iex> choice = DomovoyCore.Choice.new(%{name: "proceed", description: "Go.", target: {:run, "implement"}})
      iex> DomovoyCore.Choice.target_vertex(choice)
      "implement"
      iex> DomovoyCore.Choice.target_vertex(%{choice | target: :halt})
      nil
  """
  @spec target_vertex(choice :: Choice.t()) :: Vertex.name() | nil
  def target_vertex(%Choice{target: {:run, name}}), do: name
  def target_vertex(%Choice{target: {:rerun, name}}), do: name
  def target_vertex(%Choice{target: :halt}), do: nil
end
