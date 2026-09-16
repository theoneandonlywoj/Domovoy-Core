defmodule DomovoyCore.Decider do
  @moduledoc """
  The behaviour of a module that decides the answer of a `DomovoyCore.Decision`.

  A decider gets the Decision, the `DomovoyCore.Context` of the run and the
  options of the decider. The context holds the store, so a decider reads a
  value with `DomovoyCore.Store.latest(context.store, name,
  context.job.generation)`.

  A decider gives one of four results:

    * `{:ok, choice_name}` — it picks the choice with that name.
    * `{:ok, choice_name, inputs}` — it picks the choice, and it adds a value
      for each input that the choice declares in its `inputs`.
    * `:await` — a person must answer. `DomovoyCore.Run` stops the run and waits.
    * `{:error, reason}` — it cannot decide. `DomovoyCore.Run` fails the run.

  The values of `inputs` are raw values. `DomovoyCore.Run` casts each one with the
  type that the chosen `DomovoyCore.Choice` declares for it.

  A Decision names its decider as a module or as `{module, options}`. The
  default decider is `DomovoyCore.Decider.Person`, which always gives `:await`.

  ## Examples

  A decider that reads the value of `"double"` and approves from `5` up:

      defmodule MyApp.Decider.Threshold do
        @behaviour DomovoyCore.Decider

        alias DomovoyCore.Context
        alias DomovoyCore.Decision
        alias DomovoyCore.Record
        alias DomovoyCore.Store
        alias DomovoyCore.Value

        @impl DomovoyCore.Decider
        def decide(%Decision{} = _decision, %Context{} = context, _opts) do
          case Store.latest(context.store, "double", context.job.generation) do
            {:ok, %Record{result: %Value{value: value}}} when value >= 5 -> {:ok, "approve"}
            {:ok, %Record{}} -> {:ok, "rerun"}
            _other -> {:error, :double_missing}
          end
        end
      end

  The same workflow uses the decider with options, and a fixed answer needs no
  store:

      decision = DomovoyCore.Decision.new(%{
        name: "review",
        prompt: "Go on?",
        choices: [
          DomovoyCore.Choice.new(%{name: "approve", description: "Go on.", target: {:run, "report"}})
        ],
        decider: {MyApp.Decider, choice: "approve"}
      })
      decision.decider
      {MyApp.Decider, choice: "approve"}
  """

  alias DomovoyCore.Choice
  alias DomovoyCore.Context
  alias DomovoyCore.Decision

  @typedoc "A module that implements the `DomovoyCore.Decider` behaviour, with its options."
  @type t() :: module() | {module(), keyword()}

  @typedoc """
  The values that a decider adds to its answer. `DomovoyCore.Run` casts each raw
  value with the type that the chosen `DomovoyCore.Choice` declares for it.
  """
  @type inputs() :: %{String.t() => any()}

  @doc """
  Chooses the answer of `decision`.

  `context` is the `DomovoyCore.Context` of the run, with the store and the
  journal open. `opts` are the options that the Decision names for this
  decider.
  """
  @callback decide(
              decision :: Decision.t(),
              context :: Context.t(),
              opts :: keyword()
            ) ::
              {:ok, Choice.name()}
              | {:ok, Choice.name(), inputs()}
              | :await
              | {:error, term()}
end
