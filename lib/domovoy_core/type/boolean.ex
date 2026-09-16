defmodule DomovoyCore.Type.Boolean do
  @moduledoc """
  `DomovoyCore.Type` for a boolean.

  This type accepts only `true` and `false`. Every other raw value gives
  `:error`.

  ## Examples

      iex> DomovoyCore.Type.Boolean.cast(true)
      {:ok, true}

      iex> DomovoyCore.Type.Boolean.cast("true")
      :error
  """

  use DomovoyCore.Type

  @impl Ecto.Type
  def type, do: :boolean

  @impl DomovoyCore.Type
  @spec cast(raw :: any(), metadata :: DomovoyCore.Type.metadata()) :: DomovoyCore.Type.cast()
  def cast(raw, _metadata) when is_boolean(raw), do: {:ok, raw}
  def cast(_raw, _metadata), do: :error
end
