# Third-party notices

This repository contains software and media under different licenses. The
licenses are deliberately separated below; the root `LICENSE` does **not**
relicense the media in `assets/`.

## Project code and documentation

Unless a file says otherwise, source code, scripts, tests, and documentation in
this repository are licensed under the GNU General Public License, version 3 or
(at your option) any later version (`GPL-3.0-or-later`). See [`LICENSE`](LICENSE).

The compatibility API and rule implementation were developed with reference to
Open Source Sanguosha / QSanguosha. Using GPL-3.0-or-later keeps modifications
and any GPL-derived portions under terms compatible with that upstream project.

## Bundled media

The 470 media and skin configuration files committed under `assets/` at source
revision `1eded4c` (excluding `assets/README.md`) were copied without
modification from:

- **Work:** Open Source Sanguosha / QSanguosha materials
- **Source:** https://github.com/Mogara/QSanguosha
- **Source revision:** [`85baa7489157c023bb2528a40ce4ef4e12863387`](https://github.com/Mogara/QSanguosha/commit/85baa7489157c023bb2528a40ce4ef4e12863387)
- **Upstream attribution:** Moligaloo and the Open Source Sanguosha contributors
- **License declared by upstream:** Creative Commons
  Attribution-NonCommercial-NoDerivatives 4.0 International
  (`CC BY-NC-ND 4.0`)
- **License text:** [`LICENSES/CC-BY-NC-ND-4.0.txt`](LICENSES/CC-BY-NC-ND-4.0.txt)
- **License URL:** https://creativecommons.org/licenses/by-nc-nd/4.0/
- **Changes to the copied files:** none

The bundled media therefore may be shared only under the upstream license. In
particular:

1. give the attribution above and include or link the license;
2. do not use the bundled media commercially;
3. do not distribute edited, recolored, cropped, remixed, transcoded, or
   otherwise modified versions of the bundled media.

The project code may be modified under GPL-3.0-or-later, but that permission
does not extend to the bundled media. A commercial or differently licensed
distribution must remove `assets/` and use media for which the distributor has
the necessary rights. The game safely falls back to its built-in text and
shape rendering when media are absent; an authorized external resource root
may also be selected with `SGS_ASSET_ROOT`.

`docs/images/gameplay.jpg` is a project screenshot containing the bundled
media. Treat its embedded upstream media under CC BY-NC-ND 4.0 and retain the
attribution above when sharing the screenshot.

## Names and trademarks

“三国杀” and related names, characters, artwork, and marks may be trademarks or
copyrighted works of their respective owners. This is an unofficial fan
project and is not affiliated with, sponsored by, or endorsed by Yoka Games or
the QSanguosha contributors.

## Verification

`THIRD_PARTY_ASSETS.sha256` records the exact bytes reviewed for this notice.
Run `./tools/verify-assets.sh` after changing media. A changed checksum means
the “Changes: none” statement must be reviewed before distribution.
