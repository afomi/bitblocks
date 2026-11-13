# Per-checkout test isolation (#85), evaluated by config/test.exs and by
# test/config/test_checkout_test.exs.
#
# Several sessions run `mix test` at once from different checkouts and
# worktrees of this repo. Sharing one database and one endpoint port, their
# runs collide. Each checkout instead gets its own database suffix and port,
# derived from a hash of its absolute path, so they are stable across runs.
# MIX_TEST_PARTITION and TEST_PORT still override them when set.
#
# Returns a function of (checkout_root, env) -> %{partition: _, port: _}.
fn root, env ->
  hash = :crypto.hash(:sha256, Path.expand(root))
  <<n::unsigned-32, _::binary>> = hash
  suffix = "_" <> (hash |> binary_part(0, 4) |> Base.encode16(case: :lower))

  partition =
    case Map.get(env, "MIX_TEST_PARTITION") do
      nil -> suffix
      explicit -> explicit
    end

  # 40000..48999: clear of dev (4000), qart's test server (4002) and the
  # macOS ephemeral range (49152 and up).
  port =
    case Map.get(env, "TEST_PORT") do
      nil -> 40_000 + rem(n, 9_000)
      explicit -> String.to_integer(explicit)
    end

  %{partition: partition, port: port}
end
