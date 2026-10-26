# WhatsApp Web's look, measured

The native UI (`ui/native/`) copies WhatsApp Web exactly. These numbers were read from the real page
on 2026-10-20 (WhatsApp Web 2.3000.1051067427). The page was logged in, and only computed styles and
geometry were read, never message text. They are what `ui/native/native.css` implements.

## Artwork and font

- **Icons** are WhatsApp's own SVGs. `tools/wa-icons.mjs BUNDLE_DIR assets/wa/icons` pulls them out
  of the WhatsApp Web bundles. They are not in git: they are WhatsApp's artwork.
  - At run time `look` (`source/qmlwhats/native/look.d`) writes one tinted copy per (icon, colour).
  - Five icons are drawn differently in the page than in their bundle module: status, channels,
    communities, emoji and tail-out. For those the files were taken from the live page.
- **Wallpaper**: the doodle is `https://static.whatsapp.net/rsrc.php/yx/r/voSdkk88H7C.svg`, saved as
  `assets/wa/doodle.svg`.
  - WhatsApp uses it as a mask 540×960 px, repeated, filled with the foreground wallpaper colour, and
    fades the whole layer.
  - Dark: white, layer opacity 0.06, over #161717.
  - Light: #EAE0D3, layer opacity 0.6, over #F5F1EB.
- **Font**: "Roboto Variable" 100–900, at 16px with weights 400/500/545/600. The UI ships it as
  `ui/native/fonts/Roboto-Variable.ttf` (OFL). Our weight 545 is 500.

## Tokens (WDS), dark | light

| token | dark | light |
|---|---|---|
| surface-default (list, headers) | #161717 | #FFFFFF |
| surface-emphasized, nav bar | #1D1F1F | #F7F5F3 |
| highlight (hover, selected row, active nav) | rgba(255,255,255,.1) | rgba(194,189,184,.15) |
| content-default | #FAFAFA | #0A0A0A |
| content-deemphasized | rgba(255,255,255,.6) | rgba(0,0,0,.6) |
| divider | rgba(255,255,255,.1) | rgba(0,0,0,.1) |
| outline-deemphasized (chip border) | rgba(255,255,255,.1) | rgba(0,0,0,.2) |
| accent | #21C063 | #1DAA61 |
| accent-deemphasized (selected chip) | #103529 | #D9FDD3 |
| accent-emphasized (selected chip text) | #D9FDD3 | #15603E |
| content-on-accent | #0A0A0A | #FFFFFF |
| content-read (blue ticks) | #53BDEB | #007BFC |
| bubble incoming | #242626 | #FFFFFF |
| bubble outgoing | #144D37 | #D9FDD3 |
| bubble system (day pill) | #1D1F1F | rgba(255,255,255,.9) |
| chat wallpaper | #161717 | #F5F1EB |
| composer | #242626 | #FFFFFF |

Default pictures and group sender names use the profile-photo palette: 11 (surface, content) pairs,
brown, cobalt, gray, green, orange, pink, purple, red, sky-blue, teal and yellow. Both themes are in
`Native.tsx` (PHOTO_DARK / PHOTO_LIGHT).

## Layout

- **Navigation rail**: 64 px wide, padding 10/12.
  - Buttons are 40×40, round, with a gap of 4; icons are 24.
  - The top group is Chats, Calls, Status, Channels, Communities, then a 1 px divider with 8 px
    margins, then Meta AI.
  - The bottom group is Media and the profile picture (24).
  - The unread badge sits at (+22, −6): 24 high, a 2 px border in the nav colour, accent fill, text
    12 px / 545.
- **Chat list**:
  - Width is 40 % of the window, or 30 % above 1300 px (min 260). There is a 1 px divider on its left
    and on the conversation's left.
  - Header: 64 high, padding 10/20, the 104×28 wordmark, then New chat and Menu buttons (40, gap 8).
  - Search: margin 0 20 4, a pill 40 high (r 20) in highlight. Icon 20 at 16 / 12, then the input at
    14 px, letter-spacing .16.
  - Filters: padding 4 10 6 20, gap 8. Chips are 32 high (r 16), padding 0 12, a 1 px outline, text
    14 / 545. Labels are Tudo, Não lidas (+count 12 px), Favoritas, Grupos (+count), then a 36 px
    dropdown.
  - Archived row: 49 high, margin 4 10, icon 24 in a 77 px column (padding 0 15 0 13).
  - Chat row: a 76 stride holding a 72 cell, margin 0 10, r 12.
    - Avatar 48 in a column padded 0 15 0 13.
    - Name 16 px / 24 lh.
    - Time 12 px, margin-left 6: deemphasized, or accent with weight 600 when unread.
    - Second line: margin-top 2, 14 px / 20 lh deemphasized. Tick 18×20 with margin-right 3.
    - Unread pill: min 20, padding 2 4, accent, text 12 / 545 on-accent, margin-left 6.
- **Conversation**:
  - Header: 64 high, padding 10/16, surface-default, shadow 0 1 4 rgba(10,10,10,.12).
    - Avatar 40 with 15 to its right, name 16 px / 600 / 21 lh.
    - Buttons 40 (gap 8, first margin 16): Video call, Voice call, Search, Menu. Calls are drawn at
      opacity .38 when unavailable.
  - Message list: 12 px top. Day pill: padding 4 12, r 6, system colour, text 12 / 545 deemphasized,
    then 12 below.
  - Rows: padding 0 57 0 62 (this UI uses 49/54 plus an 8 px tail slot).
    - 2 px between messages of one sender, 12 px after the last of a run.
    - Bubble max-width 65 %, r 7.5, shadow 0 1 .5 rgba(11,20,26,.13), padding 6 7 8 9.
    - The first bubble of a run has the 8×13 tail and a 0 radius on that corner.
  - Bubble text: 14 px / 20 lh, letter-spacing .16.
    - Time: 11 px / 15 lh (12 px digits), deemphasized, margin −10 0 −5 4.
    - Ticks are 16, margin-left 3.
    - The text ends with blank room the width of the time, so the time sits on its last line.
  - Group sender name: 12.8 px / 500 / 22 lh, in the sender's profile-photo content colour.
  - Composer: margin 0 12 12, min-height 52, r 26, padding 5, shadow 0 1 6 rgba(0,0,0,.12).
    - Attach and emoji buttons (40), emoji with margin-right 6.
    - Input 15 px / 22 lh.
    - Mic (40, margin-left 5), which becomes Send on an accent disc while there is text.
