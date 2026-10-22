# Setting up MySheets

You are setting up MySheets, a Mac spreadsheet that saves Excel files (`.xlsx`), on the user's Mac. Work through the
steps in order. Tell the user in one line what each step is doing. Don't change the source code unless the build fails,
and then change as little as possible and say what you changed.

## 1. Check the Mac

- `uname -m` must print `arm64` (Apple Silicon) and `sw_vers -productVersion` must be 14 or higher. If not, stop and tell
  the user MySheets needs an Apple Silicon Mac on macOS 14 or later.
- `xcode-select -p` must print a path. If it fails, run `xcode-select --install`, ask the user to click **Install** in
  the dialog, and wait until they say it has finished.

Nothing else is needed: no Homebrew, no Xcode.

## 2. Build

```sh
./build.sh
```

It prints `Built …/build/MySheets.app`. The first build takes a minute or two.

## 3. Run the self-test

```sh
build/MySheets.app/Contents/MacOS/MySheets --self-test
```

Every check should pass. If any fail, show the user which ones before going on.

## 4. Install and open

Ask the user whether to copy the app into Applications. If yes:

```sh
cp -R build/MySheets.app /Applications/
open /Applications/MySheets.app
```

Otherwise `open build/MySheets.app`. The first time, macOS asks whether MySheets may use the Desktop folder: tell the user
to click **Allow**, because Home lists the workbooks on the Desktop.

## 5. Hand over

Tell the user, briefly:

- **New workbook** on Home (or ⌘N) asks for a name and a place, then saves by itself as they work.
- Files are ordinary `.xlsx`, so they open in Excel, Numbers and Google Sheets too.
- To open `.xlsx` files in MySheets by double-clicking: right-click one in Finder → Get Info → Open with → MySheets →
  Change All.
- **It doesn't calculate.** Formulas from Excel files show their last saved answer. No charts, pivot tables, merged
  cells, comments or filters.

The README has the full list of what it can do.
