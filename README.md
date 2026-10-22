# MySheets

A Mac spreadsheet that looks and works like Excel's grid, without the calculating.
It saves Excel files (`.xlsx`), so your files also open in Excel, Numbers and Google Sheets.

## Set it up with Claude Code

Open Claude Code in the folder where you keep your projects and paste:

```
Clone https://github.com/automatorsplus/my-sheets and set it up on my Mac by following its CLAUDE.md.
```

Claude Code builds the app, runs its self-test and puts it in your Applications folder. It needs an Apple Silicon Mac on
macOS 14 or later. The app is built on your own Mac, so macOS doesn't block it as a download from an unknown developer.

To build it by hand instead: `./build.sh`, then open `build/MySheets.app`.

## Open it

MySheets opens on **Home**, which lists your workbooks. To make double-clicking an Excel file (`.xlsx`) open it in
MySheets, right-click any `.xlsx` in Finder → Get Info → Open with → MySheets → Change All.

## How to do things

| To… | Do this |
|---|---|
| **Type in a cell** | Click it and type. Return goes down, Tab goes right. |
| **Change what's in a cell** | Double-click it (or press F2). Esc cancels. |
| **New line inside a cell** | Option-Return |
| **Select a row or column** | Click its number or letter. Drag across several. |
| **Select more than one area** | Hold ⌘ and click |
| **Make a row taller or a column wider** | Drag the line between the numbers or letters |
| **Fit a column to its text** | Double-click the line to the right of its letter |
| **Exact size** | Format → Row Height… or Column Width… |
| **Hide a row or column** | Drag its line until it disappears, or Format → Hide |
| **Unhide** | Drag the thick line open again, or Format → Unhide |
| **Highlight** | Select, then click **Fill**. The ▾ next to it picks a colour. |
| **Bold or italic** | Select, then click **B** or ***I*** (or ⌘B, ⌘I). Click again to take it off. |
| **Text size** | Type or pick a size in the box next to ***I***, or click **A▲** / **A▼** for one step bigger or smaller. Rows grow to fit big text. |
| **Move rows between other rows** | Select the rows by their numbers, then drag the numbers up or down (as in Google Sheets). A green line shows where they'll go. Columns work the same way with their letters. |
| **…or the Excel way** | Select the rows, hold **Shift**, drag the green edge of the selection |
| **Move cells (replacing what's there)** | Drag the green edge of the selection, without Shift |
| **Copy instead of move** | Hold Option while dragging |
| **Insert or delete rows** | The **Insert** and **Delete** buttons, or right-click a row number |
| **Move rows with cut and paste** | Select rows, ⌘X, right-click a row number → Insert Cut Rows |
| **Jump to the end of the data** | ⌘ and an arrow key |
| **Go to a cell** | Type its address (like `B12`) in the box at the top left and press Return |
| **Bigger or smaller** | The slider at the bottom right, or ⌘+ and ⌘− |
| **Undo** | ⌘Z |

## Saving and finding your workbooks

- **Each workbook is its own Excel file** that you can see in Finder and double-click to open.
- **New workbook** (on Home, or ⌘N) first asks for a **name** and **where to keep it**, like Excel's
  Save box. It starts on the Desktop, then on wherever you chose last time. Click **Create**.
- **It saves by itself** after that. Every change saves as you go. Closing or quitting never loses
  anything and never asks. (⌘S still works if you like pressing it.)
- **Home** shows your workbooks, newest first, each with a small picture and its folder: every Excel
  file on the Desktop (and in any folder you've made a workbook in), plus every one you've opened.
  Click one to open it as a tab next to Home. To find one, type part of its name in **Find a workbook**.
- **Back to Home:** click the **Home** tab, the **Home** button at the top left, or press ⇧⌘H.
  The **+** at the end of the tabs also opens Home. Closing your last workbook brings Home back.
- **Start a new one:** **New workbook** on Home, or ⌘N.
- **Rename, copy or delete:** click **⋯** on a workbook's card (or right-click the card) → Rename…,
  Duplicate, Show in Finder or Move to Bin…. You can also rename an open workbook by clicking its name
  at the top of the window.
- **Go back to an earlier version:** File → Revert To → Browse All Versions…
- The first time, the Mac asks whether MySheets may use your Desktop folder. Click **Allow**.
- **Moving your sheets from Excel:** download each one as an Excel file (`.xlsx`), put it on the Desktop
  or in a folder, and double-click it. Remember MySheets doesn't calculate: formulas show their last
  answer and won't update when you change numbers.

**Excel files with extras:** if a file has things MySheets can't keep (charts, merged cells, comments
and so on), a yellow bar says so. When you change something, your changes go into a copy beside it
called "Name (MySheets)", and the original stays exactly as it was. A green bar shows you're in the copy.

## What it doesn't do

- **No calculating.** Formulas from Excel files show their last saved answer. Excel recalculates them when you open the file there.
- No charts, pivot tables, merged cells, comments or filters.
- You can change bold, italic, text size and fill colour. Other formatting from Excel files (font names, text colours, borders) is shown and kept, but can't be changed here.
