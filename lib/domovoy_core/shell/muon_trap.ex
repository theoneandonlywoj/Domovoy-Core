defmodule DomovoyCore.Shell.MuonTrap do
  @moduledoc """
  Runs an external command with MuonTrap, with a necessary timeout and one error
  format.

  This module is the default `DomovoyCore.Shell` implementation in the dev
  environment, the prod environment and the test environment. The
  `:domovoy_core, :shell_module` key can replace it. This module always gives a
  command as a list of arguments. It never uses a shell.

  ## Examples

  ```elixir
  DomovoyCore.Shell.MuonTrap.run("git", ["--version"], timeout: 5_000)
  ```

  ## Options

  This module sends `opts` to `MuonTrap.cmd/3`. There are two exceptions, which
  the list below gives. Only `:timeout` is necessary. All other options are
  optional.

    * `:timeout` — necessary. The milliseconds to wait for the end of the
      command. If the command does not end in that time, the error holds the
      output up to that moment, and the system sends SIGTERM to the process.
    * `:ok_exit_codes` - list of exit statuses treated as success, defaults to
      `[0]`. Some commands use a non-zero exit status to convey information
      rather than failure (for example `git show-ref --verify` exits `1` when
      the ref is absent, and `git diff --no-index` exits `1` when it finds a
      difference); pass those statuses here so `run/3` returns `{:ok, output}`
      for them. Stripped before the remaining options reach `MuonTrap.cmd/3`,
      which does not recognize it.
    * `:stderr_to_stdout` - forced to `true` by this implementation regardless
      of what is passed in `opts`, so `run/3` always returns combined output.
    * `:cd` - the directory to run the command in.
    * `:env` - an enumerable of `{key, value}` binary tuples to set as
      environment variables.
    * `:delay_to_sigkill` - milliseconds to wait before sending SIGKILL to a
      child that has not exited after SIGTERM (default 500 ms).

  See `MuonTrap.cmd/3` for the authoritative option reference.
  """

  @behaviour DomovoyCore.Shell

  alias DomovoyCore.Shell

  @doc """
  Runs a command and returns its combined stdout/stderr output.

  Returns `{:ok, output}` when the command exits with a status listed in
  `:ok_exit_codes`. A different status, a timeout, or a failure to spawn the
  command at all returns `{:error, message}`.

  ## Equivalent Bash

      <command> <args...> 2>&1
  """
  @impl Shell
  @spec run(String.t(), [String.t()], keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def run(command, args, opts) do
    timeout = Keyword.fetch!(opts, :timeout)
    ok_exit_codes = Keyword.get(opts, :ok_exit_codes, [0])

    command_opts =
      opts |> Keyword.delete(:ok_exit_codes) |> Keyword.put(:stderr_to_stdout, true)

    try do
      case MuonTrap.cmd(command, args, command_opts) do
        {output, :timeout} ->
          {:error, "command timed out after #{timeout}ms: #{trimmed(output)}"}

        {output, exit_status} ->
          if exit_status in ok_exit_codes do
            {:ok, IO.iodata_to_binary(output)}
          else
            {:error, "command exited with status #{exit_status}: #{trimmed(output)}"}
          end
      end
    rescue
      error -> {:error, "failed to run #{command}: #{Exception.message(error)}"}
    end
  end

  @spec trimmed(iodata()) :: String.t()
  defp trimmed(output), do: output |> IO.iodata_to_binary() |> String.trim()
end
