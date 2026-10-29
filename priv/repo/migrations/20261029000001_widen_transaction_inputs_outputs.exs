defmodule Bitblocks.Repo.Migrations.WidenTransactionInputsOutputs do
  use Ecto.Migration

  # #31: inputs/outputs were created as varchar(255)[] (`{:array, :string}`),
  # too short for one JSON-encoded vin/vout with script hex and asm. Prod was
  # widened to text[] by hand (it stores such txs); this brings dev and test
  # in line.
  #
  # Guarded, because the conversion rewrites the table (PG 17):
  #   * already text[] (prod): nothing runs, so no lock is taken;
  #   * varchar on a small table (dev, test): converted;
  #   * varchar on a large table: refuse, loudly, rather than lock a
  #     multi-GB table mid-deploy. Plan that conversion separately (#31).
  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute("""
    DO $$
    DECLARE
      inputs_type text := (
        SELECT format_type(atttypid, atttypmod) FROM pg_attribute
        WHERE attrelid = 'transactions'::regclass AND attname = 'inputs'
      );
      outputs_type text := (
        SELECT format_type(atttypid, atttypmod) FROM pg_attribute
        WHERE attrelid = 'transactions'::regclass AND attname = 'outputs'
      );
      estimated_rows real := (SELECT reltuples FROM pg_class WHERE oid = 'transactions'::regclass);
    BEGIN
      IF inputs_type = 'text[]' AND outputs_type = 'text[]' THEN
        RAISE NOTICE 'transactions.inputs/outputs already text[]; nothing to do';
      ELSIF estimated_rows > 100000 THEN
        RAISE EXCEPTION 'transactions.inputs/outputs are %/% on ~% rows: converting rewrites the table; plan it separately (#31)',
          inputs_type, outputs_type, estimated_rows;
      ELSE
        ALTER TABLE transactions
          ALTER COLUMN inputs TYPE text[],
          ALTER COLUMN outputs TYPE text[];
      END IF;
    END $$;
    """)
  end

  # Narrowing could truncate data; leave the wider type in place.
  def down, do: :ok
end
