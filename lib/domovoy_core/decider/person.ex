defmodule DomovoyCore.Decider.Person do
  @moduledoc """
  The decider that waits for a person.

  This is the default decider of a `DomovoyCore.Decision`. `decide/3` always gives
  `:await`, so `DomovoyCore.Run` stops the run and a person answers with
  `DomovoyCore.Run.decide/4`.

  ## Examples

      iex> decision = DomovoyCore.Decision.new(%{
      ...>   name: "review",
      ...>   prompt: "Go on?",
      ...>   choices: [
      ...>     DomovoyCore.Choice.new(%{name: "approve", description: "Go on.", target: {:run, "report"}})
      ...>   ]
      ...> })
      iex> context = %DomovoyCore.Context{job: DomovoyCore.Job.new("dom-30")}
      iex> DomovoyCore.Decider.Person.decide(decision, context, [])
      :await
  """

  @behaviour DomovoyCore.Decider

  alias DomovoyCore.Context
  alias DomovoyCore.Decision

  @impl DomovoyCore.Decider
  @spec decide(decision :: Decision.t(), context :: Context.t(), opts :: keyword()) :: :await
  def decide(_decision, _context, _opts), do: :await
end
