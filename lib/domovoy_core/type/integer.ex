defmodule DomovoyCore.Type.Integer do
  @moduledoc """
  `DomovoyCore.Type` for an integer.

  This type accepts only an Elixir integer. A string of digits gives `:error`.
  The caller must change the string into an integer first.

  ## Examples

      iex> DomovoyCore.Type.Integer.cast(42)
      {:ok, 42}

      iex> DomovoyCore.Type.Integer.cast("42")
      :error

      iex> DomovoyCore.Value.cast("42", DomovoyCore.Type.Integer)
      {:error, %DomovoyCore.Error{type: :cast_error, reason: %{module: DomovoyCore.Type.Integer}}}
  """

  use DomovoyCore.Type

  @impl Ecto.Type
  def type, do: :integer

  @impl DomovoyCore.Type
  @spec cast(raw :: any(), metadata :: DomovoyCore.Type.metadata()) :: DomovoyCore.Type.cast()
  def cast(raw, _metadata) when is_integer(raw), do: {:ok, raw}
  def cast(_raw, _metadata), do: :error
end
