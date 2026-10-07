#!/usr/bin/env python3
"""Copy repaired ext4 data into make_ext4fs's original sparse layout.

Keep DONT_CARE ranges: img2simg turns them into FILL ranges, causing the
AXDL target to write the entire partition rather than just the used data.
Abort if a repair changed a skipped range instead of silently losing it.
"""
import os
from pathlib import Path
import struct
import sys
import tempfile

BUFFER_SIZE = 1024 * 1024
RAW = 0xCAC1
DONT_CARE = 0xCAC3


def update(sparse_path, raw_path):
    sparse_path = Path(sparse_path)
    temporary = None
    try:
        with sparse_path.open('rb') as sparse, open(raw_path, 'rb') as raw:
            header = sparse.read(28)
            magic, major, minor, file_hdr, chunk_hdr, block_size, blocks, chunks, crc = struct.unpack('<IHHHHIIII', header)
            if (magic, major, minor, file_hdr, chunk_hdr, crc) != (0xED26FF3A, 1, 0, 28, 12, 0):
                raise ValueError('Expected the standard make_ext4fs sparse header without a checksum')
            if not block_size or os.fstat(raw.fileno()).st_size != blocks * block_size:
                raise ValueError('Expanded filesystem size does not match sparse header')
            zero = bytes(BUFFER_SIZE)
            expanded = skipped = written = 0
            with tempfile.NamedTemporaryFile(dir=sparse_path.parent, prefix=sparse_path.name + '.', delete=False) as output:
                temporary = Path(output.name)
                os.fchmod(output.fileno(), os.fstat(sparse.fileno()).st_mode & 0o777)
                output.write(header)
                for index in range(chunks):
                    chunk = sparse.read(chunk_hdr)
                    kind, reserved, count, size = struct.unpack('<HHII', chunk)
                    length = count * block_size
                    if count == 0 or expanded + length > blocks * block_size:
                        raise ValueError(f'Invalid block range in chunk {index}')
                    if kind == RAW and size == chunk_hdr + length:
                        sparse.seek(length, os.SEEK_CUR)
                        written += length
                    elif kind == DONT_CARE and size == chunk_hdr:
                        skipped += length
                    else:
                        raise ValueError(f'Unexpected chunk type/size in chunk {index}: {kind:#x}')
                    output.write(chunk)
                    remaining = length
                    while remaining:
                        amount = min(remaining, BUFFER_SIZE)
                        data = raw.read(amount)
                        if len(data) != amount:
                            raise ValueError('Truncated expanded filesystem')
                        if kind == RAW:
                            output.write(data)
                        elif data != zero[:amount]:
                            raise ValueError(f'Repair modified skipped chunk {index} at expanded offset {expanded + length - remaining}')
                        remaining -= amount
                    expanded += length
                if expanded != blocks * block_size or sparse.tell() != os.fstat(sparse.fileno()).st_size:
                    raise ValueError('Sparse chunk totals or file length do not match the header')
                output.flush()
                os.fsync(output.fileno())
        os.replace(temporary, sparse_path)
        temporary = None
        print(f'Preserved {chunks} sparse chunks: RAW {written} bytes, DONT_CARE {skipped} bytes; no FILL chunks')
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


if __name__ == '__main__':
    if len(sys.argv) != 3:
        sys.exit(f'Usage: {sys.argv[0]} MAKE_EXT4FS_SPARSE REPAIRED_RAW_EXT4')
    update(sys.argv[1], sys.argv[2])
