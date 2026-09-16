defmodule DomovoyCore do
  @moduledoc """
  Provides graph execution and plugin integrations for DomovoyCore.

  A node declares its runner inputs with `bind` and `args`. The Engine
  resolves each input and casts it through the input schema of the runner.
  A `DomovoyCore.Validator` checks a rule on the changeset before the runner
  runs.

  A `DomovoyCore.Runner` performs the work. It returns a raw value in a success
  tuple, and the Engine casts the value through the node type.

  Capabilities hold graph-independent logic. Value types cast and dump values.

  ## Examples

      iex> DomovoyCore.Runner.behaviour_info(:callbacks)
      [run: 2]
  """
end
