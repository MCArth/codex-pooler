defmodule CodexPooler.Upstreams.CodexClientIdentityTest do
  use ExUnit.Case, async: false

  alias CodexPooler.Upstreams.CodexClientIdentity

  test "reads protocol versions from current Codex CLI and Desktop user agents" do
    for prefix <- ["codex_cli_rs", "codex_exec", "Codex Desktop"] do
      assert CodexClientIdentity.client_version([
               {"user-agent", "#{prefix}/1.2.3-alpha.9.2 (Windows)"}
             ]) == "1.2.3"
    end

    assert CodexClientIdentity.client_version([{"user-agent", "Mozilla/5.0"}]) == nil

    assert CodexClientIdentity.client_version([
             {"version", "1.3.0"},
             {"user-agent", "Codex Desktop/1.2.3"}
           ]) == "1.3.0"
  end

  setup do
    previous = Application.get_env(:codex_pooler, CodexPooler.Catalog)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:codex_pooler, CodexPooler.Catalog, previous),
        else: Application.delete_env(:codex_pooler, CodexPooler.Catalog)
    end)
  end

  test "defaults to one managed release pin and keeps its identity headers consistent" do
    Application.delete_env(:codex_pooler, CodexPooler.Catalog)

    managed_version =
      :codex_pooler
      |> Application.fetch_env!(CodexClientIdentity)
      |> Keyword.fetch!(:default_client_version)

    assert managed_version =~ ~r/\A\d+\.\d+\.\d+\z/
    assert CodexClientIdentity.version() == managed_version
    assert CodexClientIdentity.user_agent() == "BloxdLocalGateway/1.0"

    assert CodexClientIdentity.headers() == [
             {"user-agent", "BloxdLocalGateway/1.0"},
             {"originator", "codex_cli_rs"},
             {"version", managed_version}
           ]
  end

  test "falls back to the managed release pin for invalid configured versions" do
    Application.delete_env(:codex_pooler, CodexPooler.Catalog)

    managed_version =
      :codex_pooler
      |> Application.fetch_env!(CodexClientIdentity)
      |> Keyword.fetch!(:default_client_version)

    for version <- [nil, "", "rust-v0.153.4", "not-a-version", 153, %{}] do
      Application.put_env(:codex_pooler, CodexPooler.Catalog, codex_client_version: version)

      assert CodexClientIdentity.version() == managed_version
      assert CodexClientIdentity.user_agent() == "BloxdLocalGateway/1.0"

      assert CodexClientIdentity.headers() == [
               {"user-agent", "BloxdLocalGateway/1.0"},
               {"originator", "codex_cli_rs"},
               {"version", managed_version}
             ]
    end
  end

  test "keeps the gateway User-Agent independent of the protocol version" do
    Application.put_env(:codex_pooler, CodexPooler.Catalog, codex_client_version: "9.8.7")

    assert CodexClientIdentity.user_agent() == "BloxdLocalGateway/1.0"

    assert CodexClientIdentity.headers() == [
             {"user-agent", "BloxdLocalGateway/1.0"},
             {"originator", "codex_cli_rs"},
             {"version", "9.8.7"}
           ]
  end
end
