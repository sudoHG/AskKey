# Legacy v7 migration fixture

`legacy-v7-vault.db` was generated through the last supported `VaultStore` at
base commit `12616611c5339587331ced9ecf23e506b511ffca`. It contains the real GRDB
migration history `v1, v3, v4, v5, v6, v7`, one AES-GCM encrypted text value,
and legacy Project/Environment/permission data.

The fixture-only legacy key is 32 bytes of `0x5A`; the plaintext value is the
non-secret string `sk-fixture`. SHA-256:
`606bbf502729a9c7b54db92ec68f39e34b5377b84d0305f5a365e6648f325e1e`.
