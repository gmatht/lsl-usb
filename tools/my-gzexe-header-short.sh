#!/bin/sh
D=$(dirname "$0");N=$(basename "$0");T="$D/.$N.tmp"
E(){awk '/^8$/{f=1;next}f' "$0"|gunzip;}
case $1 in
--unpack)
	E>"$T"&&{chmod 700 "$T";mv -f "$T" "$0"&&{echo "Unpacked.";exit 0;};}
	rm -f "$T";echo "Decompress/Write failed">&2;exit 9;;
esac
case $TMPDIR in /*/) ;; /*) TMPDIR=$TMPDIR/ ;; *) TMPDIR=/tmp/ ;; esac
Z=${TMPDIR}z$$;mkdir -p "$Z"||exit 9;G="$Z/$N"
echo "packed executable. run $0 --unpack to unpack">&2
E>"$G"&&{chmod 700 "$G";(sleep 5;rm -fr "$Z")2>/dev/null&;exec "$G" "$@";}
echo "Cannot decompress $0">&2;rm -fr "$Z"
exit 8
