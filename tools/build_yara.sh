#!/bin/bash
# Reconstruit Resources/yara : YARA 4.6.0 (licence BSD, voir Resources/YARA-LICENSE.txt), binaire universel arm64 + x86_64.
# Les sources sont compilées directement avec clang (les analyseurs générés sont dans l'archive), sans autotools ni OpenSSL :
# le module « hash » utilise CommonCrypto, le module « macho » est activé (les règles XProtect s'en servent).
set -euo pipefail
cd "$(dirname "$0")/.."
WORK="$(mktemp -d)"
curl -sL https://github.com/VirusTotal/yara/archive/refs/tags/v4.6.0.tar.gz | tar xz -C "$WORK"
cd "$WORK/yara-4.6.0"
SRC="libyara/ahocorasick.c libyara/arena.c libyara/atoms.c libyara/base64.c libyara/bitmask.c libyara/compiler.c libyara/endian.c libyara/exec.c libyara/exefiles.c libyara/filemap.c libyara/grammar.c libyara/hash.c libyara/hex_grammar.c libyara/hex_lexer.c libyara/lexer.c libyara/libyara.c libyara/mem.c libyara/modules.c libyara/notebook.c libyara/object.c libyara/parser.c libyara/proc.c libyara/proc/none.c libyara/re.c libyara/re_grammar.c libyara/re_lexer.c libyara/rules.c libyara/scan.c libyara/scanner.c libyara/simple_str.c libyara/sizedstr.c libyara/stack.c libyara/stopwatch.c libyara/stream.c libyara/strutils.c libyara/threading.c libyara/modules/tests/tests.c libyara/modules/pe/pe.c libyara/modules/pe/pe_utils.c libyara/modules/elf/elf.c libyara/modules/math/math.c libyara/modules/time/time.c libyara/modules/console/console.c libyara/modules/string/string.c libyara/modules/hash/hash.c libyara/modules/macho/macho.c cli/args.c cli/common.c cli/threading.c cli/yara.c $(ls libyara/tlshc/*.c)"
# shellcheck disable=SC2086
clang -O2 -arch arm64 -arch x86_64 -mmacosx-version-min=12.0 -I libyara/include -I libyara -I . \
  -DBUCKETS_128=1 -DCHECKSUM_1B=1 -DHASH_MODULE -DMACHO_MODULE -DUSE_NO_PROC -DNDEBUG \
  -DHAVE_COMMONCRYPTO_COMMONCRYPTO_H=1 -DHAVE_STDBOOL_H=1 -DHAVE_TM_GMTOFF=1 -DHAVE_TIMEGM=1 -DDARWIN -w $SRC -o "$OLDPWD/Resources/yara"
echo "OK : Resources/yara"
