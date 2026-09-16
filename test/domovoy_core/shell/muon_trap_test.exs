defmodule DomovoyCore.Shell.MuonTrapTest do
  use ExUnit.Case, async: true

  alias DomovoyCore.Shell.MuonTrap

  test "returns the output of a successful command" do
    assert {:ok, output} = MuonTrap.run("git", ["--version"], timeout: 5_000)
    assert output =~ "git version"
  end

  test "runs the command in the directory given by :cd" do
    assert {:ok, output} = MuonTrap.run("pwd", [], cd: "/", timeout: 5_000)
    assert String.trim(output) == "/"
  end

  test "reports a non-zero exit status as an error carrying the output" do
    assert {:error, message} = MuonTrap.run("git", ["nonesuch-subcommand"], timeout: 5_000)
    assert message =~ "command exited with status "
    assert message =~ "nonesuch-subcommand"
  end

  test "merges stderr into the returned output" do
    assert {:error, message} = MuonTrap.run("git", ["nonesuch-subcommand"], timeout: 5_000)
    assert message =~ "is not a git command"
  end

  test "treats a status listed in :ok_exit_codes as success" do
    assert {:ok, _output} =
             MuonTrap.run("git", ["nonesuch-subcommand"], timeout: 5_000, ok_exit_codes: [0, 1])
  end

  test "does not forward :ok_exit_codes to the underlying command" do
    assert {:ok, output} = MuonTrap.run("git", ["--version"], timeout: 5_000, ok_exit_codes: [0])
    assert output =~ "git version"
  end

  test "reports a command that outlives its timeout" do
    assert {:error, message} = MuonTrap.run("sleep", ["5"], timeout: 100)
    assert message =~ "command timed out after 100ms"
  end

  test "reports a command that cannot be spawned" do
    assert {:error, message} = MuonTrap.run("domovoy-no-such-executable", [], timeout: 5_000)
    assert message =~ "failed to run domovoy-no-such-executable"
  end

  test "requires a timeout" do
    assert_raise KeyError, fn -> MuonTrap.run("git", ["--version"], []) end
  end
end
