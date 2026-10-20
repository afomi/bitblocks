defmodule Bitblocks.Bitcom.RouteTest do
  @moduledoc "bit:// matchers follow route-parser rules (Bitcom 0.1.0.md)."
  use ExUnit.Case, async: true

  alias Bitblocks.Bitcom.Route

  @tx String.duplicate("e", 64)

  test ":param captures up to / ? or end" do
    assert Route.match("/:tx", "/#{@tx}") == {:ok, %{"tx" => @tx}}
    assert Route.match("/:tx", "/#{@tx}/more") == :nomatch
  end

  test "spec examples" do
    assert {:ok, %{"id" => "1", "comment" => "2", "rating" => "3"}} =
             Route.match(
               "/users/:id/comments/:comment/rating/:rating",
               "/users/1/comments/2/rating/3"
             )

    assert {:ok, %{"a" => "x/y", "b" => "z"}} = Route.match("/*a/foo/*b", "/x/y/foo/z")

    assert {:ok, %{"section" => "fiction/sci-fi", "title" => "dune"}} =
             Route.match("/books/*section/:title", "/books/fiction/sci-fi/dune")

    assert {:ok, %{"author" => "frank", "subject" => "sand"}} =
             Route.match(
               "/books?author=:author&subject=:subject",
               "/books?author=frank&subject=sand"
             )
  end

  test "optional groups may be absent" do
    assert {:ok, %{"thing" => "x"}} = Route.match("/some/(optional/):thing", "/some/x")
    assert {:ok, %{"thing" => "x"}} = Route.match("/some/(optional/):thing", "/some/optional/x")
  end

  test "literals are literal (no regex injection)" do
    assert Route.match("/a.b", "/axb") == :nomatch
    assert {:ok, %{}} = Route.match("/a.b", "/a.b")
  end

  test "an unbalanced or nameless matcher never matches" do
    assert Route.compile("/(a") == :error
    assert Route.compile("/a)") == :error
    assert Route.compile("/:") == :error
  end

  test "instantiate fills ${name} and drops unknowns" do
    assert Route.instantiate("https://media.bitcoinfiles.org/${tx}", %{"tx" => @tx}) ==
             "https://media.bitcoinfiles.org/#{@tx}"

    assert Route.instantiate("https://x/${missing}", %{}) == "https://x/"
  end
end
