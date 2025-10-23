# Vapor Node Timestamping Flow (Visual Reference)

The diagram `vaportimestamp.png` captures the cooperative timestamp process we want to convey in UI copy and tooling. Key steps:

1. **Transaction A – user signed**  
   The base transaction carries the user’s OP_RETURN payload alongside `<user_pubkey>` and `<user_signature>`.
2. **Transaction A’ – node adds timestamp**  
   A Vapor node appends its local Unix timestamp inside the OP_RETURN stack while preserving the user’s materials.
3. **Transaction A’’ – node-signed wrap**  
   The node signs the updated output, embedding `<node_pubkey>` and `<node_signature>` so downstream verifiers can assert the timestamp’s origin.

The final timestamped transaction feeds three audiences:

- The originating **user**, who receives the augmented TX for audit.
- The **transaction log**, where append-only storage records the node’s attestation.
- Replication targets (other Vapor nodes or partners) to ensure the timestamp survives network churn.

Design implication: mirror the three-stage progression (user sign → node timestamp → node sign) in product flows so users understand why additional signatures appear and how replication propagates proof of time.***
