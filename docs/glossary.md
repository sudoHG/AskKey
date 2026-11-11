# Domain glossary

AskKey stores credentials for a person and mediates their use by local agents. These terms describe the current product; the [feature inventory](features.md) and [security policy](../SECURITY.md) define its retained behavior and limits.

The Chinese UI column quotes labels or relevant phrases from [Localizable.xcstrings](../Sources/AskKeyAppKit/Resources/Localizable.xcstrings), rather than inventing translations. A dash means there is no standalone UI label. The Chinese product name is 请旨; permission labels use separate terms.

| English term | Chinese UI term or phrase | Meaning and boundary |
|---|---|---|
| Ask Key | 请旨 | The macOS product. `AskKey` names the repository and code modules; `askkey` names the restricted helper and MCP server. |
| Credential | 凭证 | One sensitive object owned by a person, with a globally unique name and one agent permission. It can contain text, ordinary-file bytes, or multiple components. Prefer this term over the retired Secret, Project and Environment domain objects. |
| Credential library | 凭证库 | The local encrypted credential store and its App-owned key. Opening it for the Broker does not grant a management session. |
| Text credential | 文字 | A credential whose value is text, such as a token or password. An environment variable is a delivery mapping, not its stored identity. |
| File credential | 文件 | A credential containing a frozen ordinary file, its original filename, size and digest. An extension does not determine whether input is safe to import. |
| Credential component | 键; 值 | One named text or file value within a credential. Components share the credential's permission and approval; delivery mappings can differ. |
| Credential group | 凭证分组 | An optional organizational category. Moving a credential or deleting its group does not change its permission; deleting a group leaves its members ungrouped. |
| Ungrouped | 未分组 | A credential without a group, not a separate authorization scope. |
| Credential catalog | 浏览凭证目录 | Agent-visible metadata: names, IDs, usage instructions, expiry state and component delivery mappings. It omits Hidden and recycled credentials, values, private notes and original filenames. |
| Usage instructions | 使用说明; 给 Agent 的说明 | Guidance visible in the agent catalog. It must not contain material intended to remain private. |
| Private notes | 私人备注 | Encrypted notes available only through authenticated App management, excluded from agent responses. |
| Agent permission | 允许; 每次询问; 隐藏 | One credential-wide rule: Allow, Ask every time or Hidden. Groups and caller declarations cannot widen it. |
| Allow | 允许 | Read delivery can proceed without a new approval, through the Broker and subject to pause, expiry and launch checks. Agent writes still need separate approval. |
| Ask every time | 每次询问 | The default for new credentials. A read needs approval unless a valid timed allowance covers that credential; every new agent write needs its own approval. |
| Hidden | 隐藏; 隐藏的凭证不会进入 Agent 目录 | Excludes a credential from the agent catalog and agent read/write requests. It does not promise resistance to side channels available to another process running as the same macOS user. |
| Approval request | Agent 请求; 待处理请求 | A proposal bound to an operation, target and immutable payload digest, with a request ID, capability and deadline. It is not a management unlock. |
| Allow once | 允许本次 | Allows one request to consume approval once for its bound operation. It does not authorize a session or a changed payload. |
| Timed read allowance | 默认限时允许; 允许 %lld 分钟 | A revocable read allowance for one credential, shared by all local callers for the current macOS user until its original deadline. It never authorizes agent writes or isolates one client. |
| Caller claim | 调用方; 调用方自报的身份 | Caller-supplied name, path, signature and purpose used for display and attribution. These are unverified context, not authorization inputs. |
| Broker | — | The App's local, versioned service that evaluates agent requests and arranges approved delivery. It exposes a limited agent protocol, not a management API. |
| Helper | — | The bundled `askkey` executable: CLI, MCP stdio and Broker transport. It neither opens the credential database nor obtains the App's vault key. |
| Runtime delivery | 交付方式 | Supplies only explicitly selected credentials to a selected target process through configured environment variables or temporary files, without returning stored plaintext in AskKey's agent responses. |
| Environment variable mapping | 环境变量映射 | The variable name receiving a text value or temporary-file path in the target process. It does not imply selection of all stored credentials. |
| Temporary file delivery | — | A random `0600` file inside a private `0700` directory. Its lifetime is bounded by file TTL, credential expiry and the original approval deadline; cleanup is retried visibly on failure. |
| Management authentication | 请确认以管理凭证 | macOS owner authentication for sensitive App management. The management session, fresh reveal authentication and agent approval are separate boundaries. |
| Agent access pause / resume | 暂停 Agent 访问; 恢复 Agent 访问 | Pause cancels pending approvals and allowances and cleans deliveries. Resume requires system authentication and does not unlock management. |
| Access record | 访问记录 | Encrypted operation metadata, with no credential values, viewed and cleared through authenticated App management. It is not an agent log or proof of external behavior. |
| Credential expiry | 到期时间 | A deadline beyond which runtime use and writes fail; related approvals and temporary deliveries are invalidated. |
| Recycle bin | 回收站 | Deleted credentials retained for 30 days and unavailable to agents. Restore and permanent deletion are App management operations. |
| Backup file | 备份文件 | One `.askkeybackup` file holding every credential in the library, including Hidden and recycled ones, usage instructions and private notes, encrypted under its recovery key. Importing it adds credentials and never deletes or overwrites; see [ADR 0012](adr/0012-encrypted-backup-export-and-import.md). |
| Recovery key | 恢复密钥 | The key generated for one backup file, 28 characters in seven groups of four, shown once when the backup is made. Ask Key never stores it. Nobody can open the file without it, and anyone holding both can read every credential in the file. |
| Device | 设备 | Another Ask Key install the Mac trusts after pairing; in stage 2 an iPhone running the pairing-only app. Its platform and name are what it says about itself and are never shown as verified. See [ADR 0013](adr/0013-device-identity-and-pairing.md). |
| Pair | 配对; 配对设备… | Adding a device to this Mac's list: the Mac shows a QR code, the iPhone scans it, and the person enters the iPhone's pairing code on the Mac and confirms with system authentication. Needs the management session; agents cannot pair, list or remove devices. |
| Pairing code | 配对码 | Only the six digits the iPhone shows on its Ask Key pairing screen, typed on the Mac. The Mac never shows it, and Ask Key never sends it in a notification or a message. The image the iPhone scans is always the QR code (二维码), never a pairing code. |
| Delivery check | 送达检查; 测试送达; 还没联系上 | A message the Mac sends to a paired device to confirm it can be reached through iCloud. Until the first check succeeds, the device shows as "Not reached yet" (还没联系上). |
| Client adapter | — | The boundary that checks, previews, applies, verifies and rolls back a supported client's MCP configuration. Current clients are Claude Code, Codex, Cursor and Grok CLI; adapters share the Broker's security model. |
| Discovery hook | 凭证查询 | A reminder to consult the catalog before relevant commands. Discovery does not select credentials, approve requests or bypass the Broker. |

Protocol and storage terms have no standalone UI labels:

| Term | Meaning |
|---|---|
| Operation ID | Identifies one proposed operation. Exact retransmissions reuse its state; a genuinely new operation needs a new ID. |
| Request capability | An unpredictable token returned for a request, required with its ID to query or cancel it. Caller identity cannot replace it. |
| Frozen payload | The exact submitted values or uploaded bytes and target state bound to an approval. Revealing it requires separate authentication and does not approve it. |
| Final launch authorization | The synchronized check of original authorization, pause/revocation and deadlines immediately around process launch. It cannot retract material a target has already received. |
| Unknown outcome | `outcome_unknown`: AskKey cannot establish an execution outcome. Automatically repeating the operation could duplicate an external effect, so it must not retry automatically. |
| Schema baseline | `askkey-0001-baseline`, reproducing the v15 schema. The subsequent `askkey-0002-drop-legacy-tables` migration removes only legacy tables proven to contain no user data. See [ADR 0001](adr/0001-domain-storage-and-schema.md). |

The legacy iCloud backup and its recovery-key workflows were removed from v0.1 ([ADR 0004](adr/0004-backup-removal-and-future-design.md)). The current backup is an encrypted file export and merge import recorded in [ADR 0012](adr/0012-encrypted-backup-export-and-import.md).
