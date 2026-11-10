LAME 3.100 (https://lame.sourceforge.io), the MP3 encoder, GNU LGPL 2.1 (see COPYING and LICENSE).
Source tarball sha256 ddfe36cab873794038ae2c1210557ad34857a4b6bdc515785d1da9e175b1da1e (the published release). The encoder sources are unmodified. Left out of this copy: the autotools build
files, the x86 assembly, the SSE vector code (only its header is kept), the MP3 decoder interface, the frontend and the documentation.

Packaging: LAME is built as its own DYNAMIC library, libmp3lame.dylib (project.yml target MP3Lame, arm64), and embedded in the app at Contents/Frameworks/libmp3lame.dylib, loaded through @rpath.
It is not statically linked into the application. LGPL 2.1 section 6 is met by this separation plus the source here: to use a modified LAME, rebuild the MP3Lame target from this folder and
replace Contents/Frameworks/libmp3lame.dylib in a copy of the app, then re-sign that copy with your own signing identity (the app uses the hardened runtime, whose library validation accepts only
libraries signed by the same team, so a replaced library needs the copy re-signed; ad-hoc signing works for a copy you run yourself). This is a description of the technical route, not legal advice.
A Mac App Store variant is not compatible with these terms.

Acknowledgement: this product uses LAME, the MP3 encoder (https://lame.sourceforge.io, www.mp3dev.org). LAME's own license file (bundled as LAME-LICENSE.txt) says a product may link to LAME as a
separate library under the LGPL, acknowledge it with a link to the project, and release any modifications to LAME under the LGPL. Browser Setu makes no modifications. Patent note: the MP3 patents of
the main licensors have expired; this is not legal advice.
