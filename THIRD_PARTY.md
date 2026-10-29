# Third-party components

Cubicon Native provides the Swift application, mesh handling, settings bridge, toolpath preview and export workflow. The slicing engine and manufacturer profiles come from the projects below.

| Component | Source | License |
| --- | --- | --- |
| CuraEngine 5.13.0 | [Pinned source](https://github.com/Ultimaker/CuraEngine/tree/636f9608621fd1d6c1b75ad2a969de53beabfbc6) | AGPL-3.0-or-later |
| Cura definitions and material resources | [Cura 5.13.0](https://github.com/Ultimaker/Cura/tree/1fb8a7610460e03ec62da950d1c173a249b23b59) | LGPL-3.0 |
| Cubicon printer definitions | Cubicon R&D Center, distributed in Cura | See Cura resource license |
| libArcus | [UltiMaker/libArcus](https://github.com/Ultimaker/libArcus) | LGPL-3.0 |
| Clipper 6.4.2 / libpolyclipping | [skyrpex/clipper](https://github.com/skyrpex/clipper) | BSL-1.0 |
| oneTBB | [uxlfoundation/oneTBB](https://github.com/uxlfoundation/oneTBB) | Apache-2.0 |

License texts and source directions are retained in `native/Notices`. Original profile files and their SHA-256 values are retained in `native/ProfileSources`.

The build downloads the original Apple Silicon Cura installer and extracts unmodified native engine binaries. It does not commit those binaries to this repository. The installer URL and hash are pinned in `scripts/build-native.py`. Upstream engine dependency recipes, including statically linked dependencies, are available in [CuraEngine's pinned conanfile](https://github.com/Ultimaker/CuraEngine/blob/636f9608621fd1d6c1b75ad2a969de53beabfbc6/conanfile.py) and [conan-ultimaker-index](https://github.com/Ultimaker/conan-ultimaker-index).
