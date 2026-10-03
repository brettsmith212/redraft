# Redraft

A quiet Markdown writing app for macOS. A plain page by default; writing tools appear when you want them.

Inspired by Jason Fried's [demo](https://x.com/jasonfried/status/2105403067793584590) of his own writing app.

## Install

1. Download the `.dmg` from the [latest release](https://github.com/brettsmith212/redraft/releases/latest).
2. Open it and drag **Redraft** to Applications.

Requires macOS 14 or later. Signed and notarized by Apple, and it keeps itself up to date.

Optional: **Redraft → Install Shell Command…** adds a `redraft` command for opening files from a terminal:

```bash
redraft draft.md    # open a file (created if it doesn't exist)
```

## First steps

1. **Write.** The page is all you see. Edits save to disk automatically within a couple of seconds.
   Quit with ⌘Q and your documents reopen where you left off; close a window and it stays closed. With nothing open, Redraft shows a welcome window with your recent files.
2. **The writing tools** sit in the bottom-right corner. Click › at their end to tuck them away for plain writing, and the pencil to bring them back (or click the word count).
3. **Select some text.** A small bar offers Alternatives, AI, Ghost and Stash.
4. **Take the tour** from the Help menu, where you'll also find the practice document, every shortcut (⌘/) and Send Feedback.

## Features

| Feature | What it does |
| --- | --- |
| **Alternatives** | Keep several versions of a word, sentence or paragraph. A wavy underline and dots mark them. Hover and press → / ← to try each one; a lower tone plays when you're back on the original. Click the dots to see them all. |
| **AI alternatives** | Suggestions that fit the sentence, marked ✦. Type `??` in the panel for more. |
| **Ghost** | Dims text instead of deleting it. It stays in the file but leaves the word count, preview and copied text. |
| **Overflow** | A side drawer for spare paragraphs and notes. |
| **Lab** | AI editing that points things out and never rewrites: convoluted sentences, off-tone words, and trims (slight, tighten, sharper, half) shown as strike-throughs you cut or keep. Hover a tool and click its sliders icon (or right-click it) to edit its prompt; **New tool** adds your own. |
| **Zen** | Full screen with one key; everything else works as usual. Toggle again to return to how the window was. |
| **Markdown** | Styled as you type; the symbols hide outside the line you're editing. Preview renders it. |
| **Vim mode** | Normal, insert, visual and visual-line modes, with your own mappings. |
| **Export** | **File → Export Clean Copy…** saves the finished essay as a new Markdown or HTML file: current alternatives only, no ghosted text, overflow or Redraft notes. Your working file is untouched. Also: copy clean text, post to X. |

## Shortcuts

Standard Mac shortcuts (⌘S, ⌘Z, ⌘C, ⌘,) work as usual. Use Caps Lock as Control, or want plain ⌃ keys left to Vim? Settings → Keyboard → Shortcuts switches Redraft's own shortcuts to **Control + Shift + letter** (⌃⇧ column).

| Action | Keys | ⌃⇧ style |
| --- | --- | --- |
| Show / hide writing tools | ⇧⌘E, or click the word count | ⌃⇧E |
| Alternatives for a selection (or open/close the panel) | ⌥⌘A, or right-click | ⌃⇧A |
| AI alternatives | ⌥⌘I | ⌃⇧I |
| Next / previous alternative | Hover the underline + → / ←, or ⌥⌘↓ / ⌥⌘↑ | ⌃⇧J / ⌃⇧K |
| In the alternatives panel | Return adds · `??` asks AI · click applies · ↑ ↓ cycle · Delete removes | |
| Ghost / revive | ⌥⌘G | ⌃⇧G |
| Stash in overflow | ⌥⌘S | ⌃⇧S |
| Overflow / Lab | ⌥⌘O / ⌥⌘L | ⌃⇧O / ⌃⇧L |
| Preview | ⌥⌘P | ⌃⇧P |
| Zen mode (full screen) | ⌃⌘Z | ⌃⇧Z |
| Zoom in / out / actual size | ⌘+ / ⌘− / ⌘0 (resets each launch) | |
| New tab / close tab | ⌘T / ⌘W | |
| Show all tabs | ⇧⌘\\ or pinch in on the page | |
| Next / previous tab | ⌃Tab / ⌃⇧Tab | |
| Export clean copy | ⌥⇧⌘E | |
| Copy clean text | ⇧⌘C | ⌃⇧C |
| All shortcuts | ⌘/ | ⌘/ |

## Vim

Turn on in Settings → Keyboard → Vim. Mappings are written vimrc-style, e.g. `inoremap jk <Esc>`, and are always non-recursive.

Supported: counts; `h j k l w b e W B E 0 ^ $ gg G { } ( ) f t F T ; ,`; `d c y` with motions and text objects (`iw aw is as ip ap`, quotes `" ' `` ` ``, brackets `( [ { <`); `dd cc yy x X s S D C Y p P r J ~ u ⌃r .`; `i a I A o O`; `v V`; `/ n N *`; `⌃d ⌃u ⌃f ⌃b`. Yank and delete use the system clipboard.

By default, line commands work on the line you see, not the whole wrapped paragraph: `j k 0 ^ $ A I D C dd cc yy V`. Turn off "Line motions follow wrapped lines" (Settings → Keyboard) for strict Vim; `gj gk g0 g^ g$` still move by screen line.

Alternatives: hover an underlined word and press → / ←, or use `]a` / `[a` on the word under the cursor.

## AI

The first time you use an AI feature, Redraft offers to connect. Choose one (Settings → AI):

- **Sign in with ChatGPT** to use the plan you already have; no API key needed (defaults to Astra, medium reasoning)
- **Anthropic API key** (defaults to Claude Sonnet 5.5)
- **OpenAI API key**

One model and one **Reasoning** level drive alternatives, `??` and the Lab. Lower reasoning is faster. Results appear as they stream in. Keys and sign-in tokens live in your Keychain.

## Updates

Redraft checks for updates about once a day. When one is ready, a small **Update** label appears in the top bar; click it to see what's new and install. Settings → Editor → Updates can install them automatically instead, and **Redraft → Check for Updates…** checks right away.

## Files

- **Documents** are plain `.md` files, saved wherever you choose. New documents show **Not saved** (top bar) until you give them a name with ⌘S. Move the pointer to the top edge to see the file's name; click it for its folder, Show in Finder, Copy Path and Rename.
- **Alternatives and ghosts** are inline `<span>` tags, so other Markdown apps show your current wording. The alternatives list and overflow sit in an HTML comment at the end of the file. Reading a Redraft file elsewhere is fine; editing it in another app can lose its alternatives, so do that in Redraft (or export a clean copy first).
- **Settings and Lab tools** live in `~/Library/Preferences/com.brettsmith.Redraft.plist`.

## Privacy

Redraft has no account, analytics or tracking.

- **AI features** send text to the provider you chose (OpenAI or Anthropic): the selected passage for alternatives, the whole document for the Lab. Nothing is sent until you use an AI feature.
- **Keys and sign-in tokens** stay in your macOS Keychain. Documents stay where you save them.
- **Update checks** fetch a small file from GitHub about once a day, which shares only the app and macOS version. You can turn this off in Settings → Editor → Updates.

## Feedback

Found a bug or have an idea? [Open an issue](https://github.com/brettsmith212/redraft/issues/new), or use **Help → Send Feedback…** in the app.

## Development

Building from source needs Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`):

```bash
make run        # build and launch a debug build
make install    # release build → /Applications/Redraft.app
```

**Shipping a version** (maintainer): `make release V=0.1.0` sets the version, builds a Developer ID signed and notarized `.dmg`, publishes a GitHub Release, adds it to the update feed (`appcast.xml`), and installs that copy. It needs the Developer ID certificate, saved notarization credentials (see the comments above `dmg` in the Makefile), and the Sparkle update key in the Keychain (account `redraft`).

## License

[MIT](LICENSE)
