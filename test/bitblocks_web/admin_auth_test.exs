defmodule BitblocksWeb.AdminAuthTest do
  use ExUnit.Case, async: true

  alias BitblocksWeb.AdminAuth

  describe "decide/3 — production fail-closed (threat T10)" do
    test "refuses the default password in production" do
      assert {:error, :default_credentials} = AdminAuth.decide(:prod, "operator", "secret")
    end

    test "refuses the default username in production" do
      assert {:error, :default_credentials} = AdminAuth.decide(:prod, "admin", "s3cret!")
    end

    test "refuses when both are defaults (unset env)" do
      assert {:error, :default_credentials} = AdminAuth.decide(:prod, "admin", "secret")
    end

    test "allows non-default credentials in production" do
      assert {:ok, "operator", "s3cret!"} = AdminAuth.decide(:prod, "operator", "s3cret!")
    end
  end

  describe "decide/3 — dev/test convenience" do
    test "allows the defaults in dev and test" do
      assert {:ok, "admin", "secret"} = AdminAuth.decide(:dev, "admin", "secret")
      assert {:ok, "admin", "secret"} = AdminAuth.decide(:test, "admin", "secret")
    end
  end
end
