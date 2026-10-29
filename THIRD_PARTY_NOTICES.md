# Third-Party Notices

Murmurly is released under the MIT License (see `LICENSE`). This file lists the
third-party software built into the app and the speech models the app can
download, with their licenses. The same file ships inside the app at
`Contents/Resources/THIRD_PARTY_NOTICES.md`.

## Software included in the app

The app uses five Swift packages, each pinned to an exact version in
`project.yml`. Three are compiled into the app binary; Sparkle is a prebuilt
framework embedded in the app; the MCP Swift SDK, with the packages it links,
is compiled only into the `murmurly` helper at `Contents/Helpers/murmurly`. The
Apache License 2.0, used by several of them, is reproduced once at the end of
this file.

| Component | Version | License |
|---|---|---|
| WhisperKit (Argmax OSS) | 1.0.0 | MIT |
| — swift-transformers (Hub, Tokenizers), included in WhisperKit | 1.1.6 | Apache-2.0 |
| KeyboardShortcuts | 3.0.1 | MIT |
| FluidAudio | 0.15.5 | Apache-2.0 |
| — fastcluster, included in FluidAudio | — | BSD-2-Clause |
| — VBx, included in FluidAudio | — | Apache-2.0 |
| — NVIDIA NeMo (Sortformer, CTC word spotting), ported in FluidAudio | — | Apache-2.0 |
| Sparkle | 2.10.0 | MIT |
| — bsdiff / bspatch 4.3, included in Sparkle | — | BSD-2-Clause |
| — sais-lite, included in Sparkle | — | MIT |
| — Ed25519 (orlp/ed25519), included in Sparkle | — | Zlib |
| — `SUSignatureVerifier.m`, included in Sparkle | — | BSD-2-Clause |
| MCP Swift SDK (`murmurly` helper only) | 0.12.1 | MIT and Apache-2.0 |
| — swift-log, linked by the MCP SDK | 1.16.2 | Apache-2.0 |
| — swift-system, linked by the MCP SDK | 1.8.1 | Apache-2.0 with Runtime Library Exception |
| — EventSource, linked by the MCP SDK | 1.5.1 | MIT |

`swift-argument-parser` is also fetched by Swift Package Manager, because
WhisperKit declares it for its command-line tool. It is not linked into the app.

### WhisperKit (Argmax OSS) 1.0.0

- Source: <https://github.com/argmaxinc/argmax-oss-swift> (formerly
  `argmaxinc/WhisperKit`), tag `v1.0.0`, commit
  `25c62997041c134b03ca82731ce2f6fd2cae1eb9`.
- Linked: the `WhisperKit` library product (targets `WhisperKit` and `ArgmaxCore`).
- License: MIT.

```text
MIT License

Copyright (c) 2024 argmax, inc.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

WhisperKit's `NOTICES` file:

```text
This file lists third-party software incorporated into Argmax OSS and the
license terms under which that software is distributed. Argmax OSS itself is
released under the MIT License (see LICENSE in the repository root).

================================================================================
swift-transformers
================================================================================

Portions of Argmax OSS (under Sources/ArgmaxCore/External) are derived from the
swift-transformers project:

  https://github.com/huggingface/swift-transformers

Copyright 2022 Hugging Face SAS.

These files have been modified by Argmax, Inc. Modifications are marked in the
source with "Argmax-modification:" comments, and each derived file retains its
original copyright notice in the file header.

Licensed under the Apache License, Version 2.0 (the "License"); you may not use
these files except in compliance with the License. You may obtain a copy of the
License at:

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software distributed
under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
CONDITIONS OF ANY KIND, either express or implied. See the License for the
specific language governing permissions and limitations under the License.

The full text of the Apache License, Version 2.0 follows.
```

The Apache License 2.0 text that the `NOTICES` file goes on to include is
reproduced at the end of this file. All 19 files in `Sources/ArgmaxCore/External`
name swift-transformers version 1.1.6, commit
`573e5c9036c2f136b3a8a071da8e8907322403d0`, as their origin. One of them,
`Hub/Downloader.swift`, was itself adapted by Hugging Face from
[swift-coreml-diffusers](https://github.com/huggingface/swift-coreml-diffusers),
Copyright 2022 Hugging Face SAS, also under the Apache License 2.0.

### KeyboardShortcuts 3.0.1

- Source: <https://github.com/sindresorhus/KeyboardShortcuts>, tag `3.0.1`,
  commit `49c3fc04ea827f816df67843bfcc57286b47ff06`.
- Linked: the `KeyboardShortcuts` library product and its resource bundle.
- License: MIT.

```text
MIT License

Copyright (c) Sindre Sorhus <sindresorhus@gmail.com> (https://sindresorhus.com)

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
```

### FluidAudio 0.15.5

- Source: <https://github.com/FluidInference/FluidAudio>, tag `v0.15.5`, commit
  `19600a485baa4998812e4654b70d2bab8f2c9949`.
- Linked: the `FluidAudio` library product (targets `FluidAudio`,
  `FastClusterWrapper` and `MachTaskSelfWrapper`).
- License: Apache License 2.0, text at the end of this file. The package's
  `LICENSE` file names no copyright holder; its `CITATION.cff` names the authors
  as "FluidInference Team". The package has no `NOTICE` file.

FluidAudio includes the following third-party code. The fastcluster and VBx
license texts below come from its `ThirdPartyLicenses/` folder; NVIDIA NeMo is
not listed there and is named only in FluidAudio's source comments.

#### fastcluster

- Source: <https://github.com/fastcluster/fastcluster>, included in FluidAudio as
  `Sources/FastClusterWrapper/fastcluster_internal.hpp`.
- License: BSD 2-Clause.

```text
Copyright:
  * Until package version 1.1.23: © 2011 Daniel Müllner <https://danifold.net>
  * All changes from version 1.1.24 on: © Google Inc. <https://www.google.com>
All rights reserved.

Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:

  * Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.
  * Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

#### VBx

- Source: <https://github.com/BUTSpeechFIT/VBx>. FluidAudio's
  `Diarizer/Offline/Clustering/VBxClustering.swift` implements the VBx algorithm.
- License: Apache License 2.0, text at the end of this file.
- Copyright, as stated in FluidAudio's `ThirdPartyLicenses/vbx-LICENSE.md`:
  "Copyright 2021-2024 BUT Speech@FIT (original VBx project)". The upstream
  source files carry "Copyright 2021 Lukas Burget, Mireia Diez".

#### NVIDIA NeMo

- Source: <https://github.com/NVIDIA/NeMo>. FluidAudio 0.15.5 contains Swift
  ports of NeMo code:
  - Sortformer streaming diarization: `Diarizer/Sortformer/SortformerStateUpdater.swift`
    ("mirrors NeMo's StateUpdater class, ported from the default implementation")
    and `SortformerStreamingState` in `Diarizer/Sortformer/SortformerTypes.swift`,
    both referring to NeMo's `nemo/collections/asr/modules/sortformer_modules.py`;
  - CTC keyword spotting: `ASR/Parakeet/SlidingWindow/CustomVocabulary/WordSpotting/CtcDPAlgorithm.swift`
    and `ContextBiasingConstants.swift`, which name NeMo's `ctc_word_spotter.py`
    (in NeMo today: `nemo/collections/asr/parts/context_biasing/ctc_based_word_spotter.py`).
- License: Apache License 2.0, text at the end of this file.
- Copyright, as stated in both NeMo source files: "Copyright (c) 2025, NVIDIA
  CORPORATION & AFFILIATES. All rights reserved." (checked at NeMo commit
  `09e7f98196f5053f3c759e1fe76d70e0b4c1e6c7`).
- FluidAudio does not record which NeMo revision it ported from.

### Sparkle 2.10.0

- Source: <https://github.com/sparkle-project/Sparkle>, tag `2.10.0`, commit
  `eef1a539a373c1f1a320624b1130fc5de7b2e100`.
- Linked: the `Sparkle` library product, a prebuilt binary
  (`Sparkle-for-Swift-Package-Manager.zip` from the 2.10.0 release, SHA-256
  `17e28312b8e18ab7cdbbe09a6fb28cc55a5479ec6c371dbc07cdecd2a14fd959`), embedded
  as `Contents/Frameworks/Sparkle.framework` with its `Autoupdate` and
  `Updater.app` helpers and its `Installer` and `Downloader` XPC services. The
  command-line tools in the same archive are used only to publish releases and
  are not part of the app.
- License: MIT. Sparkle's `LICENSE` file, reproduced below in full, also
  contains the licenses of the third-party code included in Sparkle: bsdiff and
  bspatch, sais-lite, a portable C implementation of Ed25519, and
  `SUSignatureVerifier.m`. The file is the same in the 2.10.0 tag and in the
  release archive.

```text
Copyright (c) 2006-2013 Andy Matuschak.
Copyright (c) 2009-2013 Elgato Systems GmbH.
Copyright (c) 2011-2014 Kornel Lesiński.
Copyright (c) 2015-2017 Mayur Pawashe.
Copyright (c) 2014 C.W. Betts.
Copyright (c) 2014 Petroules Corporation.
Copyright (c) 2014 Big Nerd Ranch.
All rights reserved.

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

=================
EXTERNAL LICENSES
=================

bspatch.c and bsdiff.c, from bsdiff 4.3 <http://www.daemonology.net/bsdiff/>:

Copyright 2003-2005 Colin Percival
All rights reserved

Redistribution and use in source and binary forms, with or without
modification, are permitted providing that the following conditions 
are met:
1. Redistributions of source code must retain the above copyright
   notice, this list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright
   notice, this list of conditions and the following disclaimer in the
   documentation and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR
IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY
DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING
IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
POSSIBILITY OF SUCH DAMAGE.

--

sais.c and sais.h, from sais-lite (2010/08/07) <https://sites.google.com/site/yuta256/sais>:

The sais-lite copyright is as follows:

Copyright (c) 2008-2010 Yuta Mori All Rights Reserved.

Permission is hereby granted, free of charge, to any person
obtaining a copy of this software and associated documentation
files (the "Software"), to deal in the Software without
restriction, including without limitation the rights to use,
copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the
Software is furnished to do so, subject to the following
conditions:

The above copyright notice and this permission notice shall be
included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
OTHER DEALINGS IN THE SOFTWARE.

--

Portable C implementation of Ed25519, from https://github.com/orlp/ed25519

Copyright (c) 2015 Orson Peters <orsonpeters@gmail.com>

This software is provided 'as-is', without any express or implied warranty. In no event will the
authors be held liable for any damages arising from the use of this software.

Permission is granted to anyone to use this software for any purpose, including commercial
applications, and to alter it and redistribute it freely, subject to the following restrictions:

1. The origin of this software must not be misrepresented; you must not claim that you wrote the
   original software. If you use this software in a product, an acknowledgment in the product
   documentation would be appreciated but is not required.

2. Altered source versions must be plainly marked as such, and must not be misrepresented as
   being the original software.

3. This notice may not be removed or altered from any source distribution.

--

SUSignatureVerifier.m:

Copyright (c) 2011 Mark Hamlin.

All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted providing that the following conditions
are met:
1. Redistributions of source code must retain the above copyright
   notice, this list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright
   notice, this list of conditions and the following disclaimer in the
   documentation and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR
IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY
DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING
IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
POSSIBILITY OF SUCH DAMAGE.
```

### MCP Swift SDK 0.12.1

- Source: <https://github.com/modelcontextprotocol/swift-sdk>, tag `0.12.1`,
  commit `a0ae212ebf6eab5f754c3129608bc5557637e605`.
- Linked: the `MCP` library product, into the `murmurly` helper only.
- License: the project is moving from the MIT License to the Apache License 2.0;
  code whose authors agreed is under Apache-2.0 (text at the end of this file),
  the rest stays under the MIT License below. The SDK also declares SwiftNIO and
  its dependencies for its own conformance tools; Swift Package Manager fetches
  them, but they are not linked into the helper.

```text
MIT License

Copyright (c) 2024-2025 Model Context Protocol a Series of LF Projects, LLC.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

#### swift-log 1.16.2

- Source: <https://github.com/apple/swift-log>, tag `1.16.2`, commit
  `c9c6bb9d275ec0d95c3ad16391f3f045dc623104`.
- License: Apache License 2.0, text at the end of this file. Its `NOTICE.txt`:

```text
                            The SwiftLog Project
                            ========================

Please visit the SwiftLog web site for more information:

  * https://github.com/apple/swift-log

Copyright 2018, 2019 The SwiftLog Project

The SwiftLog Project licenses this file to you under the Apache License,
version 2.0 (the "License"); you may not use this file except in compliance
with the License. You may obtain a copy of the License at:

  https://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
License for the specific language governing permissions and limitations
under the License.

Also, please refer to each LICENSE.<component>.txt file, which is located in
the 'license' directory of the distribution file, for the license terms of the
components that this product depends on.

-------------------------------------------------------------------------------

This product contains a derivation of the lock implementation and various
scripts from SwiftNIO.
```

#### swift-system 1.8.1

- Source: <https://github.com/apple/swift-system>, tag `1.8.1`, commit
  `869129b7bf4ecc57b97d0193ad29690ca2134750`.
- License: Apache License 2.0 (text at the end of this file) with the Runtime
  Library Exception: portions of the project embedded into an object form by
  compiling the source need not carry the attribution the license otherwise asks
  for. It is listed here all the same.

#### EventSource 1.5.1

- Source: <https://github.com/mattt/eventsource>, tag `1.5.1`, commit
  `86b5096ac59ab46e66bd1f6377c604bc1dab0bc2`.
- License: MIT.

```text
Copyright 2025 Mattt (https://mat.tt)

Permission is hereby granted, free of charge, to any person obtaining a
copy of this software and associated documentation files (the "Software"),
to deal in the Software without restriction, including without limitation
the rights to use, copy, modify, merge, publish, distribute, sublicense,
and/or sell copies of the Software, and to permit persons to whom the
Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
DEALINGS IN THE SOFTWARE.
```

## Speech models

**The models are not part of the app or of this repository.** The app downloads
a model only when you ask it to, directly from Hugging Face, at the exact
revision listed below. Each model is covered by its own license, and that
license applies to your copy.

| Model | Used for | Hugging Face repository | License |
|---|---|---|---|
| Parakeet TDT 0.6B v3 (Core ML) | Parakeet engine | `FluidInference/parakeet-tdt-0.6b-v3-coreml` | CC-BY-4.0 (NVIDIA) |
| Whisper large-v3 turbo (Core ML) | Whisper engine | `argmaxinc/whisperkit-coreml` | MIT |
| Whisper tokenizer | Whisper engine | `openai/whisper-large-v3` | Apache-2.0 |
| Silero VAD v6.2.1 (Core ML) | Finding speech in meetings and files | `FluidInference/silero-vad-coreml` | MIT |

### Parakeet TDT 0.6B v3 (Core ML)

- Downloaded from
  <https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml>, revision
  `7dd20fe6b1797d35f5e3307e8b1732d9a178edfe`: `Preprocessor.mlmodelc`,
  `Encoder.mlmodelc`, `Decoder.mlmodelc`, `JointDecisionv3.mlmodelc`,
  `parakeet_vocab.json`.
- Original model: [nvidia/parakeet-tdt-0.6b-v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3)
  by NVIDIA. Its model card states: "GOVERNING TERMS: Use of this model is
  governed by the CC-BY-4.0 license."
- The Core ML conversion's model card is inconsistent: its metadata declares
  `license: cc-by-4.0`, while its "License" section reads "Apache 2.0. See the
  FluidAudio repository for details and usage guidance." The weights are
  converted from NVIDIA's model, which NVIDIA licenses under CC BY 4.0, and that
  license governs them. The Apache 2.0 mention appears to refer to the FluidAudio
  software rather than to these weights.

**Attribution.** "parakeet-tdt-0.6b-v3" by NVIDIA, licensed under
[CC BY 4.0](https://creativecommons.org/licenses/by/4.0/). Converted to Core ML
by FluidInference ([conversion code](https://github.com/FluidInference/mobius/tree/main/models/stt/parakeet-tdt-v3-0.6b/coreml));
the converted model is not the original. Provided as is, without warranties of
any kind; see Section 5 of the license.

### Whisper large-v3 turbo (Core ML)

- Downloaded from <https://huggingface.co/argmaxinc/whisperkit-coreml>, revision
  `0f63a7800b00dd0226abd051b906c246e1907482`, folder
  `openai_whisper-large-v3-v20240930_turbo/`: `AudioEncoder.mlmodelc`,
  `MelSpectrogram.mlmodelc`, `TextDecoder.mlmodelc`,
  `TextDecoderContextPrefill.mlmodelc`, `config.json`, `generation_config.json`.
- License: MIT, as declared in the repository's model card metadata. The
  repository has no separate license file. Converted to Core ML by Argmax.
- Original model: [OpenAI Whisper](https://github.com/openai/whisper). Its
  README states: "Whisper's code and model weights are released under the MIT
  License."

```text
MIT License

Copyright (c) 2022 OpenAI

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

### Whisper tokenizer

- Downloaded from <https://huggingface.co/openai/whisper-large-v3>, revision
  `06f233fe06e710322aca913c1bc4249a0d71fce1`. Only the tokenizer and
  configuration files are downloaded, no model weights: `added_tokens.json`,
  `config.json`, `generation_config.json`, `merges.txt`, `normalizer.json`,
  `preprocessor_config.json`, `special_tokens_map.json`, `tokenizer.json`,
  `tokenizer_config.json`, `vocab.json`.
- License: Apache License 2.0, as declared in the repository's model card
  metadata (`license: apache-2.0`); text at the end of this file. OpenAI's own
  Whisper repository on GitHub uses the MIT License reproduced above.

### Silero VAD v6.2.1 (Core ML)

- Downloaded from <https://huggingface.co/FluidInference/silero-vad-coreml>,
  revision `b419383c55c110e2c9271fa6ee0ea83d03c70d96`, folder
  `silero-vad-unified-256ms-v6.2.1.mlmodelc/`.
- License: MIT, in both the model card metadata and its text. Developed by the
  Silero Team, converted to Core ML by FluidInference.
- Original model: [Silero VAD](https://github.com/snakers4/silero-vad).

```text
MIT License

Copyright (c) 2020-present Silero Team

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Apache License 2.0

Applies to swift-transformers (in WhisperKit), FluidAudio, VBx and NVIDIA NeMo
(in FluidAudio) and the Whisper tokenizer files. The text below is FluidAudio's `LICENSE` file;
the terms in WhisperKit's `NOTICES` and FluidAudio's
`ThirdPartyLicenses/vbx-LICENSE.md` are the same.

```text
                                 Apache License
                           Version 2.0, January 2004
                        http://www.apache.org/licenses/

   TERMS AND CONDITIONS FOR USE, REPRODUCTION, AND DISTRIBUTION

   1. Definitions.

      "License" shall mean the terms and conditions for use, reproduction,
      and distribution as defined by Sections 1 through 9 of this document.

      "Licensor" shall mean the copyright owner or entity authorized by
      the copyright owner that is granting the License.

      "Legal Entity" shall mean the union of the acting entity and all
      other entities that control, are controlled by, or are under common
      control with that entity. For the purposes of this definition,
      "control" means (i) the power, direct or indirect, to cause the
      direction or management of such entity, whether by contract or
      otherwise, or (ii) ownership of fifty percent (50%) or more of the
      outstanding shares, or (iii) beneficial ownership of such entity.

      "You" (or "Your") shall mean an individual or Legal Entity
      exercising permissions granted by this License.

      "Source" form shall mean the preferred form for making modifications,
      including but not limited to software source code, documentation
      source, and configuration files.

      "Object" form shall mean any form resulting from mechanical
      transformation or translation of a Source form, including but
      not limited to compiled object code, generated documentation,
      and conversions to other media types.

      "Work" shall mean the work of authorship, whether in Source or
      Object form, made available under the License, as indicated by a
      copyright notice that is included in or attached to the work
      (an example is provided in the Appendix below).

      "Derivative Works" shall mean any work, whether in Source or Object
      form, that is based on (or derived from) the Work and for which the
      editorial revisions, annotations, elaborations, or other modifications
      represent, as a whole, an original work of authorship. For the purposes
      of this License, Derivative Works shall not include works that remain
      separable from, or merely link (or bind by name) to the interfaces of,
      the Work and Derivative Works thereof.

      "Contribution" shall mean any work of authorship, including
      the original version of the Work and any modifications or additions
      to that Work or Derivative Works thereof, that is intentionally
      submitted to Licensor for inclusion in the Work by the copyright owner
      or by an individual or Legal Entity authorized to submit on behalf of
      the copyright owner. For the purposes of this definition, "submitted"
      means any form of electronic, verbal, or written communication sent
      to the Licensor or its representatives, including but not limited to
      communication on electronic mailing lists, source code control systems,
      and issue tracking systems that are managed by, or on behalf of, the
      Licensor for the purpose of discussing and improving the Work, but
      excluding communication that is conspicuously marked or otherwise
      designated in writing by the copyright owner as "Not a Contribution."

      "Contributor" shall mean Licensor and any individual or Legal Entity
      on behalf of whom a Contribution has been received by Licensor and
      subsequently incorporated within the Work.

   2. Grant of Copyright License. Subject to the terms and conditions of
      this License, each Contributor hereby grants to You a perpetual,
      worldwide, non-exclusive, no-charge, royalty-free, irrevocable
      copyright license to reproduce, prepare Derivative Works of,
      publicly display, publicly perform, sublicense, and distribute the
      Work and such Derivative Works in Source or Object form.

   3. Grant of Patent License. Subject to the terms and conditions of
      this License, each Contributor hereby grants to You a perpetual,
      worldwide, non-exclusive, no-charge, royalty-free, irrevocable
      (except as stated in this section) patent license to make, have made,
      use, offer to sell, sell, import, and otherwise transfer the Work,
      where such license applies only to those patent claims licensable
      by such Contributor that are necessarily infringed by their
      Contribution(s) alone or by combination of their Contribution(s)
      with the Work to which such Contribution(s) was submitted. If You
      institute patent litigation against any entity (including a
      cross-claim or counterclaim in a lawsuit) alleging that the Work
      or a Contribution incorporated within the Work constitutes direct
      or contributory patent infringement, then any patent licenses
      granted to You under this License for that Work shall terminate
      as of the date such litigation is filed.

   4. Redistribution. You may reproduce and distribute copies of the
      Work or Derivative Works thereof in any medium, with or without
      modifications, and in Source or Object form, provided that You
      meet the following conditions:

      (a) You must give any other recipients of the Work or
          Derivative Works a copy of this License; and

      (b) You must cause any modified files to carry prominent notices
          stating that You changed the files; and

      (c) You must retain, in the Source form of any Derivative Works
          that You distribute, all copyright, patent, trademark, and
          attribution notices from the Source form of the Work,
          excluding those notices that do not pertain to any part of
          the Derivative Works; and

      (d) If the Work includes a "NOTICE" text file as part of its
          distribution, then any Derivative Works that You distribute must
          include a readable copy of the attribution notices contained
          within such NOTICE file, excluding those notices that do not
          pertain to any part of the Derivative Works, in at least one
          of the following places: within a NOTICE text file distributed
          as part of the Derivative Works; within the Source form or
          documentation, if provided along with the Derivative Works; or,
          within a display generated by the Derivative Works, if and
          wherever such third-party notices normally appear. The contents
          of the NOTICE file are for informational purposes only and
          do not modify the License. You may add Your own attribution
          notices within Derivative Works that You distribute, alongside
          or as an addendum to the NOTICE text from the Work, provided
          that such additional attribution notices cannot be construed
          as modifying the License.

      You may add Your own copyright statement to Your modifications and
      may provide additional or different license terms and conditions
      for use, reproduction, or distribution of Your modifications, or
      for any such Derivative Works as a whole, provided Your use,
      reproduction, and distribution of the Work otherwise complies with
      the conditions stated in this License.

   5. Submission of Contributions. Unless You explicitly state otherwise,
      any Contribution intentionally submitted for inclusion in the Work
      by You to the Licensor shall be under the terms and conditions of
      this License, without any additional terms or conditions.
      Notwithstanding the above, nothing herein shall supersede or modify
      the terms of any separate license agreement you may have executed
      with Licensor regarding such Contributions.

   6. Trademarks. This License does not grant permission to use the trade
      names, trademarks, service marks, or product names of the Licensor,
      except as required for reasonable and customary use in describing the
      origin of the Work and reproducing the content of the NOTICE file.

   7. Disclaimer of Warranty. Unless required by applicable law or
      agreed to in writing, Licensor provides the Work (and each
      Contributor provides its Contributions) on an "AS IS" BASIS,
      WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
      implied, including, without limitation, any warranties or conditions
      of TITLE, NON-INFRINGEMENT, MERCHANTABILITY, or FITNESS FOR A
      PARTICULAR PURPOSE. You are solely responsible for determining the
      appropriateness of using or redistributing the Work and assume any
      risks associated with Your exercise of permissions under this License.

   8. Limitation of Liability. In no event and under no legal theory,
      whether in tort (including negligence), contract, or otherwise,
      unless required by applicable law (such as deliberate and grossly
      negligent acts) or agreed to in writing, shall any Contributor be
      liable to You for damages, including any direct, indirect, special,
      incidental, or consequential damages of any character arising as a
      result of this License or out of the use or inability to use the
      Work (including but not limited to damages for loss of goodwill,
      work stoppage, computer failure or malfunction, or any and all
      other commercial damages or losses), even if such Contributor
      has been advised of the possibility of such damages.

   9. Accepting Warranty or Additional Liability. While redistributing
      the Work or Derivative Works thereof, You may choose to offer,
      and charge a fee for, acceptance of support, warranty, indemnity,
      or other liability obligations and/or rights consistent with this
      License. However, in accepting such obligations, You may act only
      on Your own behalf and on Your sole responsibility, not on behalf
      of any other Contributor, and only if You agree to indemnify,
      defend, and hold each Contributor harmless for any liability
      incurred by, or claims asserted against, such Contributor by reason
      of your accepting any such warranty or additional liability.

   END OF TERMS AND CONDITIONS

   APPENDIX: How to apply the Apache License to your work.

      To apply the Apache License to your work, attach the following
      boilerplate notice, with the fields enclosed by brackets "[]"
      replaced with your own identifying information. (Don't include
      the brackets!)  The text should be enclosed in the appropriate
      comment syntax for the file format. We also recommend that a
      file or class name and description of purpose be included on the
      same "printed page" as the copyright notice for easier
      identification within third-party archives.

   Copyright [yyyy] [name of copyright owner]

   Licensed under the Apache License, Version 2.0 (the "License");
   you may not use this file except in compliance with the License.
   You may obtain a copy of the License at

       http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
   See the License for the specific language governing permissions and
   limitations under the License.
```
