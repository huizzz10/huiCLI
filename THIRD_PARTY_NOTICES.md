# Third-Party Notices / 第三方声明

This repository contains third-party components. The MIT license in
[LICENSE](LICENSE) applies to the original hui code only; the components below
remain under the licenses stated here.

## Apache License 2.0

The following components are licensed under the Apache License, Version 2.0.
A copy of the license text is provided in
[LICENSE-APACHE-2.0](LICENSE-APACHE-2.0).

### Ninja

- Location: `third_party/ninja/`
- Upstream: <https://github.com/ninja-build/ninja>
- Version: v1.12.1
- Copyright: 2011 Google Inc. and Ninja contributors; see the source headers
- License: Apache-2.0
- Modifications: `third_party/ninja/hui.patch`

### hui executor

- Location: `prebuilts/hui/hui`
- Built from Ninja v1.12.1 with `third_party/ninja/hui.patch`
- License: Apache-2.0
- Additional notice: `prebuilts/hui/NOTICE`

### Runa

- Location: `prebuilts/runa/runa`
- Upstream: <https://github.com/uwuAOSP/platform_external_runa>
- Copyright (C) 2026 The uwuAOSP Project
- License: Apache-2.0
- Additional notice: `prebuilts/runa/NOTICE`
- Provenance: `docs/runa-provenance.md`

### lib/admit.py

- Location: `lib/admit.py`
- Runtime admission policy derived from the uwuAOSP `uni` implementation in
  <https://github.com/uwuAOSP/uwuCLI>
- Copyright (C) 2026 The uwuAOSP Project
- License: Apache-2.0
- The file header carries the corresponding copyright and SPDX notice.

## Original hui code

Unless stated otherwise, the original hui code is:

Copyright (C) 2026 hui contributors
Licensed under the MIT License; see [LICENSE](LICENSE).
