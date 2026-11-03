ExUnit.start(exclude: [:integration, :scale])
Ecto.Adapters.SQL.Sandbox.mode(Bitblocks.Repo, {:shared, self()})
