defmodule DomovoyCore.Shell do
  @moduledoc """
  The behaviour that runs an external command with a necessary timeout and one
  error format.

  `run/3` gives the work to the implementation in the
  `:domovoy_core, :shell_module` application environment key. The default is
  `DomovoyCore.Shell.MuonTrap`, in every environment. A test can set
  `:shell_module` to a fake module with this behaviour. Then the test controls
  the response.

  Every DomovoyCore capability that runs a command goes through this module.
  Therefore the commands have one timeout policy, one error shape and one point
  of replacement.

  ## Examples

  ```elixir
  DomovoyCore.Shell.run("git", ["--version"], timeout: 5_000)
  #=> {:ok, "git version 2.51.0\\n"}
  ```
  """

  @doc """
  Runs a command and returns its combined stdout/stderr output.

  Implementations return `{:ok, output}` when the command exits with an accepted
  status and `{:error, message}` otherwise, where `message` is a human-readable
  string describing the failure.
  """
  @callback run(command :: String.t(), args :: [String.t()], opts :: keyword()) ::
              {:ok, String.t()} | {:error, String.t()}

  @doc """
  Runs a command through the implementation configured for the current
  environment.

  See `DomovoyCore.Shell.MuonTrap` for the option reference honoured by the default
  implementation.

  ## Equivalent Bash

      <command> <args...>
  """
  @spec run(String.t(), [String.t()], keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def run(command, args, opts) do
    impl().run(command, args, opts)
  end

  @spec impl() :: module()
  defp impl do
    Application.get_env(:domovoy_core, :shell_module, DomovoyCore.Shell.MuonTrap)
  end
end
