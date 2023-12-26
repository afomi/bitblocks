defmodule Bitblocks.Repo do
  use Ecto.Repo,
    otp_app: :bitblocks,
    adapter: Mongo.Ecto
end
