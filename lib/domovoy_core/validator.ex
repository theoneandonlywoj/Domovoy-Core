defmodule DomovoyCore.Validator do
  @moduledoc """
  Checks runner input through an Ecto changeset.

  A validator receives the changeset and the existing `DomovoyCore.Context`. It returns a changeset and produces no value.
  Errors must describe fields and rules. They must not contain input values or configuration secrets.

  The Engine calls runner validators first, then node validators. It applies the changeset only after all validators return.
  If the changeset is invalid, the Engine does not call the runner. It returns this error:

      %DomovoyCore.Error{type: :invalid_input, reason: changeset.errors, retryable?: false, metadata: %{}}

  ## Examples

      iex> defmodule Elixir.DomovoyCore.Example.PositiveCount do
      ...>   @behaviour DomovoyCore.Validator
      ...>   @impl DomovoyCore.Validator
      ...>   def validate(changeset, %DomovoyCore.Context{}) do
      ...>     Ecto.Changeset.validate_number(changeset, :count, greater_than: 0)
      ...>   end
      ...> end
      iex> changeset = Ecto.Changeset.cast({%{}, %{count: :integer}}, %{count: -1}, [:count])
      iex> checked = DomovoyCore.Example.PositiveCount.validate(changeset, %DomovoyCore.Context{})
      iex> checked.valid?
      false
      iex> checked.errors
      [count: {"must be greater than %{number}", [validation: :number, kind: :greater_than, number: 0]}]
  """

  @callback validate(changeset :: Ecto.Changeset.t(), context :: DomovoyCore.Context.t()) ::
              Ecto.Changeset.t()
end
