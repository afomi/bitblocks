defmodule Bitblocks.Chain do
  @moduledoc """
  The Chain context.
  """

  import Ecto.Query, warn: false
  alias Bitblocks.Repo

  alias Bitblocks.Block
  alias Bitblocks.Transaction

  @doc """
  Returns the list of blocks.

  ## Examples

      iex> list_blocks()
      [%Block{}, ...]

  """
  def list_blocks do
    query = from(u in Block, limit: 100, order_by: [desc: u.height])
    Repo.all(query)
  end

  def list_transactions do
    query = from(u in Transaction, limit: 100)
    Repo.all(query)
  end

  @doc """
  Gets a single block.

  Raises `Ecto.NoResultsError` if the Block does not exist.

  ## Examples

      iex> get_block!(123)
      %Block{}

      iex> get_block!(456)
      ** (Ecto.NoResultsError)

  """
  # def get_block!(id), do: Repo.get!(Block, id)

  # Find block by height, rather than ID
  def get_block!(height) do

    case Integer.parse(height) do
      # if passed a height, find by Height
      {int, ""} ->
        query = from i in Block,
          where: (i.height == ^height), limit: 1
        Repo.one(query)

      # if passed what is assumed to be a hash, find by hash
      {int, x} ->
        query = from i in Block,
          where: (i.hash == ^height), limit: 1
        Repo.one(query)

    end
  end

  def get_transaction!(txid) do
    query = from i in Transaction,
      where: (i.txid == ^txid), limit: 1
     Repo.one(query)
  end

  @doc """
  Creates a block.

  ## Examples

      iex> create_block(%{field: value})
      {:ok, %Block{}}

      iex> create_block(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_block(attrs \\ %{}) do
    %Block{}
    |> Block.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a block.

  ## Examples

      iex> update_block(block, %{field: new_value})
      {:ok, %Block{}}

      iex> update_block(block, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_block(%Block{} = block, attrs) do
    block
    |> Block.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a block.

  ## Examples

      iex> delete_block(block)
      {:ok, %Block{}}

      iex> delete_block(block)
      {:error, %Ecto.Changeset{}}

  """
  def delete_block(%Block{} = block) do
    Repo.delete(block)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking block changes.

  ## Examples

      iex> change_block(block)
      %Ecto.Changeset{data: %Block{}}

  """
  def change_block(%Block{} = block, attrs \\ %{}) do
    Block.changeset(block, attrs)
  end
end
