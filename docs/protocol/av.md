# Audio and video frames

Status: draft 1 (clean-room spec, facts only). Covers what happens to AV packets after the transport has
parsed and decrypted them: video frame assembly, the erasure code (FEC), the bitstream facts the client
reads and changes, game audio, DualSense haptics audio and the microphone upstream.

Prerequisites:

- From `takion.md` §AV packets: the AV packet header fields named in §1 (their offsets, the payload start,
  payload decryption, and the reorder stage for video packets).
- From `stream.md`: the stream-info message (one video header per resolution, the audio header), and the
  messages for "corrupt frame" reports, IDR requests and enabling the microphone.

Conventions are those of `README.md`. In addition: GF arithmetic is in §3.1; `a ⊕ b` is XOR; "frame
index" arithmetic is 16-bit serial-number arithmetic (§4.1). Names (`k`, `m`, `S`, `lastGood`, …) are
this spec's own. "Client choice (observed)" marks behaviour of existing clients that the console isn't
known to require.

---

## 1. Header fields this layer uses

The transport hands over, per AV packet, the header fields below and the **decrypted payload** (the bytes
after the header; see takion.md §7 for offsets and for the 3 extra bytes skipped when the
extension flag is set). Names follow takion.md §7.2 where it names them; offsets live there.

| Field | Size | Meaning |
|---|---|---|
| `avKind` | from the packet type | 2 = video, 3 = audio (game audio, haptics or, upstream, microphone). |
| `packetIndex` | u16 | Per-stream packet counter. Consecutive units of one video frame have consecutive `packetIndex`. |
| `frameIndex` | u16 | Video: the frame this unit belongs to. Audio: the frame index of the packet's first source unit (§6.3). |
| `unitWord` | u32 | Split differently for video and audio, see below. |
| `codec` | u8 | Audio: must be 5 (Opus); packets with another value are dropped. Video: never read by existing clients; 3 is the only value on record (H.264 capture and the reference client's header test). No HEVC value is on record anywhere; take the codec from what was negotiated (stream.md), not from this byte. |
| `adaptiveStreamIndex` | 3 bits | Video only: which stream-info resolution (profile) this frame uses (§4.2). |
| `streamByte` | u8 | PS5 audio packets only: `0x02` = this packet carries haptics (§7), anything else = game audio. |
| offset-18 field | u16 | Video only. Not needed for assembly; meaning unknown (open question 14). |

`unitWord`, video (bit 31 = most significant):

| Bits | Field |
|---|---|
| 31..21 (11 bits) | `unitIndex`: 0-based position of this unit in its frame |
| 20..10 (11 bits) | `unitsTotal − 1` |
| 9..0 (10 bits) | `fecUnits`: number of parity units at the end of the frame |

`unitWord`, audio:

| Bits | Field |
|---|---|
| 31..24 | `unitIndex` (0 in every audio packet seen) |
| 23..16 | `unitsTotal − 1`: units in this packet |
| 15..8 | `unitSize`: bytes per unit |
| 7..4 | `redundantUnits` ("FEC units" in takion.md): units repeating earlier frames (§6.3) |
| 3..0 | `sourceUnits`: units carrying new frames |

Examples: video `unitWord` `0x00c01c01` → `unitIndex` 6, `unitsTotal` 8, `fecUnits` 1 (so `k` = 7);
audio `unitWord` `0x00022821` → `unitIndex` 0, `unitsTotal` 3, `unitSize` 40, `redundantUnits` 2,
`sourceUnits` 1 (V-AV8).

---

## 2. Video frame assembly

### 2.1 Units of a frame

All packets with the same video `frameIndex` are the **units** of one frame. With `n = unitsTotal` and
`m = fecUnits` (both from the header, the same in every unit of the frame):

- `k = n − m` **source units**, `unitIndex` 0..k−1. Concatenated (after §2.2's prefix is removed) they form
  the frame's access unit.
- `m` **parity units**, `unitIndex` k..n−1. Parity unit `k + i` is row `i` of the erasure code (§3).
- A header with `n < m` is invalid; drop the packet.
- Existing clients size a frame for at most 512 units (`k + max(m,1)`), and treat more as invalid (client
  choice, observed). The 11-bit fields would allow 2048.

### 2.2 Unit size `S`, the length prefix and padding

All units of a frame are, for FEC purposes, exactly `S` bytes long, and every **source unit** starts with
a 2-byte prefix:

```
source unit on the wire:  pad (u16, big-endian) || content (wireLen − 2 bytes)
S = wireLen + pad
parity unit on the wire:  S bytes of parity (no prefix)
```

- `pad` is how many bytes the console left off the end of the unit. For FEC the unit is the wire bytes
  followed by `pad` zero bytes, so every source unit is `S` bytes. The prefix bytes are part of the
  FEC-protected data.
- Parity units are sent at full length `S`.
- `S` is the same for every unit of a frame. A receiver learns it from the first unit of the frame that
  arrives: `wireLen + pad` if that unit is a source unit, `wireLen` if it is a parity unit.
- A source unit with `wireLen < 2` cannot carry the prefix; an `S` of 0 is invalid.
- Checked against a real console capture: frames with `k` = 1 and `k` = 17, `m` = 1, `S` = 108 and 1400; the
  parity units on the wire equal §3's code applied to the zero-padded source units (see "Observed").

### 2.3 Receiving units

For the frame being assembled, keep `S`, `k`, `m` and one slot per unit (`k + max(m, 1)` slots). For each
unit:

1. Drop it if `unitIndex ≥ n`, if `unitIndex` is beyond the slots, if `wireLen` = 0, if `wireLen > S`,
   or if that slot is already filled (duplicate).
2. Otherwise store it at slot `unitIndex`, zero-filled to `S`, and count it as a source or parity unit.

### 2.4 When a frame is finished

Client choice (observed): a frame is finished, and handled per §2.5, at the first of these events:

- after a unit is stored, units stored so far (source + parity) ≥ `k`;
- a unit with `unitIndex = n − 1` arrives. This holds unconditionally: also when it is the frame's first or
  only unit, and also when §2.3 rejected it. The frame is then finished with whatever was stored, which with
  fewer than `k` units means "FEC failed";
- a unit of a newer frame arrives (§4.3) while this frame is unfinished.

`k` and `n` are the header values; `fecUnits` = 0 changes neither condition. Because the transport delivers
video units in `packetIndex` order (below), unit `n − 1` is normally the last one to arrive, so the second rule
only fires early when units are lost or reordered beyond the reorder wait.

Units of a frame that arrive after it was finished are dropped (existing clients still count them in the
packet statistics, §4.5). Units of an older frame than the one being assembled are dropped.

The transport delivers video units in `packetIndex` order after a short reorder wait (takion.md), so the
"newer frame arrives" rule doesn't cut off late units of the previous frame in normal operation.

### 2.5 Finishing a frame

1. **All source units present**: no FEC is needed (parity units are ignored).
2. **Some source unit missing**: let `E` be the set of slot indices (0..k+max(m,1)−1) with no unit.
   - If `|E| ≤ m`, recover the missing source units with §3.4. Then for each source unit `j`, its length
     is `S − pad_j`, with `pad_j` read from the first 2 bytes of the (recovered or received) unit. A
     recovered unit whose `pad_j ≥ S` is unusable and treated as missing.
   - If `|E| > m` (fewer than `k` units arrived), the frame is **lost** ("FEC failed", §4.3).
   - With `fecUnits` = 0 there is no parity: any missing source unit loses the frame.
3. **Build the access unit** (frame succeeded): for `j = 0..k−1` in order, append bytes `2 .. len_j−1` of
   source unit `j` (that is, drop the 2-byte prefix, keep the content, drop the zero padding). Units
   shorter than 2 bytes contribute nothing.

The result is one complete **Annex-B access unit**: the console already puts start codes in the content
(4-byte `00 00 00 01` before each NAL unit in every capture seen), so nothing is added or removed. A frame
may hold several slice NAL units (12 slices per frame in a 1080p H.264 capture). A slice NAL unit can span
several units: units are cut at arbitrary byte positions, and the last unit of a slice is usually short.

Parameter sets (SPS/PPS, and VPS for HEVC) are **not** in the frames seen: they come in the stream-info
video header (§4.2).

---

## 3. FEC: the erasure code

A systematic Reed–Solomon-type code built on a **Cauchy matrix** over GF(2^8), applied independently to
each byte position of the `S`-byte units.

### 3.1 The field

GF(2^8) with the primitive polynomial

```
p(x) = x^8 + x^4 + x^3 + x^2 + 1        (0x11d)
```

A byte `b7..b0` is the polynomial `b7·x^7 + … + b0`. Addition is XOR. Multiplication is polynomial
multiplication reduced mod `p(x)`. `x` (the byte `0x02`) is a generator of the multiplicative group, so
`a·b = exp((log a + log b) mod 255)` with `exp(i) = 0x02^i`, for nonzero `a`, `b`. `inv(a)` is the
multiplicative inverse (`inv(a) = exp(255 − log a)`); `inv(0)` doesn't exist and is never needed.

### 3.2 The coding matrix

For a frame with `k` source and `m` parity units (`k + m ≤ 256`), the `m × k` coding matrix is

```
C[i][j] = inv( i ⊕ (m + j) )        i = 0..m−1 (parity row), j = 0..k−1 (source unit)
```

where `i` and `m + j` are taken as integers 0..255, XORed, and the result used as a field element. This is a
Cauchy matrix with `x_i = i` and `y_j = m + j` (`x_i + y_j ≠ 0` because the two sets are disjoint). There is no
normalisation of rows or columns (no "1"s are forced into the first row or column). **`C` depends on `m`**: the same
`k` source units give different parity for a different `m`.

The full generator is the `(k+m) × k` matrix `G = [ I_k ; C ]`: unit `u` (0..k+m−1) is row `u` of `G` times the
source vector. Every square submatrix of a Cauchy matrix is nonsingular, so any `k` of the `k + m` units
determine the source units (the code is MDS).

### 3.3 Encoding (what the console sends)

Each unit is `S` symbols; symbol `t` (0..S−1) of a unit is its byte `t`. The `k + m` units are `S`
independent codewords, one per byte position, with no interleaving and no grouping of bytes into
larger words:

```
P_i[t] = Σ_{j=0..k−1}  C[i][j] · D_j[t]          (sum = XOR)
```

`D_j` is source unit `j` zero-padded to `S` bytes (§2.2), `P_i` is parity unit `k + i`.

### 3.4 Decoding (recovering missing source units)

Given the set `R` of received unit indices, `|R| ≥ k`:

1. Choose any `k` indices `r_0 < … < r_{k−1}` from `R` (preferring source units makes the system smaller;
   the result is the same for any choice).
2. Form the `k × k` matrix `A` with rows `G[r_0], …, G[r_{k−1}]` and invert it over GF(2^8)
   (Gauss–Jordan elimination).
3. For each missing source unit `j`: `D_j[t] = Σ_q A⁻¹[j][q] · U_{r_q}[t]` for every byte `t`, with `U_r`
   the received unit `r` (source units zero-padded to `S`).

Because the code is MDS and the arithmetic exact, every correct decoder returns the same bytes: a decoder
written from this section matches the reference library bit for bit whenever the received units are
correct. Only the rows of `A⁻¹` for the missing source units are needed; rows for received source units are
unit vectors.

For speed: received source units contribute only through the missing rows, so with `e` missing source units it is
enough to solve an `e × e` system (the parity rows restricted to the missing columns, after subtracting the
received source units' contributions). Byte-wise `c · U` over a whole unit is the usual "region multiply";
with SIMD it is two 16-entry table lookups per byte (low and high nibble of `U[t]`, XORed), a standard
technique (Plank, Greenan, Miller 2013, "Screaming Fast Galois Field Arithmetic Using Intel SIMD
Instructions"; NEON `TBL` does the same).

### 3.5 Limits

- `k + m ≤ 256` (Cauchy point sets must fit in the field). The 11-bit `unitsTotal` field could exceed this;
  such frames can't be decoded with this code.
- More than `m` missing units (counting the empty slot of a frame with `fecUnits` = 0): unrecoverable.

---

## 4. Video stream handling

### 4.1 Frame index arithmetic

`frameIndex` is 16 bits and wraps from 65535 to 0. Comparisons use serial-number arithmetic (RFC 1982,
SERIAL_BITS = 16): `a` is **newer** than `b` when `a ≠ b` and `(a − b) mod 65536 < 32768`; **older** when
`a ≠ b` and `(a − b) mod 65536 > 32768`; a difference of exactly 32768 is neither. "`a + 1`" is mod 65536.

The first video frame of a session has `frameIndex` 1 (capture: the first frame, an IDR, had index 1).

### 4.2 Profiles and parameter sets

Stream info (stream.md) lists up to 8 resolutions, each with a width, height and a **video header**: the
Annex-B parameter sets for that resolution (H.264: SPS and PPS; HEVC: VPS, SPS and PPS, each after a
4-byte start code).

When the first video unit arrives, and whenever `adaptiveStreamIndex` differs from the current one:

- if `adaptiveStreamIndex` ≥ the number of resolutions, drop the unit;
- otherwise switch to that resolution: give its video header to the decoder (as its own sample, before the
  next frame) and re-read the SPS fields of §5.

### 4.3 Per-frame rules

State (all frame indices): `current` (frame being assembled, none at start), `lastGood` (last frame
completed successfully, starts at 0), `lastHandedOver` (last frame given to the decoder, none at start),
`waitingForIdr` (false), and a list of the last 16 frames handed to the decoder (`refs`).

**A unit of a newer frame `f` arrives** (or the very first unit):

1. If `current` is unfinished, finish it now (§2.5) and handle the result as below.
2. If `f` is newer than `lastGood + 1`: send a **corrupt-frame report** for frames `lastGood + 1 … f − 1`
   (inclusive; message in stream.md).
3. `current = f`; start a new frame from this unit's header (§2.1–§2.2).

**A frame finishes with "FEC failed"**:

1. Send a corrupt-frame report for `lastGood + 1 … current`.
2. Client choice (observed, PlayFX enables it): if not `waitingForIdr`, send an **IDR request**
   (stream.md) and set `waitingForIdr`. If already waiting, repeat the IDR request when at least 1000 ms
   passed since the last one.
3. The frame isn't handed over. `lastGood` doesn't change.

Existing clients do send that range twice when a newer frame follows a failed one: once here, and once in
step 2 of the next frame's start (`lastGood` didn't move, so the next frame `current + 1` gives the range
`lastGood + 1 … current` again; a later frame gives a range that contains it). Each report is a plain range
(stream.md), so the second one only repeats information; suppressing a repeat should be harmless, but no
client has been seen doing that, so the console's tolerance of a missing repeat is untested. Matching the
existing behaviour is the safe choice.

**A frame finishes successfully**: read the first slice header of the access unit (§5). The header "can't be
parsed" when: no 4-byte start code `00 00 00 01` begins at byte offset 0..64 of the access unit (a 3-byte
`00 00 01` at offset 0 is not found); the NAL type isn't one §5 accepts (H.264: 1, 5; HEVC: 1, 20); or one of
§5's parse failures occurs. Then skip steps 1–2 and go to step 3: the frame is handed over without IDR or
reference logic, **even while `waitingForIdr`** (which stays set).

1. If `waitingForIdr`: an I slice clears it. Any other parsed slice, P or "neither" (§5.1, §5.2), is dropped:
   not handed over, `lastGood` unchanged, and the IDR request repeated if 1000 ms passed since the last one.
2. If it's a P slice with a known reference `d` (§5: the slice references the frame `d + 1` frames back):
   if `current − d − 1` is not in `refs`:
   - HEVC: look for the smallest `d' > d`, `d' ≤ 15`, with `current − d' − 1` in `refs`. If one exists,
     rewrite the slice header to reference it (§5.3) and, if that succeeds, mark the frame **recovered**.
   - If there is none, the rewrite fails, or the stream is H.264 (no rewrite): the frame isn't handed over and
     `lastGood` doesn't change. Existing clients send **no IDR request** and don't set `waitingForIdr` here;
     they rely on the next frame's corrupt-frame report (§4.3, "a unit of a newer frame", step 2).
   - Slices that are "neither" (not P, not I) get no reference check and are handed over (when not waiting).
3. Hand the access unit to the decoder with `framesLost` (§4.4) and the `recovered` flag. If the decoder
   rejects it, `lastGood` doesn't change and it isn't added to `refs` (client choice, observed).
   Otherwise add `current` to `refs` (dropping the oldest beyond 16) and set `lastGood = current`.

The corrupt-frame report is how the console learns which frames the client lacks. The console's encoder
keeps many reference pictures (HEVC slices list up to 9+ earlier pictures, §5.3), so it can carry on from an
older good picture; an IDR is the fallback.

### 4.4 `framesLost` and `recovered`

- `framesLost` (per frame handed over): the frames skipped since the previous frame handed over:
  `0` for the first frame handed over; otherwise `g = (current − lastHandedOver) mod 65536` and
  `framesLost = 0` if `g = 0`, else `g − 1`. Each missing index counts once, whatever the reason (never
  arrived, FEC failed, missing reference, dropped while waiting for an IDR). Then `lastHandedOver = current`.
- A running total is the sum of these.
- `recovered` = the slice header was rewritten to an older reference (§4.3 step 2). The picture is then
  decodable but may show artefacts until the next refresh.
- The video header given on a profile switch is handed over with `framesLost = 0`, `recovered = false`,
  and doesn't change `lastHandedOver`.

### 4.5 Packet statistics (for congestion feedback)

When a newer frame starts, existing clients add the previous frame's counts to the statistics behind the
congestion reports (takion.md §8.3): units received (source + parity units accepted by §2.3, including ones
that came after the frame was finished; rejected units and duplicates don't count) and units missing
(`expected − received`). Game-audio packets add one "received" each and track the highest audio `frameIndex`
(takion.md §8.3). **Haptics packets are not counted** anywhere in these statistics. Client choice (observed).

Where `fecUnits` = 0 matters (the only case where the counts differ):

| Use | Count used by existing clients |
|---|---|
| Finishing the frame (§2.4) | `k` and `n` from the header; no phantom unit |
| FEC recovery (§2.5, §3.5) | `k + max(m, 1)` slots, so the empty phantom slot is one erasure: any missing source unit loses the frame |
| Congestion statistics `expected` | `k + max(m, 1)`: a complete frame with `fecUnits` = 0 reports 1 unit lost |
| `framesLost` (§4.4) | frame indices only; units don't matter |

takion.md §8.3 states `expected` as "the frame's total units (source + FEC)"; that is the same number except
when `fecUnits` = 0, where existing clients use `n + 1`. Every frame in the capture had `fecUnits` ≥ 1, so
whether consoles send 0 at all is unknown.

---

## 5. Bitstream facts the client needs

The client reads a few fields of the **first slice NAL unit** of each access unit (the first 4-byte start
code beginning at offset 0..64, §4.3), and needs a few SPS/PPS fields to reach them. Syntax and semantics are from
ITU-T H.264 (06/2019) and ITU-T H.265 (V8, 08/2021); section numbers below are theirs. All slice-header
fields are read from the RBSP, i.e. after removing emulation-prevention bytes (`00 00 03` → `00 00`,
H.264 §7.4.1 / H.265 §7.4.2).

### 5.1 H.264

SPS (§7.3.2.1.1) fields needed: `log2_max_frame_num_minus4`, `frame_mbs_only_flag`, `pic_order_cnt_type`
(and `log2_max_pic_order_cnt_lsb_minus4`, `delta_pic_order_always_zero_flag` if they apply). For the High
profiles (`profile_idc` 100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135) the chroma/bit-depth
fields come first; existing clients give up when `seq_scaling_matrix_present_flag` = 1, and when
`log2_max_frame_num_minus4 > 12`. PPS (§7.3.2.2): `bottom_field_pic_order_in_frame_present_flag`,
`redundant_pic_cnt_present_flag`.

Slice NAL types: 1 (non-IDR) and 5 (IDR). Slice header (§7.3.3) up to the reference list:

```
first_mb_in_slice ue(v), slice_type ue(v), pic_parameter_set_id ue(v),
frame_num u(log2_max_frame_num_minus4 + 4),
[field_pic_flag …  if !frame_mbs_only_flag], [idr_pic_id ue(v)  if IDR],
[POC fields  per pic_order_cnt_type], [redundant_pic_cnt  if present],
P: num_ref_idx_active_override_flag u(1) [num_ref_idx_l0_active_minus1 ue(v)],
   ref_pic_list_modification_flag_l0 u(1),
   then pairs modification_of_pic_nums_idc ue(v) [+ value ue(v)] until idc = 3   (§7.3.3.1)
```

- `slice_type` 0 or 5 → P; 2 or 7 → I; anything else → neither (treated as "unknown": no IDR or reference
  logic).
- Reference distance `d` for a P slice in a non-IDR NAL: 0 (the previous frame) when there is no list
  modification. With modification entries, an entry with `modification_of_pic_nums_idc` = 0 gives
  `abs_diff_pic_num_minus1 = d`: the first reference is `frame_num − (d + 1)`, i.e. `d + 1` frames back
  (§8.2.4.3.1; frame numbers step by one per frame in these streams). Existing clients accept at most **two**
  modification entries before the terminating idc 3, and `d` = the value of the **last** idc-0 entry. With no
  idc-0 entry (only idc 1 or 2 entries) `d` = 0, the previous frame, whatever the entries say. Three or more
  entries, or an idc value above 3, is a parse failure (§4.3: handed over without checks). Idc 1 and 2
  values are read and ignored.
- Values seen in console H.264 streams (1080p sample): Main profile (77), level 5.0, `pic_order_cnt_type`
  = 2, `frame_mbs_only_flag` = 1, `log2_max_frame_num_minus4` = 3 (frame_num wraps at 128),
  `max_num_ref_frames` = 9, CABAC, no redundant_pic_cnt. P slices referencing 6 frames back use one
  modification entry (idc 0, value 5) then idc 3.
- H.264 slices are never rewritten.

### 5.2 HEVC

SPS (§7.3.2.2) fields needed: `separate_colour_plane_flag`, `log2_max_pic_order_cnt_lsb_minus4`
(existing clients give up when > 12), `num_short_term_ref_pic_sets`. To reach them the parser walks
`profile_tier_level` (§7.3.3; with `sps_max_sub_layers_minus1` = 0 that is 2+1+5+32+4+43+1+8 = 96 bits), the
ids, chroma format, picture size, conformance window and bit depths. PPS (§7.3.2.3):
`dependent_slice_segments_enabled_flag`, `output_flag_present_flag`, `num_extra_slice_header_bits`. The
video header holds VPS (type 32), SPS (33), PPS (34) in that order.

Slice NAL types used by the console: 1 (TRAIL_R, P pictures) and 20 (IDR_N_LP). These are the **only**
types existing clients parse: any other first NAL (including 19 IDR_W_RADL, 21 CRA_NUT, 0 TRAIL_N, or a
VPS/SPS/PPS/SEI/AUD ahead of the slice) is "can't be parsed" (§4.3), so an IDR coded as type 19 would be
handed over but would **not** clear `waitingForIdr`. The rewrite (§5.3) accepts type 1 only. An implementation
may accept 16..21 as I pictures; that is a deviation, harmless as far as known. Slice segment header
(§7.3.6.1) up to the short-term RPS:

```
first_slice_segment_in_pic_flag u(1), [no_output_of_prior_pics_flag u(1)  if NAL type 16..23],
slice_pic_parameter_set_id ue(v), [dependent_slice_segment_flag, slice_segment_address  if not first],
slice_reserved_flag × num_extra_slice_header_bits, slice_type ue(v),
[pic_output_flag  if output_flag_present_flag], [colour_plane_id u(2)  if separate_colour_plane_flag],
if not IDR: slice_pic_order_cnt_lsb u(log2_max_pic_order_cnt_lsb_minus4 + 4),
            short_term_ref_pic_set_sps_flag u(1),
            if 0: st_ref_pic_set(num_short_term_ref_pic_sets)   (§7.3.7)
```

`st_ref_pic_set` coded in the slice header with `num_short_term_ref_pic_sets` = 0 (as in console streams) has
no prediction flag: `num_negative_pics ue(v)`, `num_positive_pics ue(v)`, then per negative picture
`delta_poc_s0_minus1 ue(v)`, `used_by_curr_pic_s0_flag u(1)`, then the positive ones.

- `slice_type` 1 → P, 2 → I, 0 (B) → neither.
- Reference distance `d` for a P slice: the index of the first negative picture with
  `used_by_curr_pic_s0_flag` = 1. With every `delta_poc_s0_minus1` = 0 (always so in console streams),
  negative picture `i` is the picture `i + 1` frames back. If no flag is set (or the SPS RPS is used),
  `d` is unknown and the reference check is skipped. `num_negative_pics > 16` is a parse failure (§4.3).
- Values seen in console HEVC streams (1080p sample): Main profile, level 5.0 (`general_level_idc` 150),
  `log2_max_pic_order_cnt_lsb_minus4` = 0 (POC LSB is 4 bits), `num_short_term_ref_pic_sets` = 0, no extra
  slice header bits, no output flag, P slices listing 1 to 9 negative pictures, each `delta_poc_s0_minus1`
  = 0, exactly one marked used.

### 5.3 Rewriting an HEVC P slice to an older reference

To make a P slice whose reference `d` is missing use negative picture `d'` instead (`d' > d`,
`d' < num_negative_pics`):

- In the first slice NAL unit of the access unit, set `used_by_curr_pic_s0_flag[d']` = 1 and
  `used_by_curr_pic_s0_flag[i]` = 0 for all `i < d'`. Flags after `d'` stay as they are (0 in console
  streams). Nothing else changes: these are single bits, so the header length doesn't change.
- The bit positions are those of the flags in the NAL unit **as transmitted**: an RBSP bit position plus 8
  for every emulation-prevention byte that precedes it in the escaped NAL unit. In console streams the RPS
  lies in the first few bytes, ahead of any emulation-prevention byte.
- If `d' ≥ num_negative_pics`, the rewrite fails.
- A flipped bit could in principle form a forbidden `00 00 0x` (x ≤ 3) pattern with neighbouring bytes, or
  turn an existing `00 00 03` into data. An implementation should re-escape the NAL unit after changing the
  RBSP (H.265 §7.4.2) or refuse the rewrite in that case. Existing clients don't check (open question 6).
- Only the first slice is rewritten. If a picture has several slices, the others keep their original RPS,
  and the slices of one picture then disagree (H.265 requires them to match); whether console HEVC pictures
  have more than one slice is open question 7.

### 5.4 Latency-related SPS values

The console's SPS already asks for no reordering: H.264 VUI `bitstream_restriction_flag` = 1 with
`max_num_reorder_frames` = 0 (and `max_dec_frame_buffering` = 9); HEVC `sps_max_num_reorder_pics` = 0,
`sps_max_latency_increase_plus1` = 0 (`sps_max_dec_pic_buffering_minus1` = 9). A decoder can therefore output
each picture as soon as it's decoded. Existing clients don't patch the SPS. H.264 timing info in the sample:
`num_units_in_tick` 2002, `time_scale` 240000, fixed frame rate (nominally 59.94 fps).

### 5.5 Handing access units to VideoToolbox

Informative. VideoToolbox wants length-prefixed NAL units: split the access unit on 3- or 4-byte start
codes, keep parameter sets (H.264 types 7/8, HEVC 32/33/34) to build the format description, and prefix each
other NAL unit with its 4-byte big-endian length.

---

## 6. Game audio

### 6.1 Audio header (from stream info)

Stream info (stream.md) carries a 14-byte audio header:

| Offset | Size | Field |
|---|---|---|
| 0 | 1 | channels |
| 1 | 1 | bits per sample |
| 2 | 4 | sample rate (Hz), BE32 |
| 6 | 4 | frame size (samples per channel per Opus frame), BE32 |
| 10 | 4 | unknown, BE32 (1 in headers clients make) |

Any other length is invalid. Expected values 2 channels, 16 bits, 48000 Hz, 480 samples (10 ms), from the
upstream header's shape and the decoder settings existing clients end up with; not checked against a
capture (open question 1). A new audio header resets the audio receiver (jitter buffer, indices).

### 6.2 Packet payload

`unitWord` gives `n = unitsTotal`, `unitSize`, `sourceUnits = s`, `redundantUnits = r`. Checks (drop the
packet if any fails): `codec` = 5, payload not empty, `s + r = n`, payload length = `n × unitSize`. Unit
`i` is payload bytes `i·unitSize … (i+1)·unitSize − 1`. **Each unit is one complete Opus packet** (RFC 6716
§3, with its TOC byte) for one audio frame. Units have a fixed size, so the console encodes at a constant
bitrate.

Audio "FEC" is repetition, not an erasure code: the redundant units are copies of earlier frames' packets.

### 6.3 Frame index of each unit

With `F` = the packet's `frameIndex`:

- source unit `i` (0 ≤ i < s): frame `F + i`;
- redundant unit `s + q` (0 ≤ q < r): frame `F − r + q` (oldest first).

So with `s` = 1, `r` = 2: unit 0 = frame `F`, unit 1 = `F − 2`, unit 2 = `F − 1`.

Start-up rule: until a packet with `F > 32768` has been seen (as an unsigned 16-bit value), skip redundant
units with `F + q < r + 1`; they would name frames at or before 0, before the stream started. Once a packet
with `F > 32768` was seen, the rule is off for the rest of the stream.

A frame received more than once (from source and later redundant units) is used once.

### 6.4 Decoding

Opus decoder (RFC 6716) at the header's sample rate and channel count. Each frame decodes to at most
`frame size` samples per channel, interleaved signed 16-bit PCM. For a frame that never arrived, run the
decoder's packet-loss concealment (decode with no data) to fill the gap.

### 6.5 Jitter buffer (client choice, observed)

8 slots keyed by frame index. Playback starts once 3 frames are buffered, from the oldest. Then frames go to
the decoder in index order. If the next frame is missing but a newer one is buffered, the gap is concealed
(PLC) when at least 3 frames are buffered and the newest is at least 3 ahead of the missing one, or when fewer
than 3 are buffered. Frames older than the next one to play are dropped. When full, a frame older than the newest
buffered one replaces the newest.

Implementer note: existing clients decide on concealment while they are still storing a packet's units, source
units first. In practice the buffer is nearly empty in steady state, so a lost frame gets concealed just before
the redundant copy in the same packet would have filled it (checked with the reference receiver: one lost packet
gives one concealed frame, not a recovered one). Storing **all** units of a packet before deciding what to play
lets the repetition do its job.

---

## 7. Haptics audio (DualSense, PS5)

- Carried in audio AV packets (`avKind` 3) whose `streamByte` = `0x02`. Same header, `unitWord` split and
  checks as §6.2, including `codec` = 5.
- **Units are raw PCM, not Opus**: signed 16-bit samples, 2 channels interleaved (left/right actuator),
  3000 Hz. Units seen are 120 bytes = 30 sample frames = 10 ms. Byte order little-endian (open question 3).
- Frame indices per unit as §6.3, **including the start-up rule**, with its own state: the haptics stream
  has its own "a packet with `F > 32768` was seen" flag, independent of game audio's. Unlike game audio it is
  never reset (no audio header applies to it).
- Client choice (observed): a unit is used only if its frame index is newer (§4.1) than the last haptics frame
  used, in payload order; no jitter buffer, no concealment. "Last used" starts at 0, so the first usable
  haptics frame must be newer than 0 (index 1..32767).
- Haptics packets don't count in the congestion statistics (§4.5).
- Consumers either play it on the DualSense's haptic channels (USB audio, resampled to 48 kHz) or reduce it
  to rumble (outside this protocol).

---

## 8. Microphone upstream

### 8.1 Enabling

1. After stream info, the client announces its upstream audio format with a stream-info message (stream.md)
   whose audio header bytes are exactly `01 10 0000bb80 000001e0 00000001` (read per §6.1: 1 channel, 16 bits,
   48000 Hz, 480 samples, unknown = 1). This is what existing clients send even though they encode stereo
   (open question 4).
2. Before the first microphone packet: ctrl "microphone connect" (`ctrl.md` §6.6), and ctrl "microphone
   state" to unmute/mute.

### 8.2 Encoding

Client choice (observed), compatible with the console:

- Opus encoder (libopus API terms): 48000 Hz, 2 channels, application `RESTRICTED_LOWDELAY` (CELT only),
  frames of 480 samples per channel (10 ms), constant bitrate 32000 bit/s (VBR off), which gives packets of
  exactly 40 bytes. Also signal type "music" and phase inversion disabled.
- Input: interleaved signed 16-bit PCM, 960 values per frame.
- Only 40-byte packets are sent; a packet of any other size is not sent. With VBR off every packet is 40
  bytes (V-AV13); with VBR on, quiet frames encode smaller and would be lost.

### 8.3 Packet layout

One AV packet per 10 ms frame, `avKind` 3 (audio). With `c` a 16-bit counter starting at 0 (one per packet,
wrapping to 0 after 65535):

| Field | Value |
|---|---|
| `packetIndex` | `c` |
| `frameIndex` | `c + 1` (the new frame's index) |
| `unitWord` | `0x00022821`: `unitIndex` 0, `unitsTotal` 3, `unitSize` 40, `redundantUnits` 2, `sourceUnits` 1 |
| `codec` | 5 |
| PS5 only: the `streamByte` byte | `0x00` |
| Payload (120 bytes) | new frame (40) ‖ frame two back (40) ‖ frame one back (40) |

For the first two packets the "back" frames that don't exist yet are copies of the first frame. The payload is
encrypted and the GMAC and key position fields filled as takion.md §7 says for client-sent audio.
Total packet size 139 bytes (PS4) or 140 (PS5) before any transport framing takion.md adds.

---

## 9. Constants and timeouts (summary)

| What | Value | Kind |
|---|---|---|
| GF polynomial | `0x11d` | protocol |
| Coding matrix | `C[i][j] = inv(i ⊕ (m+j))` | protocol |
| Source unit prefix | 2 bytes, BE `pad` | protocol |
| Max units per frame | 512 | client choice |
| `refs` list | last 16 frames handed over | client choice |
| Max HEVC rewrite distance | `d' ≤ 15` | client choice |
| IDR request repeat | ≥ 1000 ms apart while waiting | client choice |
| Audio codec byte | 5 (Opus) | protocol |
| Audio jitter buffer | 8 slots, prefill 3 | client choice |
| Haptics | 3000 Hz, stereo, s16, 120-byte units | protocol (observed) |
| Mic | Opus 48 kHz stereo, 10 ms, 40 bytes, `unitWord` `0x00022821` | client choice, accepted by consoles |

---

## Observed

From the H.264 capture of a real console session that ships with the reference client's test data (128
packets, first frames of a stream), checked with this spec's own script:

- Video packets had byte 0 `0x02` and `0x12` (extension flag set). `codec` 3.
- Frame 1: `k` = 1, `m` = 1, IDR slice; `pad` = 3 on a 105-byte source unit, parity unit 108 bytes and equal
  to the source unit zero-padded (with `m` = 1 and `k` = 1, `C = [inv(1)] = [1]`).
- Frame 2: `k` = 17, `m` = 1, `S` = 1400, 12 slices; the parity unit on the wire equals §3.3 applied to the 17
  zero-padded source units, byte for byte.
- Each source unit's `wireLen + pad` = 1400 (e.g. a 12-byte unit with `pad` = `0x056c`).

---

## 10. Open questions

1. The audio header values real consoles send (expected 2 / 16 / 48000 / 480 / 1).
2. The video `codec` byte for HEVC and HEVC HDR streams (3 seen for H.264 only).
3. The haptics PCM byte order (assumed little-endian: existing clients use the bytes as native 16-bit values
   on little-endian machines and the result drives the actuators correctly).
4. Whether the console checks the upstream audio header: it says 1 channel, while the Opus packets sent are
   stereo (their TOC says so, and consoles accept them).
5. Whether `unitIndex` in audio packets is ever non-zero (one packet per audio frame group seen).
6. Whether existing clients' HEVC rewrite ever hits an emulation-prevention byte (not seen; §5.3).
7. Whether HEVC frames have more than one slice and, if so, whether the decoder tolerates a rewritten first
   slice only.
8. H.264 slice headers with `num_ref_idx_active_override_flag` = 1 weren't seen; existing clients' parse
   differs from the standard there (they read an extra bit), so behaviour on such streams is untested.
9. What the extension flag's 3 bytes contain (takion.md skips them).
10. Whether IDR access units on PS5 ever carry parameter sets in-band (none seen).
11. The console's encoder behaviour after a corrupt-frame report (assumed: references a picture before the
    reported range).
12. The game-audio Opus mode and frame duration as coded in the TOC byte (only the header's frame size is
    known; the microphone's packets are CELT-only 10 ms, TOC `0xf4`).
13. SPS/slice values are from 1080p sample streams; other resolutions, HDR and PS4 streams weren't parsed.
14. The meaning of the video header's 16-bit field at offset 18 (takion.md §7.2); existing clients ignore it.

---

## 11. Known-answer vectors

Markers:

- **[I]**: computed by an independent Python script written from this spec's text (session scratchpad, not in
  the repo).
- **[J]**: the same bytes came out of a C harness linked against the reference FEC library (jerasure 2 +
  gf-complete, `cauchy_original_coding_matrix`, `w` = 8, encode and decode with no "row of ones"), built
  from source in the scratchpad.
- **[C]**: the same result came out of a C harness linked against the reference client's library (frame
  assembly, bitstream parser/rewriter, frame-loss counter).
- **[R]**: checked against real console data (the capture in "Observed").

### V-AV1. GF(2^8) arithmetic (§3.1) [I][J]

| Expression | Value |
|---|---|
| `0x02 · 0x80` (= `exp(8)`) | `0x1d` |
| `log(0x03)` | 25 |
| `0x53 · 0xca` | `0x8f` |
| `0xff · 0xff` | `0xe2` |
| `inv(0x02)`, `inv(0x03)`, `inv(0x53)` | `0x8e`, `0xf4`, `0x8c` |

[J]: the reference library's single-element multiply and divide (`w` = 8) gave the same values.

### V-AV2. Coding matrices (§3.2) [I][J]

`k` = 4, `m` = 3 (rows `i` = 0..2, columns `j` = 0..3):

```
f4 47 a7 7a
8e a7 47 ba
01 7a ba 47
```

`k` = 17, `m` = 1 (one row): `01 8e f4 47 a7 7a ba ad 9d dd 98 3d aa 5d 96 d8 72`
(`inv(1)`, `inv(2)`, … `inv(17)`). `k` = 1, `m` = 1: `01` (the parity unit is a copy of the source unit).

### V-AV3. Encoding, `k` = 4, `m` = 3, `S` = 8 (§3.3) [I][J]

Source units `D_j[t] = 16·j + t`:

```
D0 0001020304050607
D1 1011121314151617
D2 2021222324252627
D3 3031323334353637
```

Parity:

```
P0 (unit 4) 553b89e7f09e2c42
P1 (unit 5) 1bcfae7a6cb8d90d
P2 (unit 6) 21a730b603851294
```

### V-AV4. Decoding (§3.4) [I][J]

- Units 0, 2 and 5 missing (received: 1, 3, 4, 6): the decoder returns `D0` and `D2` of V-AV3 exactly. The
  reference library returned the same bytes (its contents for the missing units were overwritten with `0x42`
  first).
- Units 0, 1, 2, 3 missing (only the 3 parity units): unrecoverable (reference library: failure).

### V-AV5. Random agreement (§3) [I][J]

300 random cases (`k` 1..40, `m` 1..12, `S` 1..64, random data, 1..`m` random erasures among all `k + m`
units) plus one `k` = 200, `m` = 56, `S` = 32 encode: the spec script's parity and recovered units equal the
reference library's in every case.

### V-AV6. Frame assembly with prefix, padding and FEC (§2) [I][C]

`n` = 5, `m` = 2 (`k` = 3), `S` = 16. Units as sent (source units carry `pad`; parity per §3.3 over the
zero-padded source units):

```
unit 0 (source, pad 0)   000000000001419a0102030405060708
unit 1 (source, pad 5)   0005090a0b0c0d0e0f1011
unit 2 (source, pad 10)  000a12131415
unit 3 (parity row 0)    008f8dcbf7c85ebc8bfa80028c038d04
unit 4 (parity row 1)    008e7b538f51b7717dfd87f70302f6f3
```

Access unit (27 bytes) in every successful case:

```
00000001419a0102030405060708090a0b0c0d0e0f101112131415
```

| Units received, in arrival order | Result |
|---|---|
| 0, 1, 2 | complete without FEC |
| 1, 3, 4 | units 0 and 2 recovered by FEC (`S` learnt from unit 1: 11 + 5) |
| 3, 0, 2 | unit 1 recovered (`S` learnt from parity unit 3: 16) |
| 4, 0, 2 | FEC failed: unit 4 (`n − 1`) finishes the frame on arrival with 1 unit stored; 0 and 2 come too late (§2.4) |
| 1, 3 | FEC failed (2 units < `k`) |

[C]: the reference client's frame assembly, fed the same units and finished at the point §2.4 says, returned
the same access unit and the same outcome (complete / recovered by FEC / failed) in all five cases.

### V-AV7. Real console capture (§2, §3) [I][R][C]

The units are in [`data/vectors/av-capture-h264.txt`](data/vectors/av-capture-h264.txt): one line per unit
(byte 0, `packetIndex`, `frameIndex`, `unitIndex`, `unitsTotal`, `fecUnits`, decrypted payload in hex), all 20
units of frames 1 (`k` = 1, `m` = 1, `S` = 108) and 2 (`k` = 17, `m` = 1, `S` = 1400). The last unit of each
frame is its parity unit; it equals the spec script's encoding of the zero-padded source units.

| Frame | Access unit length | First 16 bytes | SHA-256 of the access unit |
|---|---|---|---|
| 1 | 103 | `00000001658880867f002fc803ff087e` | `7cfcb4169c975d5ff1f6120c2239b9564b5530811c76fe31be79c0fc99fb2982` |
| 2 | 15995 | `00000001419a04422f9fe004a404fffc` | `02b08cbe0820d13393ea93d17c551a8291bcdbefaf8a76d4c209129306ae5dc6` |

Suggested tests: rebuild both access units from all units; drop any one source unit and recover it from the
parity unit; re-encode the parity unit from the source units. Dropping one source unit (unit 0 of frame 1, unit 5 of
frame 2) and recovering it with the spec script gave the same 103- and 15995-byte access units as the
complete frames; the reference client's assembly agreed.

### V-AV8. Header words (§1, §8.3) [I][C]

| `unitWord` | As video | As audio |
|---|---|---|
| `0x00c01c01` | `unitIndex` 6, `unitsTotal` 8, `fecUnits` 1 | — |
| `0x00022821` | — | `unitIndex` 0, `unitsTotal` 3, `unitSize` 40, `redundantUnits` 2, `sourceUnits` 1 |
| `0x00022811` | — | `unitsTotal` 3, `unitSize` 40, `redundantUnits` 1, `sourceUnits` 1 (fails the `s + r = n` check) |

[C]: the reference client's audio field split gave the same numbers.

### V-AV9. Audio unit frame indices (§6.3), `s` = 1, `r` = 2 [I][C]

| `F` | Start-up rule on | Units 0, 1, 2 → frames |
|---|---|---|
| 1000 | no | 1000, 998, 999 |
| 1 | yes | 1, skipped, skipped |
| 2 | yes | 2, skipped, 1 |
| 3 | yes | 3, 1, 2 |
| 0 (after a wrap) | no | 0, 65534, 65535 |

[C]: the reference audio receiver, fed packets whose units were tagged with their claimed frames, played the
redundant copies as those frames (packets `F` = 3, 4, 5, 6 alone played frames 1, 2 from the redundant units
of `F` = 3, then 3…6; packets 2, 3, 4, 5 played frame 1 from `F` = 2's last unit).

### V-AV10. Serial comparison and `framesLost` (§4.1, §4.4) [I][C]

| `a`, `b` | `a` newer than `b` | `a` older than `b` |
|---|---|---|
| 1, 0 | yes | no |
| 0, 65535 | yes | no |
| 65535, 0 | no | yes |
| 0, 32768 / 32768, 0 | no | no |
| 100, 32867 | no | yes |
| 100, 32869 | yes | no |

| `lastHandedOver`, `current` | `framesLost` |
|---|---|
| none, 7 | 0 |
| 5, 6 | 0 |
| 5, 9 | 3 |
| 65534, 1 | 2 |
| 65535, 0 | 0 |
| 10, 10 | 0 |

### V-AV11. HEVC slice parse and reference rewrite (§5.2, §5.3) [I][C]

Synthetic access units (made by the spec script; `log2_max_pic_order_cnt_lsb_minus4` = 0, no extra slice header
bits). P slice (NAL type 1, `slice_type` 1, POC LSB 5, 4 negative pictures, all `delta_poc_s0_minus1` = 0,
only picture 0 used):

```
000000010201d28beaa55ac33c9669966980        → P, d = 0
```

IDR slice (NAL type 20, `slice_type` 2): `000000012801ae956b0cf259a659a6` → I.

Rewrites of the P slice:

| `d'` | Result |
|---|---|
| 1 | `000000010201d28bbaa55ac33c9669966980` (re-parses as `d` = 1) |
| 2 | `000000010201d28baea55ac33c9669966980` (`d` = 2) |
| 3 | `000000010201d28baba55ac33c9669966980` (`d` = 3) |
| 4 | fails (`d' ≥ num_negative_pics`) |

[C]: the reference client's parser gave the same slice type and `d`, and its rewriter the same bytes for
`d'` = 1..3 and a failure for 4. (On failure it leaves every flag before the end of the list cleared; this spec
leaves the access unit unchanged, and the frame isn't handed over either way.)

### V-AV12. H.264 slice parse (§5.1) [I][C]

`log2_max_frame_num_minus4` = 3, `pic_order_cnt_type` 2, `frame_mbs_only_flag` 1:

| Access unit (synthetic) | Result |
|---|---|
| `00000001419a25988a55ac33c966996698` (P, frame_num 9, one modification idc 0 value 5) | P, `d` = 5 |
| `00000001419a28a55ac33c9669966980` (P, frame_num 10, no modification) | P, `d` = 0 |
| `00000001658880d2ad619e4b34cb34c0` (IDR NAL, `slice_type` 7) | I |

### V-AV13. Microphone encoder (§8.2) [C]

libopus with §8.2's settings, fed 200 frames (silence, a 440 Hz tone, noise): every packet was exactly 40
bytes, TOC byte `0xf4` (configuration 30 = CELT-only fullband 10 ms, stereo, one frame per packet; RFC 6716
§3.1). A libopus decoder at 48 kHz stereo returned 480 samples per channel for a packet and for concealment.

---

## Clarifications (2026-11-23)

Answers to implementer questions; facts checked against the reference client as a black box.

1. §2.4: the `unitIndex = n − 1` rule is unconditional (also for a frame's first unit); V-AV6's row
   "4, 0, 2" was wrong and is now "3, 0, 2", with "4, 0, 2" added as a failure.
2. §4.5: which count (`n`, `k + max(m,1)`) applies where when `fecUnits` = 0, and the difference from
   takion.md §8.3's wording.
3. §4.3: the repeated corrupt-frame range after an FEC failure is real; suppressing it is untested.
4. §4.3 step 1, §5.1: while waiting for an IDR, every parsed non-I slice is dropped; unparsable frames are
   handed over and leave the wait set.
5. §1 `codec`: no HEVC value on record; the byte isn't read for video.
6. §4.5, §7: haptics packets aren't in the congestion statistics.
7. §7: haptics apply the start-up rule with their own state.
8. §4.3 step 2: a dropped P slice with a missing reference triggers no IDR request.
9. §5.1: H.264 `d` with no idc-0 entry is 0; at most two entries parse.
10. §5.2, §4.3: HEVC NAL types 1 and 20 only (H.264: 1, 5); the start code must be 4 bytes at offset 0..64.
11. V-AV7: the capture's units are now in `data/vectors/av-capture-h264.txt`, with access-unit hashes.

## Sources

- ITU-T H.264 (06/2019) §7.3.2.1.1, §7.3.2.2, §7.3.3, §7.3.3.1, §7.4.1, §8.2.4.3.1, Annex B, Annex E.
- ITU-T H.265 (08/2021) §7.3.2.2, §7.3.2.3, §7.3.3, §7.3.6.1, §7.3.7, §7.4.2, Annex B.
- RFC 6716, Definition of the Opus Audio Codec (TOC §3.1, packet-loss concealment §4.4).
- RFC 1982, Serial Number Arithmetic.
- J. Blömer et al., "An XOR-Based Erasure-Resilient Coding Scheme", ICSI TR-95-048, 1995 (Cauchy
  Reed–Solomon).
- J. S. Plank, "Jerasure: A Library in C Facilitating Erasure Coding for Storage Applications", Univ. of
  Tennessee CS-08-627, 2008 (the original Cauchy matrix construction).
- J. S. Plank, K. Greenan, E. Miller, "Screaming Fast Galois Field Arithmetic Using Intel SIMD
  Instructions", FAST 2013.
