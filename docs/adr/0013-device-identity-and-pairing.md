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

The cross review of #282 found that decision 4, taken literally, makes every message the iPhone sends prompt for Face ID, including delivery replies and unpair notices, and makes stage 4's locked-phone receipts impossible, because a notification extension cannot show Face ID. This ADR therefore applies decision 4 to a dedicated approval key, which signs the pairing confirmation and, in stage 4, approval decisions; routine messages are signed by a message key without per-use authentication. The purpose of the decision holds: nobody can pair or approve with the passcode alone. Merging this ADR is the maintainer's confirmation of that reading.

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

  The Mac creates them when the person first starts pairing. The iPhone creates them when its welcome screen finishes, so its subscriptions exist well before the first delivery check. Nothing is created at launch: a person who never pairs gets no keychain item and makes no CloudKit request.
- The Secure Enclave returns each key as a wrapped blob that any process on the same device can use once it has the blob. The blobs are stored like the vault key:
  - Mac: the login keychain, under the existing App service with the App-only access already used for the vault key, accounts `device-message-key`, `device-agreement-key` and `device-approval-key`.
  - iPhone: the data protection keychain, accessible after first unlock, this device only, in the access group above, so the stage 4 notification extension can read the message and key-agreement keys.
- Key access control:
  - Message and key-agreement keys, on both platforms: `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` with `privateKeyUsage` and no per-use authentication. Routine messages (requests, replies, unpair notices) are signed and decrypted without a prompt, including by a locked phone's notification extension and a Mac with a locked screen in stage 4.
  - iPhone approval key: `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` with `privateKeyUsage` and `biometryCurrentSet`. Each approval signature asks for Face ID or Touch ID, and enrolling a new face or finger invalidates the key; the phone then has to pair again with each Mac. Someone who knows the phone's passcode therefore cannot approve. A phone without Face ID or Touch ID set up cannot pair.
  - Mac approval key: `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` with `privateKeyUsage` and no per-use authentication. Every human step on the Mac is already gated by the management session and system authentication; stage 3 decides how a Mac's remote decision is authenticated, as ADR 0002 does for local ones.
- The device module has no default access control: every caller passes the protection for each key explicitly.
- If a stored key no longer works, for example after Migration Assistant or a Time Machine restore copied the login keychain to another Mac, or after a Face ID or Touch ID enrollment change invalidated the iPhone approval key, the device reports that its identity is unusable. The Devices section then offers one action that deletes the keys and the list so the person can pair again.
- A device without a Secure Enclave cannot pair, and the Devices section says so. No shipped build falls back to software keys; software keys exist only in the test-only target `AskKeyDevicesTestSupport`.
- The development and production namespaces have separate identities, because they use separate keychain services.
- Local erase stops the device services first (see Removal and account changes), then deletes the three keys and the paired-device list. Backups (ADR 0012) contain none of them, so a Mac restored from a backup is a new device and pairs again. Replacing keys means removing the device and pairing again; there is no rotation protocol.
- CryptoKit's Secure Enclave key-agreement key opens HPKE `P256_SHA256_AES_GCM_256` messages in base and PSK modes. This was checked on the maintainer's Mac with in-memory Secure Enclave keys (wrong pre-shared keys and wrong info strings were refused, and keys restored from their wrapped blobs kept working), and the same code type-checks for macOS 14 and iOS 17 deployment targets. No device running macOS 14 or iOS 17 was available; running on those versions is an accepted risk.

### Encodings

- Every domain label below is ASCII followed by one NUL byte.
- **Device ID**: the first 16 bytes of SHA-256 over `AskKey device id v1` and the message key's compressed public key, written as lowercase RFC 4648 Base32 without padding (26 characters). It is not secret.
- **Device card**, version 1, a fixed binary layout: version (1 byte), platform (1 byte: 1 macOS, 2 iOS), creation time (8 bytes, big-endian Unix seconds), message, key-agreement and approval public keys (33 bytes each, compressed), then a 64-byte raw ECDSA signature by the message key over `AskKey device card v1` and the preceding bytes, 173 bytes in all. The device ID is derived from the card, never stored in it. The platform byte is what the device says about itself; the interface never presents it as verified. Display names are not in the card.
- **Display names** travel only inside sealed payloads, at most 64 characters after removing control and bidirectional formatting characters; the receiving side applies the same rule before showing one.
- Signatures cover the exact bytes that are sent. Nothing is re-serialized before a signature is verified.

### Paired-device list

- Each device's own list is its only source of trust. Nothing read from CloudKit is trusted unless it is signed by a key on that list, or belongs to a pairing session this device started or joined.
- An entry holds the peer's device card, the pairing ID, a local display name, the platform, the paired time, the last time the peer was reached, and the last delivery check result.
- On the Mac the list is the keychain item `paired-devices` under the App service, authenticated with HMAC-SHA256 under a key derived from the vault key with HKDF-SHA256 and the label `AskKey paired devices v1`, like the agent access policy. A list that fails authentication is refused, not repaired. There is no database schema change, no ADR 0001 amendment and no downgrade limit.
- On the iPhone the list is a data protection keychain item in the access group above.
- A device holds at most 8 paired devices.
- Every change to the list (adding, renaming, removing, recording a delivery check) is one serialized read, modify and write. A change prepared before a removal re-reads the list when it commits, and is dropped if its entry is gone or its pairing ID differs. Removing a peer also ends any pairing session or delivery check with it, so only a new pairing can add it back.

### CloudKit layout

- Container `iCloud.com.sudohg.askkey`, private database only, so paired devices must be signed in to the same Apple ID. Every signed build uses the Production environment.
- **Subscriptions belong to the account, not to the device.** Apple's [Technical Q&A QA1917](https://developer.apple.com/library/archive/qa/qa1917/_index.html) states that CloudKit subscriptions are per-user and that a notification is not delivered to the device that made the change. Developer reports agree that a subscription's pushes reach every device of the account that runs the app ([forum thread](https://developer.apple.com/forums/thread/24420)). A push therefore says nothing about which device it is for. Its desired keys are `kind`, `recipient` and `sender`, so a device can tell from the push alone whether the message is for it, and ignores it otherwise. Whether pushes for a subscription saved by the iPhone app also reach the Mac app, which has a different bundle ID, is not documented; #290 records what happens.
- **One inbox zone per device**, named `inbox_<device ID>`. A device creates its zone and its two subscriptions once, when its identity is first published. On later launches it fetches them by ID: a subscription counts as missing only when CloudKit answers that the item does not exist, and only then is it created again. A fetched subscription whose definition (zone, record type, predicate, options, notification settings, comparing only fields CloudKit returns unchanged) differs from this ADR has been replaced by someone else; the device saves the correct one once and logs it. Other fetch errors are retried later and never lead to a save. It never saves a matching subscription again. Each save is logged with its subscription ID and time.
- A device never creates another device's zone. A send that fails because the recipient's zone does not exist shows that device as unreachable.
- **Two record types with the same fields**: `sender` and `recipient` (device IDs, strings), `kind` (integer), `sentAt` and `expiresAt` (dates), and `body` (bytes, the HPKE ciphertext). The record name is the message ID. `AlertMessage` may show a notification on an iPhone; `QuietMessage` never does. Stage 4 adds message kinds, not record types, fields or subscriptions. Stage 3 starts with its own investigation of push delivery to a Mac in the background (#281) and may change that.
- **Subscriptions** are query subscriptions on the device's own inbox zone with `TRUEPREDICATE` and the single option `firesOnRecordCreation`, so no field needs a queryable index in Production and deleting a processed message sends no push.
  - iPhone `AlertMessage` (`inbox_<device ID>_alert`): an alert with title and body localization keys `push.message.title` and `push.message.body`, the default sound, mutable content, category `askkey.message`, and desired keys `kind`, `recipient` and `sender`. Every setting that stage 4's notification extension needs is set now, because changing a subscription means saving it again.
  - iPhone `QuietMessage`, and both Mac subscriptions: content-available only, with the same desired keys.
- **Push is a hint.** A device that waits for an answer polls its own inbox with a zone change token, kept per iCloud account together with the account's user record ID so an account change is noticed: about once a second while a pairing sheet is open, and every two seconds for up to a minute after a delivery check.
- **Change tokens.** A fetch processes every message it returned, or keeps it for a retry, before it saves the new token. When CloudKit reports the token expired, the device fetches its whole inbox again from no token; the list and the processed-message IDs are kept. A record that fails to fetch is retried at the next poll.
- **Retention.** The recipient deletes a message after processing it. Every device deletes expired messages in its own inbox when it polls. Lifetimes: pairing messages end with their session; a delivery check and its reply live 10 minutes; an unpair notice lives 30 days, so a device that stays offline for weeks still learns of the removal.
- The schema is committed as `CloudKit/schema.ckdb`. The maintainer imports it into the Development environment and deploys it to Production in #290; record type and field names are final from then on.
- Debug, E2E and CI builds never create a `CKContainer`, which terminates an app that lacks the entitlement. The App creates the CloudKit transport only when its Info.plist has `AskKeyCloudKitContainer` and its signed entitlements contain that container.
- Anyone who can write to the account's private database, any app build or device signed in to that Apple ID included, can read every record, which holds only routing data and ciphertext; delete records, zones and subscriptions, which only stops delivery until the device notices and creates them again; insert records, which recipients refuse unless they are signed by a paired device; and replace a subscription with one that shows different alert text. Alert text is never trusted: the iPhone app and, in stage 4, its notification extension show only content they decrypted and verified.

### Sealed messages

- **Inner message**: format version, kind, sender device ID, recipient device ID, message ID (16 random bytes, Base32 like device IDs), sent time, expiry time and a kind-specific payload, followed by the sender's message-key signature over `AskKey message v1` and those exact bytes.
- **Body**: HPKE `P256_SHA256_AES_GCM_256` in base mode, sealed to the recipient's key-agreement key, with the info string `AskKey HPKE v1`, the format version, the sender device ID and the recipient device ID. Pairing requests, and a responder's cancellation before it has a challenge, use PSK mode instead (see Pairing). Signing inside the encryption, with the recipient ID under the signature, keeps a message from being re-encrypted to another device.
- **What each kind is bound to.** Every payload names what it belongs to, and the recipient refuses a message whose binding does not match its own state:

  | Kind | Code | Record type | Bound to |
  |---|---|---|---|
  | Pairing request | 1 | `QuietMessage` | session ID (and the PSK) |
  | Pairing challenge | 2 | `QuietMessage` | session ID and the digest of the frozen request |
  | Pairing confirmation | 3 | `QuietMessage` | transcript hash |
  | Pairing cancellation | 4 | `QuietMessage` | session ID |
  | Unpair notice | 5 | `QuietMessage` | pairing ID |
  | Delivery check | 6 | `AlertMessage` | pairing ID |
  | Delivery check reply | 7 | `QuietMessage` | pairing ID and the check's message ID |

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

1. **QR code.** On the Mac, in the management session: Settings → Devices → **Pair a Device…**. The Mac creates its identity, inbox and subscriptions if needed, then creates a session: a random 16-byte session ID, a random 32-byte pairing secret, a QR expiry 5 minutes ahead and a session expiry 10 minutes ahead. The QR code is `ASKKEY-PAIR1:` followed by unpadded Base64url of the binary payload: version (1 byte), session ID, pairing secret, QR expiry (8 bytes, big-endian Unix seconds), and the Mac's message and key-agreement public keys (33 bytes each, compressed). That is 123 bytes, 177 characters, and never more than 200. It is not a URL, so `askkey://` stays unregistered, and it holds no names.
2. **Request.** The responder scans the code in its own app and refuses it if it has expired. It writes a pairing request into the Mac's inbox, sealed in HPKE PSK mode: the pre-shared key is HKDF-SHA256 over the pairing secret, with the session ID as salt and `AskKey pairing psk v1` as info; the pre-shared key ID is the session ID. The signed payload holds the session ID, the responder's device card and its proposed display name. Only a device that read the QR code can produce a request the Mac can open.
3. **Challenge.** The Mac freezes the first request it can open and refuses every later one (see step 6). Only then does it draw a random 32-byte nonce and send the responder a pairing challenge, sealed in base mode to the key-agreement key in the responder's card: the session ID, the SHA-256 digest of the frozen request, the Mac's device card, its display name and the nonce. The responder checks that the card's message and key-agreement keys are the ones in the QR code.
4. **Comparison code.** Both sides compute the transcript hash, SHA-256 over `AskKey pairing transcript v1`, the binary QR payload, the responder's device card, the Mac's device card and the nonce, and the code: the first 4 bytes of HKDF-SHA256 over the pairing secret, with the transcript hash as salt and `AskKey comparison code v1` as info, read as a big-endian integer modulo 1,000,000 and shown as six digits, `123 456`. The responder shows the code only after the challenge arrives; the Mac also shows the responder's platform and proposed name.
5. **Confirmation.** The person compares the codes and confirms on each side, and each side sends a pairing confirmation carrying the transcript hash and an approval-key signature over `AskKey pairing confirmation v1` and the transcript hash.
   - On the iPhone, that approval-key signature is what asks for Face ID or Touch ID.
   - On the Mac, confirming asks for system authentication first. If the responder's confirmation has not arrived yet, the Mac keeps that authentication for this session only, waits until the session ends, and adds the device as soon as the confirmation arrives without asking again. An open pairing sheet keeps the management session from expiring for idleness.
   - A side adds the peer, with the pairing ID, only once it holds both its own confirmation and the peer's verified confirmation with the same transcript hash. A responder therefore never trusts a Mac that accepted a different card, and vice versa.
6. **Ending without a pairing.** Before a side has added the peer, a second request, the session expiry, a cancellation, or **Codes Don't Match** ends its session with nothing stored, and it sends a signed cancellation to every peer it knows in that session. A responder that has not received a challenge seals its cancellation in PSK mode, so the Mac accepts a cancellation from any device that read the QR code; the worst it can do is end the session. A side that has already added the peer and then receives a cancellation for the same session removes the peer again. Messages that arrive after a session has ended are ignored. Starting again creates a new session ID and secret.
7. **One side only.** If both people confirmed but a confirmation is lost, one side can end up trusting the other alone. Both sides list a new peer as "not reached yet" until the first delivery check between them succeeds, so either half shows it; the person removes the device and pairs again. Pairing again with a device already on the list replaces its entry and pairing ID.
8. **Delivery check.** After pairing, and whenever the person asks, the Mac sends a delivery check to the iPhone and polls for the reply. In stage 2 the iPhone replies when its app is opened; in stage 4 its notification extension replies on a locked phone, signing with the message key. The iPhone records, without content, when each delivered notification arrived and whether it found the check through the push or by polling, so a test can tell push delivery from an opened app. A check sent within about a minute of a subscription save may be lost (#281), so the person can repeat it.

The comparison code is needed because anyone who sees the QR code, through a screen capture or over a shoulder, can produce a valid request. The code ties the Mac's confirmation to the device the person is holding. Because the nonce is drawn only after the Mac has frozen a request, the requester's card is fixed before anyone can compute the code: an impostor cannot search for a card whose code matches the real phone's, even if it knows both devices' cards. The one-request rule turns a race between the two into a visible failure.

### Removal and account changes

- Either side removes a peer from its own list at once, and from then on refuses its messages. That local effect is the guarantee: the device that matters for a lost phone is the Mac, which stops accepting it immediately. On the Mac removal needs the management session but no fresh authentication, because it only reduces trust.
- The device then sends a signed unpair notice with the pairing ID, and the peer removes the sender when it processes the notice. The notice can be lost, deleted by anyone who can write to the account, or expire before an offline peer comes back; the peer then keeps an entry for a device that no longer accepts its messages, and the person removes it there by hand.
- Stage 2 has nothing else to revoke. Stage 4 adds the cleanup of pending requests.
- If the iCloud account is signed out or changes, the list is kept and every peer shows as unreachable. The person removes them or signs back in. A new account gets an inbox and subscriptions at the next pairing.
- Local erase first stops the device services (open sessions, polling, delivery checks), drops the keys and list held in memory, and then deletes the keychain items, so no callback that started before the erase can write afterwards.

### Mac App

- Settings gains a **Devices** section only in builds with CloudKit configured. It holds **Pair a Device…** and the list (name, platform, paired date, last reached, delivery check), with **Rename**, **Test Delivery** and **Remove** for each device. It explains each unavailable state: no Secure Enclave, iCloud signed out, restricted or unavailable, an account change, an unusable identity (with the reset action), and the limit of 8.
- The Mac's string catalog also holds neutral text for `push.message.title` and `push.message.body`, in case CloudKit delivers the iPhone's alert pushes to the Mac app.
- Adding a device needs the management session and system authentication; renaming and removing need the management session. Reading the identity and list needs neither, because messages are verified in the background.
- The Broker gains no operation, and agents cannot list, pair or remove devices. The Broker protocol version is unchanged.

### iPhone app

- An iOS 17 iPhone app in `iOS/`, generated with XcodeGen from `iOS/project.yml` like `Tests/UI/project.yml`, with no third-party code dependency, linking `AskKeyDevices`.
- Screens: a welcome screen that checks the Secure Enclave, Face ID or Touch ID and the iCloud account, asks for notification permission and then creates the identity, inbox and subscriptions; the QR scanner (the camera is used only for this); the comparison code; the list of paired Macs; and removal. English and Simplified Chinese.
- The app's logic lives in a framework target, so its tests need no app host, and nothing on the launch path creates a CloudKit container. Its CI build runs in its own job, `ios-app`, which `release-gate.py` does not require. The Info.plist declares the camera and Face ID usage.
- No notification extension, approval screen, TestFlight or App Store submission until stage 4.

### Code layout

- The SwiftPM target `AskKeyDevices` (macOS 14, iOS 17) has no local dependencies. It holds the identity, device cards, sealed messages, the pairing state machine, the paired-device list model, the transport interface and the CloudKit transport. It stores nothing itself. CI builds it from the root package for the iOS Simulator, which is the path the iPhone app uses. Software keys and an in-memory transport live in the test-only target `AskKeyDevicesTestSupport`.
- `AskKeyVault` stores the Mac's key blobs and list, because it already owns the App-only keychain items and the vault key. `AskKeyAppKit` coordinates pairing and creates the CloudKit transport. The allowed new edges are `AskKeyVault` → `AskKeyDevices` and `AskKeyAppKit` → `AskKeyDevices`; `AskKeyBroker` and `AskKeyHelper` do not depend on it.

### Build and release

- `scripts/build-app.sh` gains a CloudKit option, accepted only for `Local` builds. Before signing, it embeds a Developer ID provisioning profile and adds `AskKeyCloudKitContainer` to the Info.plist; it then signs the App with `com.apple.application-identifier`, `com.apple.developer.team-identifier`, `com.apple.developer.icloud-services = [CloudKit]`, `com.apple.developer.icloud-container-identifiers = [iCloud.com.sudohg.askkey]`, `com.apple.developer.icloud-container-environment = Production` and `com.apple.developer.aps-environment = production`, and reads back the profile and the signed entitlements. Team-dependent values come from the environment at build time; no Team ID, signing identity or profile is committed. Without the option, every build is the same as before.
- `Release` refuses the option until stage 4 ships the iPhone app. README, `SECURITY.md` ("update checks are the only outbound network requests") and the feature inventory therefore stay true for every release until then, and change in the stage that ships pairing in a Release build.

## Consequences

Two devices of the same person can trust each other without any server of ours, and stage 4 can send an approval request to the iPhone and verify its answer using this identity, list, zones, record types and subscriptions unchanged. What leaves a device is routing data and ciphertext: device IDs, message kinds, times, record names and HPKE bodies. Apple, as the operator of iCloud, can see which device IDs exchange messages and when, but not their content or the devices' names.

Pairing needs both devices on the same Apple ID, a Secure Enclave, and on the iPhone Face ID or Touch ID. A Face ID or Touch ID enrollment change, a local erase, or moving to a new Mac means pairing again. Because subscriptions belong to the account, a second iPhone on the same Apple ID shows the generic alert meant for the first one, and anyone who can write to the account can make a paired iPhone show the generic alert. The device ignores such messages, but without Apple's notification filtering entitlement, which stage 4 may request, an extension can only rewrite an alert, not suppress it.

A local erase does not notify peers; they keep an entry for a device that no longer exists until the person removes it. Restoring an older copy of the Mac's login keychain, for example from Time Machine, can bring back a device that was removed after that copy was made; like other whole-library rollbacks (ADR 0001), this is not detected.

Release builds keep their current entitlements and outbound network behavior until stage 4. The identity storage, sealed messages, pairing, the paired-device list and the signing changes are `risk:security` and are reviewed line by line. CI tests pairing with software keys and an in-memory transport; the Secure Enclave, CloudKit and push are verified only on real devices in #290.
