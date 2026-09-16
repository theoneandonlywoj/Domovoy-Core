defmodule DomovoyCore.Type.Directory do
  @moduledoc """
  `DomovoyCore.Type` for a directory that exists.

  The raw value is a path. `cast/2` expands it against the current directory
  and checks that a directory is there. The value is therefore always an
  absolute path to a directory that exists. A path that names no directory
  gives an error that holds the expanded path.

  ## Examples

      iex> {:ok, path} = DomovoyCore.Type.Directory.cast(".")
      iex> path == File.cwd!()
      true

      iex> DomovoyCore.Type.Directory.cast("/no/such/directory")
      {:error, [path: "/no/such/directory"]}

      iex> DomovoyCore.Type.Directory.cast(42)
      :error
  """

  use DomovoyCore.Type

  @impl Ecto.Type
  def type, do: :string

  @impl DomovoyCore.Type
  @spec cast(raw :: any(), metadata :: DomovoyCore.Type.metadata()) :: DomovoyCore.Type.cast()
  def cast(raw, _metadata) when is_binary(raw) do
    path = Path.expand(raw)

    if File.dir?(path), do: {:ok, path}, else: {:error, path: path}
  end

  def cast(_raw, _metadata), do: :error
end
