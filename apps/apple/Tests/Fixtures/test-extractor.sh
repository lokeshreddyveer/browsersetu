#!/bin/sh
# Deterministic stand-in for an external extractor (tests only). Behaviour is chosen by words in the page address; it never touches the network.
if [ "$1" = "--version" ]; then echo "2099.01.01-stand-in"; exit 0; fi
for last; do :; done
U="$last"
BASE=$(printf '%s' "$U" | sed -E 's#^(https?://[^/]+/media/[^/]+)/.*#\1#')
case "$U" in *recordargs*) printf '%s\n' "$@" > "${HOME%/}/bs-ext-args.txt" ;; esac    # lets a test see the exact arguments the app really started this program with
case "$U" in *counted*) echo run >> "${HOME%/}/bs-ext-count.txt" ;; esac    # lets a test count how many times the program really ran
case "$U" in
*flatlist*)
  S=1; E=9999; prev=""
  for a in "$@"; do case "$prev" in --playlist-start) S=$a;; --playlist-end) E=$a;; esac; prev=$a; done
  printf '{"_type":"playlist","id":"pl1","title":"Test List","webpage_url":"%s","entries":[' "$U"
  i=$S; first=1
  while [ "$i" -le "$E" ] && [ "$i" -le 7 ]; do
    [ "$first" = 0 ] && printf ','; first=0
    if [ "$i" = 5 ]; then printf 'null'; elif [ "$i" = 7 ]; then printf '{"_type":"url","id":"vid7","title":"Item 7: gone","url":"%s/fail7/page.html","duration":70}' "$BASE"; else printf '{"_type":"url","id":"vid%s","title":"Item %s: Ünï","url":"%s/vid%s/page.html","duration":%s}' "$i" "$i" "$BASE" "$i" "$((i * 10))"; fi
    i=$((i + 1))
  done
  printf ']}' ;;
*descendant*) sleep 60 & echo $! > "${HOME%/}/bs-ext-child.pid"; wait ;;
*helperchild*) H=$(cat "${HOME%/}/bs-helper-path.txt"); printf 'while(true){}' | "$H" --deadline 60 - & echo $! > "${HOME%/}/bs-helper-child.pid"; wait ;;
*stubborn*) trap '' TERM; while :; do sleep 1; done ;;
*bighuge*) printf '{"id":"h","title":"t","webpage_url":"%s","formats":[{"url":"%s/clip.mp4","ext":"mp4","vcodec":"avc1","acodec":"mp4a","height":1e300,"width":-5,"fps":1e30,"tbr":1e300,"filesize":9e99,"protocol":"https"},{"url":"%s/clip2.mp4","ext":"mp4","vcodec":"avc1","acodec":"mp4a","height":720,"tbr":4000,"protocol":"https","format_id":"ok"}]}' "$U" "$BASE" "$BASE" ;;
*nowebpage*) printf '{"id":"n","title":"t","formats":[{"url":"%s/clip.mp4","ext":"mp4","vcodec":"avc1","acodec":"mp4a","height":120,"protocol":"https"}]}' "$BASE" ;;
*two*) printf '{"id":"two","title":"Two qualities","webpage_url":"%s","formats":[{"format_id":"hd","url":"%s/clip.mp4","ext":"mp4","vcodec":"avc1","acodec":"mp4a","height":720,"protocol":"https"},{"format_id":"sd","url":"%s/clip2.mp4","ext":"mp4","vcodec":"avc1","acodec":"mp4a","height":360,"protocol":"https"}]}' "$U" "$BASE" "$BASE" ;;
*malformed*) echo "this is not json" ;;
*huge*) yes aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa | head -c 9000000 ;;
*slow*) sleep 20; echo '{}' ;;
*fail*) echo "ERROR: Video unavailable" >&2; exit 3 ;;
*noformats*) printf '{"id":"x1","title":"Nothing","webpage_url":"%s","formats":[]}' "$U" ;;
*wrongvideo*) printf '{"id":"x2","title":"Other","webpage_url":"https://other-site.example/v","formats":[{"url":"%s/clip.mp4","ext":"mp4","vcodec":"avc1","acodec":"mp4a","height":120,"protocol":"https"}]}' "$BASE" ;;
*expired*) printf '{"id":"x3","title":"Old","webpage_url":"%s","formats":[{"url":"%s/clip.mp4","ext":"mp4","vcodec":"avc1","acodec":"mp4a","height":120,"protocol":"https","url_expires":1000000000}]}' "$U" "$BASE" ;;
*dashonly*) printf '{"id":"x4","title":"Dash","webpage_url":"%s","formats":[{"url":"%s/m.mpd","ext":"mp4","vcodec":"avc1","acodec":"none","height":720,"protocol":"http_dash_segments"}]}' "$U" "$BASE" ;;
*separate*) printf '{"id":"x5","title":"Separate tracks","thumbnail":"https://example.com/t.jpg","webpage_url":"%s","formats":[{"format_id":"v","url":"%s/v.mp4","ext":"mp4","vcodec":"avc1","acodec":"none","width":160,"height":120,"fps":30,"protocol":"https"},{"format_id":"a","url":"%s/a.m4a","ext":"m4a","vcodec":"none","acodec":"mp4a","language":"en","protocol":"https"},{"format_id":"c","url":"%s/needs.mp4","ext":"mp4","vcodec":"avc1","acodec":"mp4a","height":1080,"protocol":"https","http_headers":{"Cookie":"x=1"}}]}' "$U" "$BASE" "$BASE" "$BASE" ;;
*) printf '{"id":"x6","title":"Muxed clip","webpage_url":"%s","formats":[{"format_id":"18","url":"%s/clip.mp4","ext":"mp4","vcodec":"avc1","acodec":"mp4a","width":320,"height":176,"fps":25,"filesize":788493,"protocol":"https"}]}' "$U" "$BASE" ;;
esac
