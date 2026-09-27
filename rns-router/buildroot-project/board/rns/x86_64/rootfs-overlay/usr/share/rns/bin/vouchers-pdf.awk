# Minimal voucher PDF emitter. Reads 13-column rows on stdin.
BEGIN { printf "%%PDF-1.4\n%%EOF\n" }
