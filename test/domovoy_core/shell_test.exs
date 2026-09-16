defmodule DomovoyCore.ShellTest do
  use ExUnit.Case, async: false

  alias DomovoyCore.Shell
  alias DomovoyCore.Test.FakeShell

  test "delegates to DomovoyCore.Shell.MuonTrap by default" do
    assert {:ok, output} = Shell.run("git", ["--version"], timeout: 5_000)
    assert output =~ "git version"
  end

  test "delegates to the implementation configured in the application environment" do
    FakeShell.install(fn command, args, opts ->
      send(self(), {:ran, command, args, opts})
      {:ok, "faked\n"}
    end)

    on_exit(&FakeShell.uninstall/0)

    assert Shell.run("git", ["status"], timeout: 1_000, cd: "/repo") == {:ok, "faked\n"}
    assert_received {:ran, "git", ["status"], opts}
    assert opts[:timeout] == 1_000
    assert opts[:cd] == "/repo"
  end

  test "passes an error from the configured implementation through unchanged" do
    FakeShell.install(fn _command, _args, _opts -> {:error, "nope"} end)
    on_exit(&FakeShell.uninstall/0)

    assert Shell.run("git", ["status"], timeout: 1_000) == {:error, "nope"}
  end
end
