defmodule DomovoyCore.Test.FakeShell do
  @moduledoc """
  A `DomovoyCore.Shell` implementation that answers from a function supplied by the
  test.

  DomovoyCore has no mocking library, so command execution is substituted the same
  way `DomovoyCore.Shell` selects its implementation in production: through the
  `:domovoy_core, :shell_module` application environment key. `install/1` sets both
  that key and the responder; `uninstall/0` clears them.

  The application environment is global, so tests using this fake must run with
  `async: false` and call `uninstall/0` from `on_exit/1`.

  ## Examples

  ```elixir
  DomovoyCore.Test.FakeShell.install(fn "git", ["status", "--short"], _opts ->
    {:ok, " M README.md\\n"}
  end)

  on_exit(&DomovoyCore.Test.FakeShell.uninstall/0)
  ```
  """

  @behaviour DomovoyCore.Shell

  alias DomovoyCore.Shell

  @typedoc "The function a test installs to answer `run/3`."
  @type responder() ::
          (String.t(), [String.t()], keyword() -> {:ok, String.t()} | {:error, String.t()})

  @doc """
  Installs this fake as the configured shell, answering through `responder`.

  This is a DomovoyCore test capability and has no Bash equivalent.
  """
  @spec install(responder()) :: :ok
  def install(responder) when is_function(responder, 3) do
    Application.put_env(:domovoy_core, :shell_module, __MODULE__)
    Application.put_env(:domovoy_core, :fake_shell_responder, responder)
    :ok
  end

  @doc """
  Restores the default shell implementation and drops the installed responder.

  This is a DomovoyCore test capability and has no Bash equivalent.
  """
  @spec uninstall() :: :ok
  def uninstall do
    Application.delete_env(:domovoy_core, :shell_module)
    Application.delete_env(:domovoy_core, :fake_shell_responder)
    :ok
  end

  @doc """
  Answers a command through the installed responder.

  This is a DomovoyCore test capability and has no Bash equivalent.
  """
  @impl Shell
  @spec run(String.t(), [String.t()], keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def run(command, args, opts) do
    responder = Application.fetch_env!(:domovoy_core, :fake_shell_responder)
    responder.(command, args, opts)
  end
end
