defmodule BitblocksWeb.Utils.BsvParamsTest do
  use ExUnit.Case, async: true

  alias BitblocksWeb.Utils.BsvParams

  describe "txid/1" do
    test "accepts a 64-char hex string" do
      txid = String.duplicate("a", 64)
      assert {:ok, ^txid} = BsvParams.txid(txid)
    end

    test "rejects wrong length, non-hex, and non-binary" do
      assert {:error, :invalid_txid} = BsvParams.txid(String.duplicate("a", 63))
      assert {:error, :invalid_txid} = BsvParams.txid(String.duplicate("a", 65))
      assert {:error, :invalid_txid} = BsvParams.txid("g" <> String.duplicate("a", 63))
      assert {:error, :invalid_txid} = BsvParams.txid(nil)
      assert {:error, :invalid_txid} = BsvParams.txid(123)
    end

    test "rejects a value carrying URL/path-injection characters" do
      assert {:error, :invalid_txid} = BsvParams.txid("../../etc/passwd")
      assert {:error, :invalid_txid} = BsvParams.txid(String.duplicate("a", 60) <> "/foo")
    end
  end

  describe "address/1" do
    test "accepts a typical base58 address" do
      addr = "1BvBMSEYstWetqTFn5Au4m4GFg7xJaNVN2"
      assert {:ok, ^addr} = BsvParams.address(addr)
    end

    test "rejects base58-invalid characters (0, O, I, l) and bad length" do
      assert {:error, :invalid_address} = BsvParams.address("1BvBMSEYst0OIl")
      assert {:error, :invalid_address} = BsvParams.address("short")
      assert {:error, :invalid_address} = BsvParams.address(String.duplicate("a", 50))
    end

    test "rejects injection attempts" do
      assert {:error, :invalid_address} = BsvParams.address("1Abc/unspent?x=1")
      assert {:error, :invalid_address} = BsvParams.address(nil)
    end
  end

  describe "token_id/1" do
    test "accepts a bare txid and a txid_vout form" do
      assert {:ok, _} = BsvParams.token_id(String.duplicate("a", 64))
      assert {:ok, _} = BsvParams.token_id(String.duplicate("a", 64) <> "_0")
      assert {:ok, _} = BsvParams.token_id("deadbeef_12")
    end

    test "rejects values that could inject a topic separator or path char" do
      assert {:error, :invalid_token_id} = BsvParams.token_id("abc:evil")
      assert {:error, :invalid_token_id} = BsvParams.token_id("abc/evil")
      assert {:error, :invalid_token_id} = BsvParams.token_id("order_book:token:x")
      assert {:error, :invalid_token_id} = BsvParams.token_id(nil)
    end
  end
end
