#!/bin/zsh
# Builds lpcore.wasm (codecs + resampler + DSP) for the Windows/Electron app.
set -e
cd "$(dirname "$0")"
ZIG=${ZIG:-$HOME/.local/opt/zig/zig}
V=../../Vendor
OBJ=build/obj
rm -rf build && mkdir -p $OBJ
TGT=(-target wasm32-wasi -mexec-model=reactor)
CF=($TGT -O3 -msimd128 -w)
JOBS=0
run() { "$@" & JOBS=$((JOBS+1)); if (( JOBS >= 8 )); then wait; JOBS=0; fi }

# libogg + libvorbis
for f in $V/libogg-1.3.5/src/{bitwise,framing}.c $V/libvorbis-1.3.7/lib/*.c $V/LPCodecs/lp_vorbis.c; do
  case $(basename $f) in barkmel.c|psytune.c|tone.c) continue ;; esac
  run $ZIG cc $CF -I$V/libogg-1.3.5/include -I$V/libvorbis-1.3.7/include -I$V/libvorbis-1.3.7/lib \
    -c $f -o $OBJ/v_$(basename $f .c).o
done
# libopus
O=$V/opus-1.5.2
OPUS_INC=(-DHAVE_CONFIG_H -I$V/opus_cfg -I$O/include -I$O/celt -I$O/silk -I$O/silk/float -I$O/src -I$O)
for f in $(cat $V/opus_files.txt); do
  run $ZIG cc $CF $OPUS_INC -c $O/$f -o $OBJ/o_$(echo $f | tr '/' '_' | sed 's/\.c$//').o
done
run $ZIG cc $CF -I$O/include -c $V/LPCodecs/lp_opus.c -o $OBJ/w_lp_opus.o
# fdk-aac (C++)
A=$V/fdk-aac-2.0.3
AINC=()
for d in $A/lib*/include; do AINC+=(-I$d); done
for f in $A/lib*/src/*.cpp; do
  run $ZIG c++ $CF -fno-exceptions -fno-rtti $AINC -c $f -o $OBJ/a_$(basename $f .cpp).o
done
S=$V/speexdsp-1.2.1
# wrappers (+ speexdsp resampler via src/lp_speex.c)
for f in src/*.c; do
  run $ZIG cc $CF -I$V/LPCodecs -Isrc $AINC -DOUTSIDE_SPEEX -DFLOATING_POINT -DRANDOM_PREFIX=lpspx \
    -I$S/include/speex -I$S/libspeexdsp \
    -c $f -o $OBJ/w_$(basename $f .c).o
done
wait

EXPORTS=(lp_malloc lp_free lp_vorbis_roundtrip lp_opus_roundtrip lp_aac_roundtrip lp_resample
  lp_integrated lp_sample_peak lp_true_peak lp_limiter_envelope lp_waveform lp_align_lag)
LF=()
for e in $EXPORTS; do LF+=(-Wl,--export=$e); done
$ZIG c++ $TGT -O3 -msimd128 -fno-exceptions -fno-rtti $OBJ/*.o $LF \
  -Wl,--initial-memory=67108864 -Wl,--max-memory=4294901760 -Wl,--growable-table -Wl,--strip-all \
  -o lpcore.wasm
ls -lh lpcore.wasm
