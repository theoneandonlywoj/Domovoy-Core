defmodule DomovoyCore.Name do
  @moduledoc """
  The rule for a name that ends up in a path.

  A run id, a workflow name and a node name match `regex/0`: letters, digits,
  `_` and `-`, one or more. `DomovoyCore.Run.start/4` checks the run id
  with `check!/1`, so no store adapter ever sees a name that it must clean.
  `.` and `/` are not in the set. A store therefore cannot leave its
  directory. A binding source must also match this rule.

  ## Examples

      iex> DomovoyCore.Name.valid?("dom-30")
      true
      iex> DomovoyCore.Name.valid?("../x")
      false
      iex> DomovoyCore.Name.valid?("")
      false
      iex> DomovoyCore.Name.valid?(:atom)
      false

      iex> DomovoyCore.Name.check!("dom-30")
      "dom-30"
      iex> DomovoyCore.Name.check!("a/b")
      ** (ArgumentError) "a/b" is not a name: a name matches ~r/^[A-Za-z0-9_-]+$/

      iex> DomovoyCore.Name.random() |> DomovoyCore.Name.valid?()
      true
      iex> DomovoyCore.Name.random() |> String.length()
      16
  """

  @regex ~r/^[A-Za-z0-9_-]+$/
  @random_bytes 8

  @typedoc "A string that matches `regex/0`."
  @type t() :: String.t()

  @doc """
  Gives the regex that a name matches.
  """
  @spec regex() :: Regex.t()
  def regex, do: @regex

  @doc """
  Returns `true` when `name` is a string that matches `regex/0`.
  """
  @spec valid?(name :: any()) :: boolean()
  def valid?(name) when is_binary(name), do: Regex.match?(@regex, name)
  def valid?(_name), do: false

  @doc """
  Gives `name` back when it is valid, and raises an `ArgumentError` otherwise.
  """
  @spec check!(name :: any()) :: t()
  def check!(name) do
    if valid?(name) do
      name
    else
      raise ArgumentError, "#{inspect(name)} is not a name: a name matches #{inspect(@regex)}"
    end
  end

  @doc """
  Makes a random name of 16 lowercase hex characters.
  """
  @spec random() :: t()
  def random do
    @random_bytes |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
  end
end
