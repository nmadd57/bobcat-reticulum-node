// Android sparse image encoder, for flashing a large image through fastboot's 64 MiB download buffer.
// Each piece is a complete sparse image of the whole partition: a DONT_CARE chunk that skips to where this piece's data
// goes, one RAW chunk with the data, and a DONT_CARE chunk for the rest. U-Boot's fastboot applies each piece in turn.
export const BLK = 4096;
const MAGIC = 0xed26ff3a, RAW = 0xcac1, DONT_CARE = 0xcac3;

function header(totalBlocks, chunks) {
  const h = new DataView(new ArrayBuffer(28));
  h.setUint32(0, MAGIC, true); h.setUint16(4, 1, true); h.setUint16(6, 0, true);
  h.setUint16(8, 28, true); h.setUint16(10, 12, true);
  h.setUint32(12, BLK, true); h.setUint32(16, totalBlocks, true); h.setUint32(20, chunks, true); h.setUint32(24, 0, true);
  return new Uint8Array(h.buffer);
}
function chunkHeader(type, blocks, totalBytes) {
  const c = new DataView(new ArrayBuffer(12));
  c.setUint16(0, type, true); c.setUint16(2, 0, true); c.setUint32(4, blocks, true); c.setUint32(8, totalBytes, true);
  return new Uint8Array(c.buffer);
}

// One sparse image: `data` (a multiple of BLK long) placed at block `startBlock` of a partition `totalBlocks` long.
export function sparsePiece(totalBlocks, startBlock, data) {
  if (data.length % BLK) throw new Error("piece data must be a multiple of " + BLK);
  const nb = data.length / BLK, parts = [];
  if (startBlock + nb > totalBlocks) throw new Error("data runs past the end of the partition");
  if (startBlock > 0) parts.push(chunkHeader(DONT_CARE, startBlock, 12));
  parts.push(chunkHeader(RAW, nb, 12 + data.length), data);
  const rest = totalBlocks - startBlock - nb;
  if (rest > 0) parts.push(chunkHeader(DONT_CARE, rest, 12));
  const chunks = (startBlock > 0 ? 1 : 0) + 1 + (rest > 0 ? 1 : 0);
  const head = header(totalBlocks, chunks);
  let len = head.length; for (const p of parts) len += p.length;
  const out = new Uint8Array(len); let o = 0;
  out.set(head, o); o += head.length;
  for (const p of parts) { out.set(p, o); o += p.length; }
  return out;
}

// Turn a stream of bytes (async iterable of Uint8Array) into sparse pieces no bigger than maxBytes each.
// `imageBytes` is the data length; `partitionBytes` the partition size (must hold the data rounded up to a block).
export async function* sparsePieces(stream, imageBytes, partitionBytes, maxBytes = 64 * 1024 * 1024 - 4 * BLK) {
  const totalBlocks = Math.ceil(partitionBytes / BLK);
  if (Math.ceil(imageBytes / BLK) > totalBlocks) throw new Error("image is larger than the partition");
  const perPiece = Math.floor((maxBytes - 28 - 36) / BLK) * BLK;      // leave room for the headers
  let buf = new Uint8Array(perPiece), have = 0, block = 0;
  for await (let chunk of stream) {
    while (chunk.length) {
      const take = Math.min(chunk.length, perPiece - have);
      buf.set(chunk.subarray(0, take), have); have += take; chunk = chunk.subarray(take);
      if (have === perPiece) { yield { block, bytes: sparsePiece(totalBlocks, block, buf), dataBytes: have }; block += perPiece / BLK; buf = new Uint8Array(perPiece); have = 0; }
    }
  }
  if (have) {
    const padded = Math.ceil(have / BLK) * BLK;                          // zero-pad the last block
    yield { block, bytes: sparsePiece(totalBlocks, block, buf.subarray(0, padded)), dataBytes: have };
  }
}
