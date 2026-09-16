defmodule DomovoyCore.Decision do
  @moduledoc """
  A vertex of a `DomovoyCore.Workflow` that asks what happens next.

  A Decision runs no runner, so it needs no `:runner`. It declares no `:type`,
  because the answer is always a `DomovoyCore.Type.Choice`. It declares no
  bindings, because the store holds what a reader reads. The caller
  shows `prompt`, the name and the description of each `DomovoyCore.Choice`, and
  the records of the job.

  A Decision has one control successor for each choice. Only a Decision
  branches. Only a Stage can be re-run. A Decision that the cursor reaches
  again is asked again, so `{:rerun, decision}` adds nothing, and
  `DomovoyCore.Workflow.new/1` rejects it.

  ## The decider

  The `decider:` field says who answers. The default is
  `DomovoyCore.Decider.Person`, so the run stops and a person answers with
  `DomovoyCore.Run.decide/4`. A module or `{module, options}` names a decider
  that answers on its own, and `DomovoyCore.Decider` is the behaviour of such a
  module. A decider reads the store through the `DomovoyCore.Context` of the run,
  and it can add a value for each input that the chosen choice declares.

  ## Examples

  `choice/2` gives one choice by name, `target/2` gives its target, and
  `answer/2` gives the choice as a `DomovoyCore.Value`, ready for the store. A
  name that the Decision does not offer gives an error:

      decision = DomovoyCore.Decision.new(%{
        name: "review_plan",
        prompt: "Read PLAN.md. Is this the right plan?",
        choices: [
          DomovoyCore.Choice.new(%{
            name: "proceed",
            description: "The plan is correct. DomovoyCore implements it.",
            target: {:run, "implement"}
          }),
          DomovoyCore.Choice.new(%{
            name: "revise",
            description: "Say what to change. DomovoyCore writes the plan again.",
            target: {:rerun, "plan"},
            inputs: %{"plan_context" => DomovoyCore.Type.String}
          }),
          DomovoyCore.Choice.new(%{
            name: "stop",
            description: "DomovoyCore ends the workflow now.",
            target: :halt
          })
        ]
      })
      decision.name
      "review_plan"
      decision.decider
      DomovoyCore.Decider.Person
      decision.metadata
      %{}
      DomovoyCore.Decision.choice_names(decision)
      ["proceed", "revise", "stop"]
      DomovoyCore.Decision.choice(decision, "revise").inputs
      %{"plan_context" => DomovoyCore.Type.String}
      DomovoyCore.Decision.target(decision, "stop")
      :halt
      DomovoyCore.Decision.answer(decision, "proceed")
      %DomovoyCore.Value{
        value: %DomovoyCore.Choice{
          name: "proceed",
          description: "The plan is correct. DomovoyCore implements it.",
          target: {:run, "implement"},
          inputs: %{},
          metadata: %{}
        },
        type: DomovoyCore.Type.Choice,
        metadata: %{}
      }
      DomovoyCore.Decision.answer(decision, "retry")
      %DomovoyCore.Error{
        type: :choice_not_offered,
        reason: %{
          decision_name: "review_plan",
          choice_name: "retry",
          offered: ["proceed", "revise", "stop"]
        }
      }

  A Decision that answers on its own names its decider, with or without
  options:

      choices = [DomovoyCore.Choice.new(%{name: "approve", description: "Go on.", target: :halt})]
      DomovoyCore.Decision.new(%{name: "auto", prompt: "?", choices: choices,
        decider: MyApp.Decider}).decider
      MyApp.Decider
      DomovoyCore.Decision.new(%{name: "auto", prompt: "?", choices: choices,
        decider: {MyApp.Decider, choice: "approve"}}).decider
      {MyApp.Decider, choice: "approve"}

  Two choices with one name raise, and so does an empty list:

      proceed = DomovoyCore.Choice.new(%{name: "proceed", description: "Go.", target: :halt})
      DomovoyCore.Decision.new(%{name: "review", prompt: "?", choices: [proceed, proceed]})
      ** (ArgumentError) decision "review" offers the name "proceed" more than once

      DomovoyCore.Decision.new(%{name: "review", prompt: "?", choices: []})
      ** (ArgumentError) decision "review" offers no choice

  A decider that exports no `decide/3` raises too:

      choice = DomovoyCore.Choice.new(%{name: "proceed", description: "Go.", target: :halt})
      try do
        DomovoyCore.Decision.new(%{name: "review", prompt: "?", choices: [choice], decider: DomovoyCore.Name})
      rescue
        error in ArgumentError -> String.contains?(error.message, "invalid_decider:")
      end
      true
  """

  alias DomovoyCore.Choice
  alias DomovoyCore.Decider
  alias DomovoyCore.Decision
  alias DomovoyCore.Error
  alias DomovoyCore.Type.Choice, as: ChoiceType
  alias DomovoyCore.Value
  alias DomovoyCore.Vertex

  @type metadata() :: %{String.t() => any()}

  @type t() :: %Decision{
          name: Vertex.name(),
          prompt: String.t(),
          choices: [Choice.t()],
          decider: Decider.t(),
          metadata: metadata()
        }

  @type new() :: %{
          required(:name) => Vertex.name(),
          required(:prompt) => String.t(),
          required(:choices) => [Choice.t()],
          optional(:decider) => Decider.t(),
          optional(:metadata) => metadata()
        }

  defstruct name: nil,
            prompt: nil,
            choices: [],
            decider: Decider.Person,
            metadata: %{}

  @doc """
  Makes a Decision. `:name`, `:prompt` and `:choices` are necessary.
  `:decider` is `DomovoyCore.Decider.Person` by default, and `:metadata` is empty
  by default.

  The decider must be a module that exports `decide/3`, or a tuple of such a
  module and a keyword list of options. A decider of another shape raises an
  `ArgumentError`.

  Raises an `ArgumentError` for an empty list of choices, and for two choices
  with one name.
  """
  @spec new(new()) :: Decision.t()
  def new(args) when is_map(args) do
    name = Map.fetch!(args, :name)
    choices = args |> Map.fetch!(:choices) |> check_choices(name)
    decider = args |> Map.get(:decider) |> validate_decider(name)

    %Decision{
      name: name,
      prompt: Map.fetch!(args, :prompt),
      choices: choices,
      decider: decider,
      metadata: Map.get(args, :metadata) || %{}
    }
  end

  @doc """
  Gives the names of the choices of `decision`, in the order of the list.
  """
  @spec choice_names(decision :: Decision.t()) :: [Choice.name()]
  def choice_names(%Decision{choices: choices}), do: Enum.map(choices, & &1.name)

  @doc """
  Gives the choice of `decision` with the name `name`.

  A name that the Decision does not offer gives
  `DomovoyCore.Error.choice_not_offered/3`.
  """
  @spec choice(decision :: Decision.t(), name :: Choice.name()) :: Choice.t() | Error.t()
  def choice(%Decision{} = decision, name) do
    case Enum.find(decision.choices, &(&1.name == name)) do
      %Choice{} = choice -> choice
      nil -> Error.choice_not_offered(decision.name, name, choice_names(decision))
    end
  end

  @doc """
  Gives the target of the choice of `decision` with the name `name`.
  """
  @spec target(decision :: Decision.t(), name :: Choice.name()) :: Choice.target() | Error.t()
  def target(%Decision{} = decision, name) do
    case choice(decision, name) do
      %Choice{target: target} -> target
      %Error{} = error -> error
    end
  end

  @doc """
  Resolves `name` to a choice, and casts it with `DomovoyCore.Type.Choice`.

  The record of an answer goes to the store under the name of the Decision.
  """
  @spec answer(decision :: Decision.t(), name :: Choice.name()) :: Value.t() | Error.t()
  def answer(%Decision{} = decision, name) do
    case choice(decision, name) do
      %Choice{} = choice -> Value.cast!(choice, ChoiceType)
      %Error{} = error -> error
    end
  end

  @doc """
  Gives the module of the decider of `decision` and its options.

  A bare module means no options.
  """
  @spec decider_parts(decision :: Decision.t()) :: {module(), keyword()}
  def decider_parts(%Decision{decider: decider}) when is_atom(decider), do: {decider, []}
  def decider_parts(%Decision{decider: {module, opts}}), do: {module, opts}

  @spec validate_decider(decider :: Decider.t() | nil, name :: Vertex.name()) :: Decider.t()
  defp validate_decider(nil, _name), do: Decider.Person

  defp validate_decider(decider, name) when is_atom(decider) do
    if exports_decide?(decider) do
      decider
    else
      raise ArgumentError, Error.message(Error.invalid_decider(name, decider))
    end
  end

  defp validate_decider({module, opts} = decider, name)
       when is_atom(module) and is_list(opts) do
    if exports_decide?(module) do
      decider
    else
      raise ArgumentError, Error.message(Error.invalid_decider(name, module))
    end
  end

  defp validate_decider(decider, name) do
    raise ArgumentError, Error.message(Error.invalid_decider(name, decider))
  end

  @spec exports_decide?(module :: module()) :: boolean()
  defp exports_decide?(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :decide, 3)
  end

  @spec check_choices(choices :: [Choice.t()], name :: Vertex.name()) :: [Choice.t()]
  defp check_choices([], name),
    do: raise(ArgumentError, "decision #{inspect(name)} offers no choice")

  defp check_choices(choices, name) when is_list(choices) do
    choices
    |> Enum.map(& &1.name)
    |> Enum.frequencies()
    |> Enum.find(fn {_choice_name, count} -> count > 1 end)
    |> case do
      nil ->
        choices

      {choice_name, _count} ->
        raise ArgumentError,
              "decision #{inspect(name)} offers the name #{inspect(choice_name)} more than once"
    end
  end
end
