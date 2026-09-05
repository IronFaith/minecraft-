# WolfCraft TAB logo

The supplied transparent artwork is retained in originals/wolfcraft.png. The
256 x 151 texture is an aspect-preserving font-atlas export of that artwork.
Only assets/ is collected by the master pack builder.

Both fonts map U+E100 to the same logo at 24 GUI pixels high (about 41 wide).
logo_header uses ascent 8 and needs two empty header lines after the glyph.
logo_sidebar uses ascent 23 so the logo extends above the scoreboard title
without covering the first statistics row. Exact positioning requires an
in-game check with the player's GUI scale.

TAB text must be white, with no gradient or bold applied to the glyph.
The prepared TAB configuration keeps the original text for Bedrock and legacy
clients. Java clients must load the matching WolfHouse resource pack.