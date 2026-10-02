# Synthetic v15 library

Copied unchanged from issue #4, generated through Vault APIs at legacy-final
commit `ee709976f823104fe12fb68c3528adf67c3db3ef`. All inputs are synthetic.

`library.db` is a checkpointed, self-contained SQLite database with the 14
legacy migration identifiers. `library.key` contains exactly 32 raw AES-256
key bytes generated in memory; it is not a keychain export. `schema.sql` is
the original SQLite schema dump. `manifest.json` describes all credential
metadata, groups, access records, write receipts and table counts, without
payload values or private notes.

Tests copy the database into a temporary directory as `credentials-v2.db`,
inject the key through `MemoryAppKeyStore`, and call `VaultBootstrap.openCurrent`.
The fixed clock is Unix second 2000000000. Adoption changes only the migration
table to `askkey-0001-baseline`; its row count becomes 1 instead of 14.
`CurrentLibraryAdoptionTests` also decrypts synthetic payloads and verifies
file digests. No real vault, system keychain or installed app is used.
