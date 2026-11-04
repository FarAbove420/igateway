# Third-party software

iGateway.exe is licensed under the Apache License 2.0 (see `LICENSE`). It is
built on the work of the projects below. Everything in the first part is
compiled into the app, from source, by `deps/build-deps.zsh`. None of these
projects ships a NOTICE file.

## Compiled into the app

### FreeRDP

The Remote Desktop protocol: connecting, the RD Gateway, graphics, sound,
clipboard and the shared folder.

- https://github.com/FreeRDP/FreeRDP, version 3.33.0
- Apache License 2.0, the same text as `LICENSE`. Copyright the FreeRDP
  contributors.
- Built with FreeRDP's own MD4 and RC4 (`WITH_INTERNAL_MD4`,
  `WITH_INTERNAL_RC4`). Its MD4 code (`winpr/libwinpr/crypto/md4.c`) was
  written by Alexander Peslyak and is in the public domain.
- Its time zone table (`winpr/libwinpr/timezone/WindowsZones.c`) is generated
  from Unicode CLDR data: see Unicode below.

### OpenSSL

TLS and the cryptography FreeRDP uses to log in.

- https://github.com/openssl/openssl, version 3.6.5
- Apache License 2.0, the same text as `LICENSE`. Copyright the OpenSSL
  Project Authors.

### SwiftTerm

The terminal of SSH sessions.

- https://github.com/migueldeicaza/SwiftTerm, version 1.20.0
- MIT License, below. The app carries it as `SwiftTerm-LICENSE.txt`.
- SwiftTerm is based on xterm.js (https://github.com/xtermjs/xterm.js, MIT,
  in the same licence text), and has a small part ported from libsixel and
  tables generated from Unicode data: see both below.

```
Copyright (c) 2019-2026 Miguel de Icaza (https://github.com/migueldeicaza)
Copyright (c) 2017-2019, The xterm.js authors (https://github.com/xtermjs/xterm.js)
Copyright (c) 2014-2016, SourceLair Private Company (https://www.sourcelair.com)
Copyright (c) 2012-2013, Christopher Jeffrey (https://github.com/chjj/)

Permission is hereby granted, free of charge, to any person obtaining
a copy of this software and associated documentation files (the
"Software"), to deal in the Software without restriction, including
without limitation the rights to use, copy, modify, merge, publish,
distribute, sublicense, and/or sell copies of the Software, and to
permit persons to whom the Software is furnished to do so, subject to
the following conditions:

The above copyright notice and this permission notice shall be
included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
```

### libsixel

A colour conversion SwiftTerm ported from it, for sixel images.

- https://github.com/saitoha/libsixel
- MIT License:

```
Copyright (c) 2014-2016 Hayaki Saito

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
the Software, and to permit persons to whom the Software is furnished to do so,
subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
```

### Unicode data

FreeRDP's Windows time zone names come from the Unicode CLDR
(`windowsZones.xml`). SwiftTerm's character widths, Arabic shaping and bidi
mirroring come from the Unicode Character Database 17.0.

- https://cldr.unicode.org and https://www.unicode.org/ucd/
- Unicode License V3:

```
UNICODE LICENSE V3

COPYRIGHT AND PERMISSION NOTICE

Copyright © 1991-2026 Unicode, Inc.

NOTICE TO USER: Carefully read the following legal agreement. BY
DOWNLOADING, INSTALLING, COPYING OR OTHERWISE USING DATA FILES, AND/OR
SOFTWARE, YOU UNEQUIVOCALLY ACCEPT, AND AGREE TO BE BOUND BY, ALL OF THE
TERMS AND CONDITIONS OF THIS AGREEMENT. IF YOU DO NOT AGREE, DO NOT
DOWNLOAD, INSTALL, COPY, DISTRIBUTE OR USE THE DATA FILES OR SOFTWARE.

Permission is hereby granted, free of charge, to any person obtaining a
copy of data files and any associated documentation (the "Data Files") or
software and any associated documentation (the "Software") to deal in the
Data Files or Software without restriction, including without limitation
the rights to use, copy, modify, merge, publish, distribute, and/or sell
copies of the Data Files or Software, and to permit persons to whom the
Data Files or Software are furnished to do so, provided that either (a)
this copyright and permission notice appear with all copies of the Data
Files or Software, or (b) this copyright and permission notice appear in
associated Documentation.

THE DATA FILES AND SOFTWARE ARE PROVIDED "AS IS", WITHOUT WARRANTY OF ANY
KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT OF
THIRD PARTY RIGHTS.

IN NO EVENT SHALL THE COPYRIGHT HOLDER OR HOLDERS INCLUDED IN THIS NOTICE
BE LIABLE FOR ANY CLAIM, OR ANY SPECIAL INDIRECT OR CONSEQUENTIAL DAMAGES,
OR ANY DAMAGES WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS,
WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION,
ARISING OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THE DATA
FILES OR SOFTWARE.

Except as contained in this notice, the name of a copyright holder shall
not be used in advertising or otherwise to promote the sale, use or other
dealings in these Data Files or Software without prior written
authorization of the copyright holder.

SPDX-License-Identifier: Unicode-3.0
```

## Used, not shipped

- **OpenSSH**, https://www.openssh.com: SSH sessions run the `ssh` that comes
  with macOS. Nothing of it is copied into the app.
- **CMake**, https://cmake.org (BSD 3-Clause): downloaded by
  `deps/build-deps.zsh` to build FreeRDP, and not part of the app.

Nothing else is linked besides frameworks and libraries that ship with macOS,
such as VideoToolbox, which decodes the H.264 video.
