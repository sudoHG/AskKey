# ADR 0013: Device identity and pairing

## Status

Accepted. Stage 2 of the multi-device roadmap in [#269](https://github.com/sudoHG/AskKey/issues/269); the specification is [#282](https://github.com/sudoHG/AskKey/issues/282). [#284](https://github.com/sudoHG/AskKey/issues/284) adds the device module, [#285](https://github.com/sudoHG/AskKey/issues/285) the CloudKit transport, [#286](https://github.com/sudoHG/AskKey/issues/286) the signed Local build, [#287](https://github.com/sudoHG/AskKey/issues/287) the Mac device services, [#288](https://github.com/sudoHG/AskKey/issues/288) the Mac Devices section, [#289](https://github.com/sudoHG/AskKey/issues/289) the pairing-only iPhone app, and [#290](https://github.com/sudoHG/AskKey/issues/290) verifies it on real devices.

This ADR does not amend [ADR 0002](0002-broker-and-approval-protocol.md): no credential, approval request or decision crosses devices in stage 2. Stage 4 amends ADR 0002 when the iPhone starts approving.

## Context

Cross-device approval needs each device to know, before any request is sent, which other devices it trusts and how to reach them privately. An Ask Key install has no identity beyond its local library and cannot tell another device of the same person apart from any program or device that can write to that person's iCloud.

[#281](https://github.com/sudoHG/AskKey/issues/281) measured CloudKit on real devices ([results](https://github.com/sudoHG/AskKey/issues/281#issuecomment-6744230914)):

- A notarized Developer ID Mac app can use CloudKit and push with an embedded Developer ID profile.
- Mac → locked iPhone delivered 5 of 5 messages, median push time 0.52 s, with a Notification Service Extension fetching and decrypting each record.
- Pushes to a Mac app idling in the background were lost or delayed, so a Mac that waits for a known answer polls for it; fetching a known record took about 0.23 s.
- Re-saving a subscription lost about a minute of pushes. A first creation was not measured; this ADR assumes it behaves the same.
- Production rejects a subscription predicate on a field without a deployed queryable index.
- A push carries at most three desired keys.

The maintainer decided on 2026-11-10:

1. Stage 2 pairs a Mac with an iPhone, through a pairing-only iPhone app that stage 4 grows into the approver. Mac ↔ Mac pairing screens wait for stage 3.
2. The CloudKit container is `iCloud.com.sudohg.askkey` and the iPhone bundle ID is `com.sudohg.askkey.ios`.
3. Until stage 4 ships the iPhone app, Release builds get no CloudKit entitlement and show no Devices section; only the maintainer's Local builds do.
4. Every iPhone signature requires the current Face ID or Touch ID enrollment, with no passcode fallback. After an enrollment change the phone pairs again with each Mac, and a phone without Face ID or Touch ID set up cannot pair.

The cross review of #282 found that decision 4, taken literally, makes every message the iPhone sends prompt for Face ID, including delivery replies and unpair notices, and makes stage 4's locked-phone receipts impossible, because a notification extension cannot show Face ID. This ADR therefore applies decision 4 to a dedicated approval key, which signs the pairing confirmation and, in stage 4, approval decisions; routine messages are signed by a message key without per-use authentication. The purpose of the decision holds: nobody can pair or approve with the passcode alone. Merging this ADR is the maintainer's confirmation of that reading, and from then on this reading governs, not the literal wording above.

## Decision

### Identifiers

| Identifier | Value |
|---|---|
| CloudKit container | `iCloud.com.sudohg.askkey` |
| iPhone app bundle ID | `com.sudohg.askkey.ios` (stage 4 adds `com.sudohg.askkey.ios.notification-service`) |
| Info.plist key declaring the container | `AskKeyCloudKitContainer` |
| Mac keychain accounts (existing App service) | `device-message-key`, `device-agreement-key`, `device-approval-key`, `paired-devices` |
| iPhone keychain access group | `$(AppIdentifierPrefix)com.sudohg.askkey.ios.shared` |
| Inbox zone name | `inbox_<device ID>` |
| Record types | `AlertMessage`, `QuietMessage` |
| Subscription IDs | `inbox_<device ID>_alert`, `inbox_<device ID>_quiet` |
| Notification category | `askkey.message` |
| Alert localization keys | `push.message.title`, `push.message.body` |
| QR payload prefix | `ASKKEY-PAIR1:` |

The Mac bundle ID `com.sudohg.askkey.app` and the other product identifiers in `AGENTS.md` do not change. The probe container from #281 is not used.

### Device identity

- Each device, per storage namespace, has three CryptoKit Secure Enclave P-256 keys:
  - a **message key** (ECDSA with SHA-256), which signs every message the device sends;
  - a **key-agreement key**, used as the HPKE recipient key;
  - an **approval key** (ECDSA with SHA-256), which signs only what the person approves: in stage 2 the pairing confirmation, in stage 4 approval decisions.

  The Mac creates them when the person first starts pairing, so a Mac that never pairs gets no keychain item and makes no CloudKit request. The iPhone app, whose only purpose is pairing, creates them when its welcome screen finishes, so its subscriptions exist well before the first delivery check.
- The Secure Enclave returns each key as a wrapped blob that any process on the same device can use once it has the blob. The blobs are stored like the vault key:
  - Mac: the login keychain, under the existing App service with the App-only access already used for the vault key, accounts `device-message-key`, `device-agreement-key` and `device-approval-key`.
  - iPhone: the data protection keychain, accessible after first unlock, this device only, in the access group above, so the stage 4 notification extension can read the message and key-agreement keys.
- Key access control:
  - Message and key-agreement keys, on both platforms: `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` with `privateKeyUsage` and no per-use authentication. Routine messages (requests, replies, unpair notices) are signed and decrypted without a prompt, including by a locked phone's notification extension and a Mac with a locked screen in stage 4.
  - iPhone approval key: `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` with `privateKeyUsage` and `biometryCurrentSet`. Each approval signature uses a new authentication context that is invalidated afterwards, whether it succeeded or was cancelled, so every signature asks for Face ID or Touch ID; an earlier authentication or the phone's unlock is never reused. Enrolling a new face or finger invalidates the key; the phone then has to pair again with each Mac. The prompt offers no passcode button (an empty fallback title); separately, the key's access control is what keeps a passcode from satisfying it. An enrollment change shows up the next time the approval key is used, which in stage 2 is the next pairing and in stage 4 the next approval; the key then fails and the identity is reported unusable. A phone without Face ID or Touch ID set up cannot pair.
  - Mac approval key: `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` with `privateKeyUsage` and no per-use authentication. Every human step on the Mac is already gated by the management session and system authentication in the App. A Mac approval signature therefore does not prove at the Secure Enclave level that the person was present; stage 3 has to gate a Mac's remote decision in the App, as ADR 0002 does for local ones, and cannot strengthen this key's protection without the Mac pairing again.
- **Invariant for later stages.** A message that creates or widens trust or authority (a pairing confirmation now, an approval decision in stage 4) must carry an approval-key signature. A kind signed only by the message key may only reduce trust (an unpair notice) or carry no authority (a delivery reply).
- "Nobody can pair or approve with the passcode alone" assumes the iPhone runs the genuine app: a Mac cannot verify how a peer's keys are protected, because there is no attestation and the platform byte is self-declared. Someone with the unlocked phone and its passcode can still send what the message key signs, such as an unpair notice or a delivery reply.
- The device module has no default access control: every caller passes the protection for each key explicitly.
- If a stored key no longer works, for example after Migration Assistant or a Time Machine restore copied the login keychain to another Mac, or after a Face ID or Touch ID enrollment change invalidated the iPhone approval key, the device reports that its identity is unusable. The Devices section then offers one action that deletes the keys and the list so the person can pair again.
- A device without a Secure Enclave cannot pair, and the Devices section says so. No shipped build falls back to software keys; software keys exist only in the test-only target `AskKeyDevicesTestSupport`.
- The development and production namespaces have separate identities, because they use separate keychain services.
- Local erase stops the device services first (see Removal and account changes), then deletes the three keys and the paired-device list. Backups (ADR 0012) contain none of them, so a Mac restored from a backup is a new device and pairs again. Replacing keys means removing the device and pairing again; there is no rotation protocol.
- CryptoKit's Secure Enclave key-agreement key opens HPKE `P256_SHA256_AES_GCM_256` messages in base and PSK modes. This was run on the maintainer's Mac (a recent macOS) with in-memory Secure Enclave keys: wrong pre-shared keys and wrong info strings were refused, and a key restored from its wrapped blob had the same public key. On iOS the same code was only type-checked, for the iOS 17 deployment target, as it was for macOS 14; nothing ran on an iPhone or on macOS 14. That a key with this protection works in a locked phone's notification extension is an assumption that stage 4 verifies before release; if it fails, identities are reset and devices pair again, which before stage 4 affects only the maintainer's own test pairing (decision 3).

### Encodings

- Every domain label below is ASCII followed by one NUL byte.
- **Device ID**: the first 16 bytes of SHA-256 over `AskKey device id v1` and the message key's compressed public key, written as lowercase RFC 4648 Base32 without padding (26 characters). Decoding is canonical: only lowercase is accepted and the two unused trailing bits must be zero, so each ID has exactly one text form. It is not secret.
- **Device card**, version 1, a fixed binary layout: version (1 byte), platform (1 byte: 1 macOS, 2 iOS), creation time (8 bytes, big-endian Unix seconds), message, key-agreement and approval public keys (33 bytes each, compressed), then a 64-byte raw ECDSA signature by the message key over `AskKey device card v1` and the preceding bytes, 173 bytes in all. The device ID is derived from the card, never stored in it. The platform byte is what the device says about itself; the interface never presents it as verified. Display names are not in the card.
- **Display names** travel only inside sealed payloads as UTF-8, at most 64 Unicode scalars and 256 bytes, after removing control characters (category Cc) and the bidirectional formatting characters U+061C, U+200E, U+200F, U+202A–U+202E and U+2066–U+2069; the receiving side applies the same rule before showing one. Cards whose public keys equal this device's own keys or another entry's are refused.
- Integers and times are big-endian; times are 8-byte Unix seconds. Inside binary structures a device ID or message ID is its 16 raw bytes; the Base32 form appears only in CloudKit record names, zone names and fields.
- **Inner message**: version (1 byte), kind (1 byte), sender ID, recipient ID and message ID (16 bytes each), sent time and expiry time (8 bytes each), payload length (4 bytes), payload, then a 64-byte raw ECDSA signature by the sender's message key over `AskKey message v1` and every preceding byte. Payload fields of variable length carry a 4-byte length prefix; #284 fixes each kind's payload layout and documents it with test vectors.
- **Body**: version (1 byte), the HPKE encapsulated key (65 bytes, uncompressed P-256 point), then the HPKE ciphertext of the inner message. Every message uses a new single-shot HPKE context; no context is reused across messages. The mode follows from the kind: PSK for kinds 1 and 5, base mode for every other kind.
- **HPKE info**: `AskKey HPKE v1`, the version (1 byte), the sender ID and the recipient ID (16 bytes each), taken from the record's plaintext `sender` and `recipient` fields; after decryption both must equal the signed IDs, and in a pairing request or withdrawal the signed sender ID must equal the ID derived from the enclosed card. The receiver picks the HPKE mode from the record's plaintext `kind` and checks it against the signed kind.
- **Derived keys**: HKDF-SHA256 outputs are 32 bytes unless stated otherwise; the comparison code uses 4.
- Signatures cover the exact bytes that are sent. Nothing is re-serialized before a signature is verified.
- #284's tests include fixed test vectors for the QR payload, the pre-shared key, the transcript hash and the comparison code.

### Paired-device list

- Each device's own list is its only source of trust. Nothing read from CloudKit is trusted unless it is signed by a key on that list, or belongs to a pairing session this device started or joined.
- An entry holds the peer's device card, the pairing ID, a local display name, the platform, the paired time, the last time the peer was reached, and the last delivery check result.
- On the Mac the list is the keychain item `paired-devices` under the App service, authenticated in the manner of the agent access policy: the item holds a versioned serialization of the list and an HMAC-SHA256 tag over `AskKey paired devices v1` (with its NUL) and those exact stored bytes, under a key derived from the vault key with HKDF-SHA256, an empty salt and the info `AskKey paired devices key v1` (with its NUL). The tag is checked before the bytes are decoded, and the bytes are never re-encoded for the check. A list that fails authentication is refused, not repaired. There is no database schema change, no ADR 0001 amendment and no downgrade limit.
- On the iPhone the list is a data protection keychain item in the access group above, accessible after first unlock, this device only. Only the app process writes it; stage 4's notification extension records delivery results in a separate item and never adds or restores an entry, because the keychain offers no compare-and-swap between processes.
- A device holds at most 8 paired devices.
- Every change to the list (adding, renaming, removing, recording a delivery check) is one serialized read, modify and write. A change prepared before a removal re-reads the list when it commits, and is dropped if its entry is gone or its pairing ID differs. Removing a peer also ends any pairing session or delivery check with it, so only a new pairing can add it back.

### CloudKit layout

- Container `iCloud.com.sudohg.askkey`, private database only, so paired devices must be signed in to the same Apple ID. Every signed build uses the Production environment.
- **Subscriptions belong to the account, not to the device.** Apple's [Technical Q&A QA1917](https://developer.apple.com/library/archive/qa/qa1917/_index.html) states that CloudKit subscriptions are per-user and that a notification is not delivered to the device that made the change. Developer reports agree that a subscription's pushes reach every device of the account that runs the app ([forum thread](https://developer.apple.com/forums/thread/24420)). A push therefore says nothing about which device it is for. Every query notification carries the record ID, whose zone is the recipient's inbox, and the subscription ID; a device ignores pushes for zones other than its own. The desired keys are `kind`, `recipient` and `sender`; like every plaintext field they are routing hints, checked against the signed message after decryption. Whether pushes for a subscription saved by the iPhone app also reach the Mac app, which has a different bundle ID, is not documented; #290 records what happens.
- **One inbox zone per device**, named `inbox_<device ID>`. A device creates its zone and its two subscriptions once, when its identity is first published. On later launches it fetches them by ID: a subscription counts as missing only when CloudKit answers that the item does not exist, and only then is it created again. A fetched subscription whose definition (zone, record type, predicate, options, notification settings, comparing only fields CloudKit returns unchanged) differs from this ADR has been replaced by someone else; the device saves the correct one once and logs it. Other fetch errors are retried later and never lead to a save. It never saves a matching subscription again. Each save is logged with its subscription ID and time.
- A device never creates another device's zone. A send that fails because the recipient's zone does not exist shows that device as unreachable. When a device finds its own zone missing, it creates the zone and its subscriptions again and logs it.
- **Two record types with the same fields**: `sender` and `recipient` (device IDs, strings), `kind` (integer), `sentAt` and `expiresAt` (dates), and `body` (bytes, the HPKE ciphertext). The record name is the message ID. `AlertMessage` may show a notification on an iPhone; `QuietMessage` never does. Stage 4 adds message kinds, not record types, fields or subscriptions. Stage 3 starts with its own investigation of push delivery to a Mac in the background (#281) and may change that.
- **Subscriptions** are query subscriptions on the device's own inbox zone with `TRUEPREDICATE` and the single option `firesOnRecordCreation`, so no field needs a queryable index in Production and deleting a processed message sends no push.
  - iPhone `AlertMessage` (`inbox_<device ID>_alert`): an alert with title and body localization keys `push.message.title` and `push.message.body`, the default sound, mutable content, category `askkey.message`, and desired keys `kind`, `recipient` and `sender`. Every setting that stage 4's notification extension needs is set now, because changing a subscription means saving it again.
  - iPhone `QuietMessage`, and both Mac subscriptions: content-available only, with the same desired keys.
- **Push is a hint.** A device that waits for an answer polls its own inbox with a zone change token. Tokens are stored with the App's local state, per storage namespace and per iCloud account together with the account's user record ID, so an account change is noticed; losing them only causes a full fetch. #281 measured fetching a known record, not zone-change fetches, so the polling cost is unmeasured. Polling runs about once a second while a pairing sheet is open, and every two seconds for up to a minute after a delivery check; a reply that arrives later, within the check's 10-minute lifetime, is still accepted.
- **Change tokens.** A device saves the new token only after every message the fetch returned has been processed and its effect committed. If any message could not be processed, it keeps the old token, so the next fetch returns that message again; no retry queue is needed. A message that fails three times is treated as refused and deleted, so one bad record cannot hold the token back forever. When CloudKit reports the token expired, the device fetches its whole inbox again from no token; the list and the processed-message IDs are kept. A record that fails to fetch is retried at the next poll.
- **Retention.** The recipient deletes a message after processing it, and deletes at once a message it refuses for good (wrong recipient, bad signature or decryption, unknown sender outside a session, a mismatched binding). Every device deletes expired messages in its own inbox when it polls. Within one fetch, pairing messages are processed before the others. A message from the peer of an open pairing session that arrives before that peer is on the list, such as a delivery check that overtakes the confirmation, is kept for a retry until the session ends rather than refused. Lifetimes: pairing messages (kinds 1–5) expire with their session, at most 10 minutes; a delivery check and its reply live 10 minutes; an unpair notice lives 30 days, so a device that stays offline for weeks still learns of the removal.
- The schema is committed as `CloudKit/schema.ckdb`. The maintainer imports it into the Development environment and deploys it to Production in #290; record type and field names are final from then on.
- Debug, E2E and CI builds never create a `CKContainer`, which terminates an app that lacks the entitlement. The App creates the CloudKit transport only when its Info.plist has `AskKeyCloudKitContainer` and its signed entitlements contain that container.
- Anyone who can write to the account's private database, any app build or device signed in to that Apple ID included, can:
  - read every record, which holds only routing data and ciphertext;
  - delete records, zones and subscriptions, which only stops delivery until the device notices and creates them again;
  - insert records, which recipients refuse unless they are signed by a paired device;
  - create subscriptions of its own, or replace this design's, with alerts that show any text and no mutable content. Every device of the account that runs Ask Key then shows a system notification under Ask Key's name with text the attacker chose. Neither the app nor a notification extension runs for such a push, so nothing can rewrite or suppress it, not even with Apple's notification filtering entitlement.

  The product rule follows: Ask Key never asks the person to act on a notification's text, category or action. Every action happens in the app, on content the app decrypted and verified. Stage 4 designs approval notifications under that rule.

### Sealed messages

- Every message is an inner message signed with the sender's message key and sealed with HPKE `P256_SHA256_AES_GCM_256` to the recipient's key-agreement key, in the layouts under Encodings. Message IDs are 16 random bytes. Pairing requests and withdrawals use PSK mode (see Pairing); every other kind uses base mode. Signing inside the encryption, with the recipient ID under the signature, keeps a message from being re-encrypted to another device.
- **What each kind is bound to.** Every payload names what it belongs to, and the recipient refuses a message whose binding does not match its own state:

  | Kind | Code | Record type | Bound to |
  |---|---|---|---|
  | Pairing request (PSK mode) | 1 | `QuietMessage` | session ID (and the PSK) |
  | Pairing challenge | 2 | `QuietMessage` | session ID and the digest of the frozen request |
  | Pairing confirmation | 3 | `QuietMessage` | transcript hash, role and signer |
  | Pairing cancellation | 4 | `QuietMessage` | session ID |
  | Pairing withdrawal (PSK mode, a responder without a challenge) | 5 | `QuietMessage` | session ID |
  | Unpair notice | 6 | `QuietMessage` | pairing ID |
  | Delivery check | 7 | `AlertMessage` | pairing ID |
  | Delivery check reply | 8 | `QuietMessage` | pairing ID and the check's message ID |

  The **pairing ID** is the first 16 bytes of SHA-256 over `AskKey pairing id v1` and the transcript hash; both sides store it in the entry. Pairing again creates a new pairing ID, so a notice or reply from an earlier pairing of the same two devices is refused.
- The recipient refuses, without telling the sender:
  - a sender that is not on its list, except the messages of a pairing session it started or joined;
  - a recipient ID that is not its own;
  - a failed decryption or signature;
  - plaintext record fields (`sender`, `recipient`, `kind`, `sentAt`, `expiresAt`, record name) that differ from the signed ones;
  - an expiry in the past, a sent time more than 5 minutes in the future, or a lifetime longer than the kind allows;
  - a binding that does not match, or a record type other than the one the table gives for the kind;
  - a message ID it has already processed.

  Refusals are logged locally without content.
- Processed message IDs are kept in memory until their expiry. A message re-inserted after a restart cannot do harm in stage 2: session messages die with their in-memory session, a delivery reply only matches the check it answers, and an unpair notice only matches the current pairing ID, whose removal is idempotent. Stage 4 decides how approval decisions are protected across restarts.

### Pairing

The Mac is the initiator and the device that scans its QR code is the responder. Each side runs one session at a time.

1. **QR code.** On the Mac, in the management session: Settings → Devices → **Pair a Device…**. The Mac creates its identity, inbox and subscriptions if needed, then creates a session: a random 16-byte session ID, a random 32-byte pairing secret, a QR expiry 5 minutes ahead and a session expiry 5 minutes after that. The QR code is `ASKKEY-PAIR1:` followed by unpadded Base64url of the binary payload: version (1 byte), session ID, pairing secret, QR expiry (8 bytes), and the Mac's message and key-agreement public keys (33 bytes each, compressed). The payload is 123 bytes; with the 13-character prefix the text is 177 characters, and never more than 200. It is not a URL, so `askkey://` stays unregistered, and it holds no names.
2. **Request.** The responder scans the code in its own app, refuses it if it has expired, and sets its own session expiry to the QR expiry plus 5 minutes. It writes a pairing request into the Mac's inbox, sealed in HPKE PSK mode: the pre-shared key is HKDF-SHA256 over the pairing secret, with the session ID as salt and `AskKey pairing psk v1` as info; the pre-shared key ID is the session ID. The signed payload holds the session ID, the responder's device card and its proposed display name. A responder that resends its request keeps the same message ID. Only a device that read the QR code can produce a request the Mac can open.
3. **Challenge.** The Mac freezes the first request it opens and fully verifies, provided it first fetched it no later than 30 seconds after the QR expiry, hides the QR code, and refuses every later request (see step 6). Only then does it draw a random 32-byte nonce and send the responder a pairing challenge, sealed in base mode to the key-agreement key in the responder's card: the session ID, the SHA-256 digest of the frozen request's inner message (its exact bytes, signature included), the Mac's device card, its display name and the nonce. The responder checks that the card's message and key-agreement keys are the ones in the QR code.
4. **Code.** Both sides compute the transcript hash, SHA-256 over `AskKey pairing transcript v1`, the binary QR payload, the responder's device card, the Mac's device card and the nonce, and the code: the first 4 bytes of HKDF-SHA256 over the pairing secret, with the transcript hash as salt and `AskKey comparison code v1` as info, read as a big-endian integer modulo 1,000,000 and written as six digits, `123 456`. The responder shows the code only after a verified challenge, with the Mac's display name; the Mac shows it with the responder's platform and proposed name, and asks the person to confirm only if the iPhone shows the same code. Until the person confirms, the Mac does not show whether the responder has confirmed. A responder that has sent a request but has no challenge after 60 seconds sends a withdrawal and tells the person that the pairing failed and that, if the Mac shows a code, they must not confirm it.
5. **Confirmation.** The person compares the codes and confirms on each side. Each side then sends a pairing confirmation carrying an approval-key signature over `AskKey pairing confirmation v1`, its role (1 initiator, 2 responder), its own device ID and the transcript hash.
   - On the iPhone, that approval-key signature is what asks for Face ID or Touch ID.
   - On the Mac, confirming asks for system authentication first. If the responder's confirmation has not arrived yet, the Mac keeps that authentication for this session only and adds the device as soon as the confirmation arrives, without asking again, provided the management session in which the person authenticated is still open; locking management or closing its window cancels the pairing session. Until the session ends, an open pairing sheet keeps the management session from expiring for idleness.
   - A side adds the peer, with the pairing ID, only once it holds both its own confirmation and the peer's verified confirmation for the same transcript hash and the other role. A responder therefore never trusts a Mac that accepted a different card, and vice versa.
6. **Ending without a pairing.** Before a side has added the peer, a second request, the expiry, a cancellation, a withdrawal, **Codes Don't Match** or **Cancel** on either side ends its session with nothing stored, and it sends a signed cancellation to the peer it knows. A responder that has no challenge yet sends a withdrawal instead, sealed in PSK mode, so the Mac accepts it from any device that read the QR code. A session ends at its expiry whether or not the pairing succeeded or the sheet is still open. Until then, a side that has already added the peer and receives a cancellation or withdrawal for that session removes the entry this session wrote, if it still has this session's pairing ID; an older entry that the pairing replaced is not restored. Anyone who read the QR code can therefore end a session or undo its result, which costs availability, not trust. Messages that arrive after a session has ended, including after a restart, are ignored. Starting again creates a new session ID and secret.
7. **One side only.** If both people confirmed but a confirmation is lost, one side can end up trusting the other alone. Both sides list a new peer as "not reached yet" until the first delivery check between them succeeds, so either half shows it; the person removes the device and pairs again. Pairing again with a device already on the list replaces its entry and pairing ID.
8. **Delivery check.** After pairing, and whenever the person asks, the Mac sends a delivery check to the iPhone and polls for the reply. In stage 2 the iPhone replies when its app is opened; in stage 4 its notification extension replies on a locked phone, signing with the message key. The iPhone records, without content, when each delivered notification arrived and whether it found the check through the push or by polling, so a test can tell push delivery from an opened app. A check sent within about a minute of a subscription save may be lost (#281), so the person can repeat it.

The code is needed because anyone who sees the QR code, through a screen capture or over a shoulder, can produce a valid request. Because the nonce is drawn only after the Mac has frozen a request, the requester's card is fixed before anyone can compute the code, so an impostor cannot search for a card whose code matches the real phone's. The iPhone shows a code only for a challenge the real Mac addressed to it, so an impostor whose request was frozen leaves the real iPhone without a code. When both requests reach the Mac, the one-request rule makes the race visible; but anyone who can write to the account can delete the real phone's request first, and then the only sign of the attack is that the Mac shows a code and the iPhone shows none. Pairing then rests on the person not confirming on the Mac without a matching code on the iPhone; see Consequences. The iPhone has no equivalent check against a forged QR code, but a phone that pairs with a fake Mac gains that fake Mac nothing on the real Mac, which never trusted it.

### Removal and account changes

- Either side removes a peer from its own list at once, and from then on refuses its messages. That local effect is the guarantee: the device that matters for a lost phone is the Mac, which stops accepting it immediately. On the Mac removal needs the management session but no fresh authentication, because it only reduces trust.
- The device then sends a signed unpair notice with the pairing ID, and the peer removes the sender when it processes the notice. The notice can be lost, deleted by anyone who can write to the account, or expire before an offline peer comes back; the peer then keeps an entry for a device that no longer accepts its messages, and the person removes it there by hand.
- Stage 2 has nothing else to revoke. Stage 4 adds the cleanup of pending requests.
- If the iCloud account is signed out or changes, the list is kept and every peer shows as unreachable. The person removes them or signs back in. In a new account, a device that already has an identity creates its inbox and subscriptions at its next launch.
- Resetting an unusable identity also deletes the device's own inbox zone and subscriptions when CloudKit is reachable, so peers that still send to it see it as unreachable. Local erase does the same on a best-effort basis, without waiting for the network.
- Local erase first stops the device services (open sessions, polling, delivery checks), drops the keys and list held in memory, and then deletes the keychain items, so no callback that started before the erase can write afterwards.

### Mac App

- Settings gains a **Devices** section only in builds with CloudKit configured. It holds **Pair a Device…**, whose sheet shows the QR code and then the code to compare with the iPhone's, and the list (name, platform, paired date, last reached, delivery check), with **Rename**, **Test Delivery** and **Remove** for each device. It explains each unavailable state: no Secure Enclave, iCloud signed out, restricted or unavailable, an account change, an unusable identity (with the reset action), and the limit of 8.
- The Mac's string catalog also holds neutral text for `push.message.title` and `push.message.body`, in case CloudKit delivers the iPhone's alert pushes to the Mac app.
- Adding a device needs the management session and system authentication; renaming and removing need the management session. Reading the identity and list needs neither, because messages are verified in the background.
- The Broker gains no operation, and agents cannot list, pair or remove devices. The Broker protocol version is unchanged.

### iPhone app

- An iOS 17 iPhone app in `iOS/`, generated with XcodeGen from `iOS/project.yml` like `Tests/UI/project.yml`, with no third-party code dependency, linking `AskKeyDevices`.
- Screens: a welcome screen that checks the Secure Enclave, Face ID or Touch ID and the iCloud account, asks for notification permission, explains the system's wireless-data prompt that some iPhones show before an app's first network access (#281), and then creates the identity, inbox and subscriptions; the QR scanner (the camera is used only for this); the code to compare with the Mac's; the list of paired Macs; and removal. English and Simplified Chinese.
- The app's logic lives in a framework target, so its tests need no app host, and nothing on the launch path creates a CloudKit container. Its CI build runs in its own job, `ios-app`, which `release-gate.py` does not require. The Info.plist declares the camera and Face ID usage.
- No notification extension, approval screen, TestFlight or App Store submission until stage 4.

### Code layout

- The SwiftPM target `AskKeyDevices` (macOS 14, iOS 17) has no local dependencies. It holds the identity, device cards, sealed messages, the pairing state machine, the paired-device list model, the transport interface and the CloudKit transport. It stores nothing itself. CI builds it from the root package for the iOS Simulator, which is the path the iPhone app uses. Software keys and an in-memory transport live in the test-only target `AskKeyDevicesTestSupport`.
- `AskKeyVault` stores the Mac's key blobs and list, because it already owns the App-only keychain items and the vault key. `AskKeyAppKit` coordinates pairing and creates the CloudKit transport. The allowed new edges are `AskKeyVault` → `AskKeyDevices` and `AskKeyAppKit` → `AskKeyDevices`; `AskKeyBroker` and `AskKeyHelper` do not depend on it.

### Build and release

- `scripts/build-app.sh` gains a CloudKit option, accepted only for `Local` builds. Before signing, it embeds a Developer ID provisioning profile and adds `AskKeyCloudKitContainer` to the Info.plist; it then signs the App with `com.apple.application-identifier`, `com.apple.developer.team-identifier`, `com.apple.developer.icloud-services = [CloudKit]`, `com.apple.developer.icloud-container-identifiers = [iCloud.com.sudohg.askkey]`, `com.apple.developer.icloud-container-environment = Production` and `com.apple.developer.aps-environment = production`, and reads back the profile and the signed entitlements. Team-dependent values come from the environment at build time; no Team ID, signing identity or profile is committed. Without the option, every build is the same as before.
- `Release` refuses the option until stage 4 ships the iPhone app. README, `SECURITY.md` ("update checks are the only outbound network requests") and the feature inventory therefore stay true for every release until then, and change in the stage that ships pairing in a Release build.

### Out of scope

Credentials, approval requests and decisions crossing devices (stages 4, 3 and 5) and the ADR 0002 amendment; Mac ↔ Mac pairing screens (stage 3); the iPhone notification extension, approval screens, TestFlight and the App Store (stage 4); pairing across Apple IDs, a self-hosted relay and direct transport; key rotation and identity recovery beyond reset and pairing again; registering `askkey://`; a software-key fallback; persisting processed message IDs across restarts, which stage 4 needs for decisions; a persistent retry queue for unpair notices; notifying peers on local erase; README and `SECURITY.md` changes before pairing reaches a Release build.

## Consequences

Two devices of the same person can trust each other without any server of ours, and stage 4 can send an approval request to the iPhone and verify its answer using this identity, list, zones, record types and subscriptions unchanged. What leaves a device is routing data and ciphertext: device IDs, message kinds, times, record names and HPKE bodies. Apple, as the operator of iCloud, can see which device IDs exchange messages and when, but not their content or the devices' names.

Pairing rests partly on the person: an attacker who saw the QR code and can write to the account can delete the real phone's request and have the Mac show a code for its own device. The iPhone then shows no code and, after 60 seconds, a warning; a person who confirms on the Mac anyway pairs the attacker, which in stage 4 would make it an approver. Asking the person to type the iPhone's code on the Mac instead of comparing would remove that dependency at the cost of typing; it is a product choice left to the maintainer, and changing it later needs no new keys or schema.

Pairing needs both devices on the same Apple ID, a Secure Enclave, and on the iPhone Face ID or Touch ID. A Face ID or Touch ID enrollment change, a local erase, or moving to a new Mac means pairing again. Because subscriptions belong to the account, a second iPhone on the same Apple ID shows the generic alert meant for the first one, and anyone who can write to the account can make every device that runs Ask Key show a notification with any text. Ask Key therefore never asks the person to act on a notification's text; stage 4 inherits that rule.

A local erase does not notify peers; they keep an entry for a device that no longer exists until the person removes it. Restoring an older copy of the Mac's login keychain, for example from Time Machine, can bring back a device that was removed after that copy was made; like other whole-library rollbacks (ADR 0001), this is not detected.

Release builds keep their current entitlements and outbound network behavior until stage 4. The identity storage, sealed messages, pairing, the paired-device list and the signing changes are `risk:security` and are reviewed line by line. CI tests pairing with software keys and an in-memory transport; the Secure Enclave, CloudKit and push are verified only on real devices in #290.
