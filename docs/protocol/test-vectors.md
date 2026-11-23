# Test vectors

Known-answer vectors for [discovery.md](discovery.md), [registration.md](registration.md) and
[rpcrypt.md](rpcrypt.md). Every identity, key and address here is **made up**.

## How these were verified

Every vector was computed by an independent Python script written from these documents only (tables read
from `data/`, formulas from the text), and then checked against the reference client:

- **[C]**: the same inputs were fed to the reference client's library functions through a small C program,
  and the outputs matched byte for byte. (42 values, all equal.)
- **[L]**: loopback end-to-end. A fake console written in Python from these documents (search responder +
  TCP request handler that unmasks the seed, decrypts the request, and encrypts a response) was run on
  `127.0.0.1`, and the reference client's real registration code paired with it. That covered all four
  targets plus a rejection with `RP-Application-Reason: 80108b09`. The fake console checked the client's
  header byte for byte against registration.md 3.1 and the inner text against 3.2; the client accepted the
  response and returned the expected pairing record.
- The scripts also reproduce the reference client's own unit-test values (not reproduced here).

No vector was produced by sending anything to a real console.

## Common inputs

| Name | Value |
|------|-------|
| `N` (RP-Nonce) | `9f3c5a17e2b4086dc1f05e7a3b92d4c8` |
| `R` (RP-Key) | `4a6f1e2d8c7b5a3948e7f6d5c4b3a291` |
| `S` (registration seed, normally random) | `0f1e2d3c4b5a69788796a5b4c3d2e1f0` |
| PIN | `12345678` (`BE32` = `00bc614e`) |
| PSN account ID | 1234567890123456789 -> LE bytes `1581e97df4102211` -> base64 `FYHpffQQIhE=` |
| PSN online ID (legacy only) | `playfx-tester` |
| PSN-mode `D1` / `D2` / `CD` | `101112131415161718191a1b1c1d1e1f` / `202122232425262728292a2b2c2d2e2f` / `303132333435363738393a3b3c3d3e3f` |
| Registration key (16-byte field) | ASCII `a1b2c3d4` + 8 zero bytes = `61316232633364340000000000000000` |
| Sample plaintext `P` (38 bytes) | ASCII `The quick brown fox jumps over 13 dogs` |
| Registration filler | `0x41` x `0x1e0` (so `key_col = 1`, `mask_col = 8`) |

## 1. Discovery

### 1.1 Search datagrams [C]

PS4, 60 bytes including the trailing `00`:

```
53524348202a20485454502f312e310a6465766963652d646973636f766572792d70726f746f636f6c2d76657273696f6e3a30303032303032300a00
```

PS5, 60 bytes:

```
53524348202a20485454502f312e310a6465766963652d646973636f766572792d70726f746f636f6c2d76657273696f6e3a30303033303031300a00
```

### 1.2 Wake datagrams [C]

Registration key `a1b2c3d4` -> credential `0xa1b2c3d4` = `2712847316`.

PS5 (to port 9302), 135 bytes:

```
WAKEUP * HTTP/1.1\nclient-type:vr\nauth-type:R\nmodel:w\napp-type:r\nuser-credential:2712847316\ndevice-discovery-protocol-version:00030010\n\0
```

```
57414b455550202a20485454502f312e310a636c69656e742d747970653a76720a617574682d747970653a520a6d6f64656c3a770a
6170702d747970653a720a757365722d63726564656e7469616c3a323731323834373331360a6465766963652d646973636f7665
72792d70726f746f636f6c2d76657273696f6e3a30303033303031300a00
```

PS4 (to port 987): identical except the version, `...76657273696f6e3a30303032303032300a00`.

### 1.3 Search response parse [C]

A made-up answer, received from `192.168.1.23`:

```
HTTP/1.1 200 Ok\r\n
host-id:0A1B2C3D4E5F\r\n
host-type:PS5\r\n
host-name:PS5-TEST\r\n
host-request-port:997\r\n
device-discovery-protocol-version:00030010\r\n
system-version:09400000\r\n
running-app-titleid:PPSA01234\r\n
running-app-name:Test Game\r\n
\0
```

Hex:

```
485454502f312e3120323030204f6b0d0a686f73742d69643a3041314232433344344535460d0a686f73742d747970653a5053350d0a
686f73742d6e616d653a5053352d544553540d0a686f73742d726571756573742d706f72743a3939370d0a6465766963652d646973
636f766572792d70726f746f636f6c2d76657273696f6e3a30303033303031300d0a73797374656d2d76657273696f6e3a30393430
303030300d0a72756e6e696e672d6170702d7469746c6569643a5050534130313233340d0a72756e6e696e672d6170702d6e616d65
3a546573742047616d650d0a00
```

Parsed:

| Field | Value |
|-------|-------|
| state | ready (200) |
| address | `192.168.1.23` |
| host-id | `0A1B2C3D4E5F` |
| host-type | `PS5` |
| host-name | `PS5-TEST` |
| host-request-port | 997 |
| device-discovery-protocol-version | `00030010` -> PS5 |
| system-version | `09400000` -> reference target selection gives `PS5-1` |
| running-app-titleid / name | `PPSA01234` / `Test Game` |

## 2. RP crypt, session mode [C]

Inputs `N`, `R` above.

| Target | `K` | `S` |
|--------|-----|-----|
| `PS4-9` | `0072967383a3888e49ec63fc477adc7a` | `795db676d2b15006d9faa000cb5470c3` |
| `PS4-10` | `7fc2079c248c4bfd9757b28add09b9d5` | `d7a0bebce46050c88357d9c895005820` |
| `PS5-1` | `0d2d5679e889b82040692955128dfab5` | `3702cc25ab3e19c6e185321596443ba9` |

(`PS4-8` uses the same derivation as `PS4-9`.)

IVs:

| Target | `IV(0)` | `IV(1)` | `IV(0x0102030405060708)` |
|--------|---------|---------|--------------------------|
| `PS4-9` | `0f10be874cc7f9bad9f9ce433033709a` | `661e4acd6aac6d7f25ed7f1a581e0bbd` | `4b5f8a2ddaf63da041cc275ae5be1859` |
| `PS4-10` | `505df3da9186e52cf7e97045eb2ded0d` | `5e835e6f13f0f7f56826e02a7447c918` | `0b9005de1c59b8c7b0e1e384dd939ba5` |
| `PS5-1` | `4a680df9eda7a382a183e9f29e6d36ee` | `2c256fff5ef4f8de3ce0600365e256e6` | `73e809923b34526891c4c7f6847634c8` |

`Encrypt(context, c = 5, P)` (38 bytes; exercises two full blocks and a partial one):

| Target | Ciphertext |
|--------|------------|
| `PS4-9` | `301b27ac03bfc1d86756a4667b8e98ace005241987d324e1e87e427993dd67255a2a8932ef06` |
| `PS4-10` | `f33853b5115cb4ec3b25cf70b444bbe50087535e04a70d2e78dbc20dded35b24a3f3131252c3` |
| `PS5-1` | `c65fa154cfc3ab08748f4f33d22090821c620b45935917205db08a0f28f667cedc30802ef514` |

Keystream-only form (rpcrypt.md 2.3), `P XOR Encrypt(context, 0, zeros(38))`:

| Target | Output |
|--------|--------|
| `PS4-9` | `7d1e15fb7b040569b3d103b9b5197aa6562f503289a6931f611362f84355312b9d71bc9b752d` |
| `PS4-10` | `003eca643c3c6743a1389f0653fbeec5a2f7776858cba6aa2f3279bbc2485e19477dca330ed8` |
| `PS5-1` | `bad59a62345fbe31e3920175c6de40a9854f6d2349904d9fae075ac6fd6527105063d645e25c` |

## 3. RP crypt, registration mode [C]

`K` was compared directly. `M` and `IV(0)` were checked through the bodies in section 4.2 (which embed `M`
and whose ciphertext depends on `IV(0)`); `E` is fixed by the compared PSN-mode `K`.

Seed `S` and PIN above, filler `0x41` (`key_col = 1`, `mask_col = 8`).

| Target | `K` | `H` | `IV(0)` | Masked seed `M` |
|--------|-----|-----|---------|-----------------|
| `PS4-8`/`PS4-9` | `3fa0a5f8dcbb3ecc50baedef9734c7c9` | p9 | `655467f6d7b9f14a6006f488702ca42e` | `07189e2ac39132cdaa6a6ff81eae6abc` |
| `PS4-10` | `cebcb640080776047b85e85bf350f52d` | ps4 | `837b69ad7efb2592540fbe075c9a2e3c` | `791ffef007185a6e52e54002dd54dfe0` |
| `PS5-1` | `d860e146bdb0bd94b460070bb1f3866d` | ps5 | `4f38c01a3aeb01220b00ad1c5c21feb3` | `7afd215f437e47f0c0b17cf1a1274c57` |

PSN mode (rpcrypt.md 7), same `S`, `D1`/`D2`/`CD` above:

| Target | `E` | `K` | Masked seed `M` |
|--------|-----|-----|-----------------|
| `PS4-10` | `dfad4528457aa9d983959d9314836156` | `1111f3684d7ddfddf81075c8e76ff535` | `b91ffce88f9c780ef041dafae550e3e0` |
| `PS5-1` | `8a0def7502a1f4040cf2786b26273ba5` | `526d0e33bf114990b8927f609768dc86` | `927f37d1557c89f2c8fbfc73e3657489` |

## 4. Registration request

### 4.1 Headers [L]

`PS5-1`, 587-byte body:

```
POST /sie/ps5/rp/sess/rgst HTTP/1.1\r\n HTTP/1.1\r\nHOST: 10.0.2.15\r\nUser-Agent: remoteplay Windows\r\nConnection: close\r\nContent-Length: 587\r\nRP-Version: 1.0\r\n\r\n
```

`PS4-10`, 587-byte body:

```
POST /sie/ps4/rp/sess/rgst HTTP/1.1\r\n HTTP/1.1\r\nHOST: 10.0.2.15\r\nUser-Agent: remoteplay Windows\r\nConnection: close\r\nContent-Length: 587\r\nRP-Version: 10.0\r\n\r\n
```

`PS4-9`, 530-byte body:

```
POST /sce/rp/regist HTTP/1.1\r\n HTTP/1.1\r\nHOST: 10.0.2.15\r\nUser-Agent: remoteplay Windows\r\nConnection: close\r\nContent-Length: 530\r\nRP-Version: 9.0\r\n\r\n
```

`PS4-8`, 530-byte body (no `RP-Version`):

```
POST /sce/rp/regist HTTP/1.1\r\n HTTP/1.1\r\nHOST: 10.0.2.15\r\nUser-Agent: remoteplay Windows\r\nConnection: close\r\nContent-Length: 530\r\n\r\n
```

### 4.2 Bodies [C]

Full bodies are in `data/vectors/` (same hex format as the tables, 32 bytes per line). In this document, line
breaks inside a hex block are layout only: concatenate the lines. Each is filler
`0x41` with the masked seed `M` from section 3 at the offsets in registration.md 3.2, followed by the
encrypted inner text.

| File | Target / identity | Bytes | SHA-256 |
|------|-------------------|------:|---------|
| `regist-body-ps5-1.hex` | `PS5-1`, account ID | 587 | `b81c94e6e6e91cc61c544a004ac8e1108ce0d7ee4358e4afe06e5bd5379f210b` |
| `regist-body-ps4-10.hex` | `PS4-10`, account ID | 587 | `c38d217d245d52fe0b14f7eb89ed5198e0e84535514c19311dc4ea3e8c80f72b` |
| `regist-body-ps4-9-account.hex` | `PS4-9` (and `PS4-8`: identical body), account ID | 530 | `12f7e5cd77a296db5a772c91d6543e9efdc03f6cc68ab8da5a8b4c8f554ee4af` |
| `regist-body-ps4-9-online.hex` | `PS4-9`, online ID `playfx-tester` | 531 | `05e3787b844c8a0720ebcda3ac225b3c5adf342f7d1f7926a074ece4fa06bc83` |
| `regist-body-psn-ps5-1.hex` | `PS5-1`, PSN mode | 587 | `f33ff313d91c4875af9647b17ef27953c604e3dc1130b4aacab7494c57b6dde3` |
| `regist-body-psn-ps4-10.hex` | `PS4-10`, PSN mode | 587 | `bf33add66e5796144618dca23a29dfc7c94b8fe59f2521ba7f29a74bfec77744` |

`PS5-1` in detail:

- `body[0x0c7..0x0ce]` = `M[8..15]` = `c0b17cf1a1274c57`
- `body[0x191..0x198]` = `M[0..7]` = `7afd215f437e47f0`
- every other byte below `0x1e0` is `41`
- inner plaintext (107 bytes):
  `Client-Type: dabfa2ec873de5839bee8d3f4c0239c4282c07c25c6077a2931afcf0adc0d34f\r\nNp-AccountId: FYHpffQQIhE=\r\n`
- `body[0x1e0..]` (ciphertext, 107 bytes):

```
9cd0fe2bcf0b07264ea347cb15f94026bff41f76bb17a0f8c9e4ff4e02a8ecb1538a9486b91772304f3c3cfa3d525eacd7766b3723ce
6c87795735bbe4f13663ac5b1ba51626ccb1c840d3e5f182da10f1e256e21cec7d3dc05cdfa850046ba559cd6fa630f70d7580a863
```

`PS4-9`, account ID: `body[0x11c..0x12b]` = `M` = `07189e2ac39132cdaa6a6ff81eae6abc`; inner plaintext (50 bytes)
`Client-Type: Windows\r\nNp-AccountId: FYHpffQQIhE=\r\n`; ciphertext:

```
56652bbc50e4ed0867f9eae5f4805d60aba972509faae5ce52647a1b7f13c93b694c89184ea231def6de117730dcd67b7cef
```

## 5. Registration response [C] [L]

A made-up successful response body, plaintext (`XX` = `PS5` for `PS5-1`, `PS4` otherwise):

```
XX-RegistKey: 6131623263336434\r\n
RP-KeyType: 2\r\n
RP-Key: 00112233445566778899aabbccddeeff\r\n
XX-Mac: 0a1b2c3d4e5f\r\n
XX-Nickname: XX-TEST\r\n
```

Encrypted with the registration context of section 3 at counter 0 (this is what the console sends after
`HTTP/1.1 200 OK\r\nContent-Length: 137\r\n\r\n`):

| Target | Ciphertext (137 bytes) |
|--------|------------------------|
| `PS5-1` | `8fefa263f31a4d1b44a769944ca70172ddd3b79c08691dea103854ac7b327df51f632630bdf46eb5f6a275c45a8b5be97966e3cac6f9a2e4b7b8df4721ec1fa3dc8224fd569c7c8f44fc5a7d519cdec4e0009714cfd9e9cf50c5e50a302410949c187d5b3273dc2d5ec8d672edaba2ae4d0c83369abfaed659afc5677066a89253bbc1f72e71ba0b3f` |
| `PS4-10` | `6b5e44086611e5e0ec927d8bc04514493b913c9cbc489875981151aa6add591ccef27c4d559184c16ce2cf6ee8b24b31b4122791bac02f1401a4169dc437d2040fdaecab805918019b6a451af1b02ebef6308cbd0097d68e8a608f44886d802793c94d7fd0ec107e7c9535f0d0ea178f486b0aedbb354e98fecf2cdd55790953b322e021a14aa0fc1e` |
| `PS4-8`/`PS4-9` | `455a76f46cf5a7356dfdc4baaded14388eb6f68adac8854a18547b090ab0d7fdd7cbbf38fe09393ab63b7f02fcd691ea2724ec11df9069c8ef3840ee57da711618012912234dc1b8f4b9cf8683d6291bba60f4b0e6f64a1c5ac6a784e46552eeeb34b620959c64a52f7d043b2aa973c9ab2b86c5ea8d0ee88441db12c4e6397d78a5a07730dcb2b05c` |

Resulting pairing record [L]:

| Field | Value |
|-------|-------|
| Registration key (16 bytes) | `61316232633364340000000000000000` (`a1b2c3d4`) |
| RP key | `00112233445566778899aabbccddeeff` |
| MAC | `0a1b2c3d4e5f` |
| Nickname | `PS5-TEST` / `PS4-TEST` |
| Key type | 2 |
| Wake credential (discovery.md 6.2) | `2712847316` |

The loopback run also sent `RP-Key` in upper-case hex plus `AP-Ssid` and `RP-SupportCmd` lines; the client
accepted them (hex is case-insensitive; the other names are optional).

## 6. Registration failure [L]

Console answer `HTTP/1.1 403 Forbidden\r\nRP-Application-Reason: 80108b09\r\nContent-Length: 0\r\n\r\n` after
a valid request -> failure, console had answered the search, status 403, reason `0x80108b09` (wrong or
expired PIN).
