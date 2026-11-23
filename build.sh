#!/bin/zsh
set -e
cd "$(dirname "$0")"
APP="build/Loudness Preview.app"
V=Vendor
rm -rf build && mkdir -p build/obj "$APP/Contents/MacOS" "$APP/Contents/Resources"

# libogg + libvorbis + libopus + wrappers -> libLPCodecs.a (compiled in parallel)
CF=(-O2 -arch arm64 -mmacosx-version-min=15.0 -w)
SRCS=($V/libogg-1.3.5/src/{bitwise,framing}.c $V/LPCodecs/lp_vorbis.c)
for f in $V/libvorbis-1.3.7/lib/*.c; do
  case $(basename $f) in barkmel.c|psytune.c|tone.c) ;; *) SRCS+=$f ;; esac
done
for f in $SRCS; do
  clang $CF -I$V/libogg-1.3.5/include -I$V/libvorbis-1.3.7/include -I$V/libvorbis-1.3.7/lib \
    -c $f -o build/obj/v_$(basename $f .c).o &
done
O=$V/opus-1.5.2
OPUS_INC=(-DHAVE_CONFIG_H -I$V/opus_cfg -I$O/include -I$O/celt -I$O/silk -I$O/silk/float -I$O/src -I$O)
for f in $(cat $V/opus_files.txt); do
  clang $CF $OPUS_INC -c $O/$f -o build/obj/o_$(echo $f | tr '/' '_' | sed 's/\.c$//').o &
done
clang $CF -I$O/include -c $V/LPCodecs/lp_opus.c -o build/obj/w_lp_opus.o &
wait
ar rcs build/libLPCodecs.a build/obj/*.o

swiftc -O -swift-version 5 -parse-as-library -target arm64-apple-macos15.0 \
  -I $V/LPCodecs -L build Sources/*.swift -o "$APP/Contents/MacOS/LoudnessPreview"

cp Info.plist "$APP/Contents/"
[ -f AppIcon.icns ] && cp AppIcon.icns "$APP/Contents/Resources/"
codesign --force --deep -s - "$APP"
echo "$APP"
