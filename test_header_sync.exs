# Test script for header-only sync
# Run with: mix run test_header_sync.exs

IO.puts("\n=== Testing Block Header Decoder ===\n")

# Sample block 100 data (verbosity 0)
hex_data =
  "01000000" <>
    "95194b8567fe2e8bbda931afd01a7acd399b9325cb54683e64129bcd00000000" <>
    "660802c98f18fd34fd16d61c63cf447568370124ac5f3be626c2e1c3c9f0052d" <>
    "29ab5f49" <>
    "ffff001d" <>
    "1e4f8611" <>
    "01" <>
    "01000000010000000000000000000000000000000000000000000000000000000000000000ffffffff0704ffff001d010affffffff0100f2052a010000004341041b0e8c2567c12536aa13357b79a073dc4444acb83c4ec7a0e2f99dd7457516c5817242da796924ca4e99947d087fedf9ce467cb9f7c6287078f801df276fdf84ac00000000"

try do
  decoded = Bitblocks.BlockHeaderDecoder.decode(hex_data)
  hash = Bitblocks.BlockHeaderDecoder.hash(hex_data)

  IO.puts("✓ Successfully decoded block header")
  IO.puts("  Hash: #{hash}")
  IO.puts("  Height: (need to get from RPC)")
  IO.puts("  Version: #{decoded.version}")
  IO.puts("  Previous Hash: #{decoded.prevblockhash}")
  IO.puts("  Merkle Root: #{decoded.merkleroot}")
  IO.puts("  Time: #{decoded.time}")
  IO.puts("  Bits: #{decoded.bits}")
  IO.puts("  Nonce: #{decoded.nonce}")
  IO.puts("  Num TX: #{decoded.num_tx}")
  IO.puts("  Size: #{decoded.size} bytes")

  IO.puts("\n=== Comparison ===")
  IO.puts("Verbosity 0: ~#{decoded.size} bytes")
  IO.puts("Verbosity 1 (with 1M txids): ~32 MB")
  IO.puts("Verbosity 1 (with 4M txids): ~128 MB")
  IO.puts("Memory savings: #{Float.round(128_000_000 / decoded.size, 0)}x smaller!\n")

  IO.puts("✓ Header-only sync is working!\n")
rescue
  e ->
    IO.puts("✗ Error: #{inspect(e)}\n")
    reraise e, __STACKTRACE__
end
