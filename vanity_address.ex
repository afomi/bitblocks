#!/usr/bin/env elixir

Mix.install([{:bsv, "~> 2.1.0"}])

defmodule VanityAddress do
  @moduledoc """
  Bitcoin SV vanity address generator with parallel processing.

  Usage:
    ./vanity_address.ex <prefix> [options]

  Options:
    --workers N       Number of parallel workers (default: System.schedulers_online())
    --case-sensitive  Match case-sensitive prefix (default: case-insensitive)
    --suffix          Match suffix instead of prefix

  Examples:
    ./vanity_address.ex Ryan
    ./vanity_address.ex Ryan --workers 8
    ./vanity_address.ex Ryan --case-sensitive
    ./vanity_address.ex coin --suffix
  """

  @base58_alphabet "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"

  def main(args) do
    case parse_args(args) do
      {:ok, opts} ->
        validate_prefix(opts.prefix, opts.case_sensitive)
        run(opts)

      {:error, reason} ->
        IO.puts(:stderr, "Error: #{reason}")
        print_usage()
        System.halt(1)
    end
  end

  defp parse_args([]) do
    {:error, "No prefix provided"}
  end

  defp parse_args(args) do
    {options, remaining, _} =
      OptionParser.parse(args,
        strict: [
          workers: :integer,
          case_sensitive: :boolean,
          suffix: :boolean
        ]
      )

    case remaining do
      [prefix] ->
        {:ok,
         %{
           prefix: prefix,
           workers: Keyword.get(options, :workers, System.schedulers_online()),
           case_sensitive: Keyword.get(options, :case_sensitive, false),
           suffix: Keyword.get(options, :suffix, false)
         }}

      [] ->
        {:error, "No prefix provided"}

      _ ->
        {:error, "Too many arguments"}
    end
  end

  defp validate_prefix(prefix, case_sensitive) do
    # Bitcoin addresses always start with '1' or '3' for mainnet
    # We need to check if the prefix is valid Base58
    valid_chars = String.graphemes(@base58_alphabet)

    invalid_chars =
      prefix
      |> String.graphemes()
      |> Enum.reject(&(&1 in valid_chars))

    unless Enum.empty?(invalid_chars) do
      IO.puts(
        :stderr,
        "Warning: Prefix contains invalid Base58 characters: #{Enum.join(invalid_chars, ", ")}"
      )

      IO.puts(:stderr, "Valid characters: #{@base58_alphabet}")
      System.halt(1)
    end

    # Warn about difficulty
    difficulty = calculate_difficulty(String.length(prefix))

    IO.puts(
      "Searching for #{if case_sensitive, do: "case-sensitive", else: "case-insensitive"} match..."
    )

    IO.puts("Estimated attempts needed: ~#{format_number(difficulty)}")
    IO.puts("Using #{System.schedulers_online()} CPU cores")
    IO.puts("")
  end

  defp calculate_difficulty(length) do
    # Each character in base58 has ~58 possibilities
    # Case-insensitive reduces this to ~29 for letters
    trunc(:math.pow(29, length))
  end

  defp format_number(n) when n < 1_000, do: to_string(n)
  defp format_number(n) when n < 1_000_000, do: "#{Float.round(n / 1_000, 1)}K"
  defp format_number(n) when n < 1_000_000_000, do: "#{Float.round(n / 1_000_000, 1)}M"
  defp format_number(n), do: "#{Float.round(n / 1_000_000_000, 1)}B"

  defp print_usage do
    IO.puts(@moduledoc)
  end

  def run(opts) do
    start_time = System.monotonic_time(:millisecond)
    parent = self()

    # Trap exits to see worker crashes
    Process.flag(:trap_exit, true)

    # Spawn worker processes
    workers =
      for worker_id <- 1..opts.workers do
        spawn_link(fn -> worker(parent, opts, worker_id) end)
      end

    # Spawn statistics reporter
    stats_pid = spawn_link(fn -> stats_reporter(start_time, 0) end)

    # Wait for first result
    receive do
      {:found, address, private_key, wif, attempts, worker_id} ->
        # Kill all workers
        Enum.each(workers, &Process.exit(&1, :kill))
        Process.exit(stats_pid, :kill)

        elapsed = System.monotonic_time(:millisecond) - start_time

        IO.puts("\n" <> String.duplicate("=", 70))
        IO.puts("✓ FOUND VANITY ADDRESS!")
        IO.puts(String.duplicate("=", 70))
        IO.puts("")
        IO.puts("Address:     #{address}")
        IO.puts("Private Key: #{Base.encode16(private_key, case: :lower)}")
        IO.puts("WIF:         #{wif}")
        IO.puts("")
        IO.puts("Worker:      ##{worker_id}")
        IO.puts("Attempts:    #{format_number(attempts)}")
        IO.puts("Time:        #{format_time(elapsed)}")
        IO.puts("Rate:        #{format_number(trunc(attempts / (elapsed / 1000)))} addr/sec")
        IO.puts(String.duplicate("=", 70))

      {:EXIT, from, reason} ->
        IO.puts("\nWorker #{inspect(from)} crashed: #{inspect(reason)}")
        # Continue waiting
        receive_loop(workers, stats_pid, start_time)
    end
  end

  defp receive_loop(workers, stats_pid, start_time) do
    receive do
      {:found, address, private_key, wif, attempts, worker_id} ->
        # Kill all workers
        Enum.each(workers, &Process.exit(&1, :kill))
        Process.exit(stats_pid, :kill)

        elapsed = System.monotonic_time(:millisecond) - start_time

        IO.puts("\n" <> String.duplicate("=", 70))
        IO.puts("✓ FOUND VANITY ADDRESS!")
        IO.puts(String.duplicate("=", 70))
        IO.puts("")
        IO.puts("Address:     #{address}")
        IO.puts("Private Key: #{Base.encode16(private_key, case: :lower)}")
        IO.puts("WIF:         #{wif}")
        IO.puts("")
        IO.puts("Worker:      ##{worker_id}")
        IO.puts("Attempts:    #{format_number(attempts)}")
        IO.puts("Time:        #{format_time(elapsed)}")
        IO.puts("Rate:        #{format_number(trunc(attempts / (elapsed / 1000)))} addr/sec")
        IO.puts(String.duplicate("=", 70))

      {:EXIT, from, reason} ->
        IO.puts("\nWorker #{inspect(from)} crashed: #{inspect(reason)}")
        # Continue waiting
        receive_loop(workers, stats_pid, start_time)
    end
  end

  defp worker(parent, opts, worker_id) do
    # Each worker has its own PRNG seed
    :rand.seed(:exsss, {System.unique_integer(), System.monotonic_time(), worker_id})

    worker_loop(parent, opts, worker_id, 0)
  end

  defp worker_loop(parent, opts, worker_id, attempts) do
    # Generate random private key (32 bytes)
    private_key = :crypto.strong_rand_bytes(32)

    # Generate address from private key using BSV library
    case generate_address(private_key) do
      {:ok, address, wif} ->
        if matches?(address, opts) do
          send(parent, {:found, address, private_key, wif, attempts + 1, worker_id})
        else
          # Report progress every 1000 attempts (changed from 10000 for more feedback)
          if rem(attempts, 1_000) == 0 do
            send(parent, {:progress, 1_000})
          end

          worker_loop(parent, opts, worker_id, attempts + 1)
        end

      {:error, _reason} ->
        worker_loop(parent, opts, worker_id, attempts + 1)
    end
  end

  defp stats_reporter(start_time, total_attempts) do
    receive do
      {:progress, count} ->
        new_total = total_attempts + count
        elapsed = System.monotonic_time(:millisecond) - start_time
        rate = if elapsed > 0, do: trunc(new_total / (elapsed / 1000)), else: 0

        IO.write(
          "\rAttempts: #{format_number(new_total)} | Rate: #{format_number(rate)}/sec | Time: #{format_time(elapsed)}   "
        )

        stats_reporter(start_time, new_total)
    after
      100 ->
        # Show loading indicator even when no progress messages yet
        elapsed = System.monotonic_time(:millisecond) - start_time
        spinner = spinner_char(elapsed)

        if total_attempts > 0 do
          rate = trunc(total_attempts / (elapsed / 1000))

          IO.write(
            "\r#{spinner} Attempts: #{format_number(total_attempts)} | Rate: #{format_number(rate)}/sec | Time: #{format_time(elapsed)}   "
          )
        else
          IO.write("\r#{spinner} Searching...   ")
        end

        stats_reporter(start_time, total_attempts)
    end
  end

  defp spinner_char(elapsed) do
    frames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
    index = rem(div(elapsed, 100), length(frames))
    Enum.at(frames, index)
  end

  defp matches?(address, opts) do
    search_string = if opts.case_sensitive, do: opts.prefix, else: String.downcase(opts.prefix)

    address_part =
      if opts.suffix do
        # For suffix matching, skip the first character (always '1' or '3')
        address
        |> String.slice(1..-1//1)
        |> then(&if opts.case_sensitive, do: &1, else: String.downcase(&1))
      else
        # For prefix matching, skip the first character (always '1' or '3')
        # and check if the rest starts with the prefix
        address
        |> String.slice(1..-1//1)
        |> then(&if opts.case_sensitive, do: &1, else: String.downcase(&1))
      end

    if opts.suffix do
      String.ends_with?(address_part, search_string)
    else
      String.starts_with?(address_part, search_string)
    end
  end

  defp generate_address(private_key_bytes) do
    try do
      {:ok, priv} = BSV.PrivKey.from_binary(private_key_bytes)
      pubkey = BSV.PubKey.from_privkey(priv)
      addr = BSV.Address.from_pubkey(pubkey)
      address_string = BSV.Address.to_string(addr)
      wif_string = BSV.PrivKey.to_wif(priv)
      {:ok, address_string, wif_string}
    rescue
      _ -> {:error, :generation_failed}
    end
  end

  defp format_time(ms) when ms < 1000, do: "#{ms}ms"
  defp format_time(ms) when ms < 60_000, do: "#{Float.round(ms / 1000, 1)}s"

  defp format_time(ms) do
    minutes = div(ms, 60_000)
    seconds = rem(ms, 60_000) / 1000
    "#{minutes}m #{Float.round(seconds, 1)}s"
  end
end

# Run if called as script
VanityAddress.main(System.argv())
