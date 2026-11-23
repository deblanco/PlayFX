# RP crypt: key derivation and payload cipher

"RP crypt" is the symmetric cipher that Remote Play uses for:

- the **registration** request body and response body (see [registration.md](registration.md)), and
- the **session**: the encrypted fields of the ctrl request, ctrl message payloads, and the launch
  specification (see [session.md](session.md) and [ctrl.md](ctrl.md), which say *which* bytes are encrypted
  and with which counter; this document says *how*).

Every use works on a **cipher context** of three 16-byte values:

| Name | Size | Meaning |
|------|------|---------|
| `K`  | 16   | AES-128 key |
| `S`  | 16   | IV seed: mixed with a counter to make each operation's IV |
| `H`  | 16   | HMAC key used to turn (`S`, counter) into an IV; a constant picked by console type/version |

Only the way `K` and `S` are produced differs between modes. The cipher itself (section 2) is the same for
all modes.

## 1. Versions ("targets")

The derivations depend on the console family and its Remote Play protocol version. This spec calls the
combination the **target**:

| Target | Meaning | Where the version comes from |
|--------|---------|------------------------------|
| `PS4-8`  | PS4, RP-Version `8.0`  | session response `RP-Version`, or discovery `system-version` (registration) |
| `PS4-9`  | PS4, RP-Version `9.0`  | same |
| `PS4-10` | PS4, RP-Version `10.0` | same |
| `PS5-1`  | PS5, RP-Version `1.0`  | same |

`PS4-8` and `PS4-9` use the **legacy** derivations ("P9" below). `PS4-10` and `PS5-1` use the **table**
derivations. Throughout this document "PS4" in a table name means `PS4-10`, "PS5" means `PS5-1`.

How a client picks the target for registration is in [registration.md](registration.md#target-selection); for
the session it is the console's `RP-Version` answer (see session.md).

## 2. The cipher (all modes)

### 2.1 IV for counter `c`

`c` is an unsigned 64-bit counter. Let `BE64(c)` be its 8-byte big-endian encoding.

```
IV(c) = first 16 bytes of HMAC-SHA256(key = H, message = S || BE64(c))
```

The HMAC message is exactly 24 bytes (`S` then the counter). The HMAC key is the 16-byte `H`.

### 2.2 Encrypt / decrypt

- Algorithm: **AES-128 in CFB mode with a 128-bit feedback segment** (NIST SP 800-38A "CFB128"; OpenSSL
  `aes-128-cfb`, CommonCrypto `kCCModeCFB`). Key `K`, IV `IV(c)`.
- No padding. Output length equals input length; the last partial block uses only as many keystream bytes
  as needed.
- **Each operation is independent**: it starts from `IV(c)` with a fresh CFB state. No cipher state carries
  over from one call to the next, even with the same context. The only thing that links operations is the
  counter value the caller picks.
- Decrypt is the CFB inverse with the same key and IV (CFB uses the AES *encrypt* direction for both).

CFB128 restated byte-wise, for an input of `n` bytes, blocks `P_1..P_m` (the last possibly short):

```
X_1 = IV(c)
O_j = AES-128-Encrypt(K, X_j)
C_j = P_j XOR O_j            (truncated to the length of P_j)
X_{j+1} = C_j                (full 16-byte ciphertext block)
```

Decrypt: `P_j = C_j XOR O_j`, `X_{j+1} = C_j`.

### 2.3 Keystream-only use

Some session fields are not CFB-encrypted directly. Instead the client takes `n` zero bytes, encrypts
them with the context at counter 0 (section 2.2), and XORs the result onto the plaintext:

```
out = P XOR Encrypt(context, c = 0, 0x00 * n)
```

This is **not** the same as `Encrypt(context, 0, P)` beyond the first 16 bytes (encrypting zeros makes the
feedback equal the keystream, i.e. it behaves like OFB). session.md says where this is used (the launch
specification).

### 2.4 HMAC key `H` by target

| Target | `H` (hex) | Data file |
|--------|-----------|-----------|
| `PS4-8`, `PS4-9` | `ac078883c83a1fe811463af39ee3e377` | `data/iv-hmac-key-p9.hex` |
| `PS4-10`         | `20d66f5904ea7c14e557ffc52e488ac8` | `data/iv-hmac-key-ps4.hex` |
| `PS5-1`          | `464687b349ca8ce859c5270f5d7a69d6` | `data/iv-hmac-key-ps5.hex` |

Observed quirk: when a PS5 reports an `RP-Version` other than `1.0`, the reference client still uses the PS5
tables for `K`/`S` but the **PS4-10** `H`. Whether any real console needs that is unknown
(see Open questions). An implementation that only supports `PS5-1` never hits this.

## 3. Constant tables

All constant tables are in [`data/`](data/). File format:

- ASCII, lowercase hexadecimal, two hex digits per byte, no `0x`, no separators inside a line.
- One table row per line, ending in `\n`; the row width is given below. Rows are a convenience: the table is
  simply all lines concatenated, in file order.
- The SHA-256 below is over the **decoded bytes** (not the text file).

| File | Bytes | Row width | SHA-256 of the decoded bytes |
|------|------:|----------:|------------------------------|
| `p9-nonce-mask.hex`   |   16 |  16 | `3083df1d0164f85f72eadfafdd1540b1c99fecaf6812099c0015367e2bde2df9` |
| `p9-mask.hex`         |   16 |  16 | `1765b69e117a12e22040374414d877f3af2d0eb0026495b9bee9c192a29d9a8b` |
| `p9-regist-key.hex`   |   16 |  16 | `5575c2a21c0d04ef2d8d0a5a9ff6208b7544824471d9ed73513eeafd80e45dde` |
| `session-seed-ps4.hex`| 3584 | 112 | `2966fd3c1ba2fdd1fdeb8db5fbd9ef6fa41e4b4b351a724a36e653ffcd786696` |
| `session-seed-ps5.hex`| 3584 | 112 | `1db53dc52e9259b87d3b4e6c93ed008eb3aeed3a05d8dbeb27ce12c92511beb9` |
| `session-key-ps4.hex` | 3584 | 112 | `42a65bb3ca48909313574cd37805bf0435f78cfc884538f828dffb343042286e` |
| `session-key-ps5.hex` | 3584 | 112 | `22f6776ae81cc9bf2e562abee4618e3a32557875af5cd346145a5f2a5d81009b` |
| `regist-key-ps4.hex`  |  512 |  32 | `e7d94548c4b9dba6076a89ba1dfb466cf7b635fcbc4e9efc8ec844d946c6df75` |
| `regist-key-ps5.hex`  |  512 |  32 | `53b11608360076562655967ca89d6bd5e9b8c05220644075bb49876c95cd3965` |
| `regist-mask-ps4.hex` |  512 |  32 | `4aacf71fe36d53b46faa277a04c73e3c115eb3d4b4ae7732e919a6d1b35f5f54` |
| `regist-mask-ps5.hex` |  512 |  32 | `3299d292a30e9be23c16a79bdd1a7cf8862a973ead751fd20d6d7c48154edeb0` |
| `iv-hmac-key-p9.hex`  |   16 |  16 | `3a38d06e6602d3f284dc066037187ba37e3f81fabf2cd5ef4f13403ed21899a8` |
| `iv-hmac-key-ps4.hex` |   16 |  16 | `4942743098a7bad11e2be8c2e899d3fcae52de3fc4df4edeafd979d734c31818` |
| `iv-hmac-key-ps5.hex` |   16 |  16 | `880c56eda992313f9aaa57e70e725b72b4371253beba1fabf60a83fe3d429a37` |

The 16-byte tables, inline for convenience:

| Name | Hex |
|------|-----|
| `P9N` = `p9-nonce-mask` | `0149879b65398b394b3a8d48c30aef51` |
| `P9M` = `p9-mask`       | `e1ec9c3addbd0885fc0e1d789032c004` |
| `P9R` = `p9-regist-key` | `3f1cc4b6dcbb3ecc50baedef9734c7c9` |

Indexing (`T[x]` means byte `x` of the concatenated table, 0-based):

- `session-seed-*` and `session-key-*` are 32 rows of 112 (`0x70`) bytes. A derivation picks row
  `r` (0..31) and uses bytes `T[r*0x70 + i]` for `i = 0..15`. Bytes 16..111 of each row are never read, but they
  are part of the table and of its hash.
- `regist-key-*` and `regist-mask-*` are 16 rows of 32 (`0x20`) bytes. A derivation picks a column `o`
  (0..31) and uses `T[i*0x20 + o]` for `i = 0..15`; that is, output byte `i` comes from row `i`.

## 4. Notation for the derivations

All arithmetic on bytes is **mod 256** (wrap-around), `+`/`-` are integer add/subtract then mod 256, `^` is
XOR, `>>` is a logical right shift, `&` is bitwise AND. `i` always runs over `0..15`. A constant written
`-0x2d` means the byte `0xd3`.

`PIN` is the registration PIN as an unsigned 32-bit integer (see registration.md), and
`PINB = BE32(PIN)` its 4-byte big-endian encoding: `PINB[0]` is the most significant byte.

## 5. Session mode (after a successful session request)

Inputs:

- `N` = the 16-byte nonce the console returns in the session response header `RP-Nonce` (base64 there;
  decoded here). See session.md.
- `R` = the 16-byte `RP-Key` from registration (registration.md, "Pairing record").

### 5.1 `PS4-10` and `PS5-1`

Tables: `A` = `session-seed-ps4` / `session-seed-ps5`, `B` = `session-key-ps4` / `session-key-ps5`.

```
a = N[0] >> 3          (row 0..31 of A)
b = N[7] >> 3          (row 0..31 of B)

PS4-10:  S[i] = (N[i] + 0x36 + i) ^ A[a*0x70 + i]
         K[i] = ((B[b*0x70 + i] ^ R[i]) + 0x21 + i) ^ N[i]

PS5-1:   S[i] = (N[i] - 0x2d - i) ^ A[a*0x70 + i]
         K[i] = (R[i] + 0x18 + i) ^ N[i] ^ B[b*0x70 + i]
```

`H` per section 2.4.

### 5.2 `PS4-8` and `PS4-9` (legacy)

```
S[i] = (N[i] - i - 0x27) ^ P9N[i]
K[i] = (R[i] - i + 0x34) ^ P9M[i] ^ N[i]
H    = iv-hmac-key-p9
```

### 5.3 Counters in the session

The session context is set up once, when the session request succeeds, and kept for the whole session.
The ctrl channel keeps two independent 64-bit counters, one for each direction, both starting at 0 for a
new session; each encrypt (client to console) or decrypt (console to client) operation uses the current
value of its direction's counter and then increments it by 1. Exactly which fields consume counter values,
and in which order, is in ctrl.md. The launch specification uses counter 0 in the keystream-only form
(section 2.3) independently of the ctrl counters (session.md).

## 6. Registration mode, LAN (PIN)

Registration builds a fresh context per attempt. The client generates `S` itself: **16 random bytes**
(use a cryptographically secure RNG). `S` is not sent in clear: it is sent **masked** inside the request
body (registration.md gives the offsets), and the console recovers it.

The request body begins with `0x1e0` bytes of filler `F[0..0x1df]` (registration.md). Two filler bytes select
table columns, which the console reads from the same received bytes:

```
key_col  = F[0x18d] & 0x1f     (0..31)
mask_col = F[0x000] >> 3       (0..31)
```

`F[0x18d]` and `F[0]` are not overwritten by the masked seed (which lives at other offsets), so these are
the values on the wire.

### 6.1 `PS4-10` and `PS5-1`

Tables: `RK` = `regist-key-ps4` / `regist-key-ps5`, `RM` = `regist-mask-ps4` / `regist-mask-ps5`.

```
K[i] = RK[i*0x20 + key_col]            for i = 0..15
K[12] ^= PINB[0];  K[13] ^= PINB[1];  K[14] ^= PINB[2];  K[15] ^= PINB[3]

m    = 0x29 (PS4-10)   or   -0x2d = 0xd3 (PS5-1)
M[i] = (S[i] ^ RM[i*0x20 + mask_col]) + m + i          (masked seed, 16 bytes)

H    = iv-hmac-key-ps4 (PS4-10)  or  iv-hmac-key-ps5 (PS5-1)
```

Inverse (what the console computes; useful for tests): `S[i] = (M[i] - m - i) ^ RM[i*0x20 + mask_col]`.

### 6.2 `PS4-8` and `PS4-9` (legacy)

```
K = P9R
K[0] ^= PINB[0];  K[1] ^= PINB[1];  K[2] ^= PINB[2];  K[3] ^= PINB[3]

M[i] = (S[i] - i - 0x29) ^ P9M[i]       (masked seed, 16 bytes)

H    = iv-hmac-key-p9
```

Inverse: `S[i] = (M[i] ^ P9M[i]) + i + 0x29`. No filler bytes select anything in this mode.

### 6.3 Counters in registration

Exactly two cipher operations use the registration context, and **both use counter 0**:

1. encrypting the inner text of the request body (client), and
2. decrypting the response body (client; the console encrypted it with the same context at counter 0).

## 7. Registration mode, PSN (internet pairing)

Registration can also run over a PSN-brokered connection instead of the LAN; the transport (PSN session,
NAT traversal, the reliable-UDP framing) is **not** covered by these documents. The crypto differs from 6.1
only in how `K` and the mask are made. It exists only for `PS4-10` and `PS5-1`.

Extra 16-byte inputs, all produced during the PSN session setup:

| Name | Origin |
|------|--------|
| `D1` | 16 random bytes generated by the client and sent (base64) to PSN during session setup |
| `D2` | 16 random bytes generated by the client and sent (base64) to PSN during session setup |
| `CD` | 16 bytes the console sends back through PSN (a 32-character text value, decoded to 16 bytes) |

```
E    = Encrypt(context {K = D1, S = D2, H = H(target)}, c = 0, CD)      (16 bytes)
K[i] = RK[i*0x20 + key_col] ^ E[i]                 (no PIN mixing)

m'   = 0x2b (PS5-1)   or   -0x29 = 0xd7 (PS4-10)
M[i] = (S[i] - i + m') ^ RM[i*0x20 + mask_col]

H    = as in 6.1
```

Inverse: `S[i] = (M[i] ^ RM[i*0x20 + mask_col]) + i - m'`.

`H(target)` in the `E` step is the same `H` as the registration context. How `CD` text is decoded to 16
bytes is part of the PSN spec (not written; see Open questions).

## 8. Summary of modes

| Mode | Target | `K` | `S` | `H` | Counters |
|------|--------|-----|-----|-----|----------|
| Session | PS4-10 / PS5-1 | 5.1 from `RP-Nonce`, `RP-Key` | 5.1 | 2.4 | per direction, from 0 |
| Session | PS4-8 / PS4-9 | 5.2 | 5.2 | p9 | per direction, from 0 |
| Registration LAN | PS4-10 / PS5-1 | 6.1 (table + PIN) | random, sent masked | 2.4 | 0 for request, 0 for response |
| Registration LAN | PS4-8 / PS4-9 | 6.2 (`P9R` + PIN) | random, sent masked | p9 | 0, 0 |
| Registration PSN | PS4-10 / PS5-1 | 7 (table ^ E) | random, sent masked | 2.4 | 0, 0 |

## Open questions

1. **PS5 with an unknown RP-Version.** The reference client uses PS5 tables with the PS4-10 HMAC key. No PS5
   is known to report anything but `1.0`; treat other values as unsupported unless seen in the wild.
2. **`CD` decoding (PSN mode).** The console's value is 32 characters long and decodes to 16 bytes; whether that
   is plain hex or another encoding belongs to the PSN/holepunch spec, which does not exist yet.
3. **Filler bytes.** Any filler value should work, since the console derives the columns from the received
   bytes. The reference client always sends `0x41` filler, so that is the only value known to work with real
   consoles.
