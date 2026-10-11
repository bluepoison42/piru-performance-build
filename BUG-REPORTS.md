# Reporting a bug

Something broke, crashed, or showed a number that looks wrong? Tell us. You don't need a GitHub
account or any developer knowledge. This page covers where to send a report, what to put in it,
and how to get the crash details from your phone or Mac so it can be fixed.

## Where to send it

Pick whichever is easiest for you. They all reach the same person.

| You have | Send it to |
|---|---|
| Discord | **[#bug-reports](https://discord.gg/hbpMZhPSdx)** on the Piru Discord. Start a new post with a short title ("crash when I open Journal"). The easiest option, and you can attach screenshots and files. |
| Piru from TestFlight on iPhone | **TestFlight feedback.** Take a screenshot in Piru and tap *Share Beta Feedback*, or open TestFlight → Piru → *Send Beta Feedback*. After a crash, iOS often asks whether to share it: say yes and add one line about what you were doing. |
| A GitHub account | **[A new issue](https://github.com/kageroumado/piru/issues/new/choose)** with the *Bug report* template. "Issue" is just GitHub's word for a bug report. |

Security or privacy problems (anything that could expose someone's journal) go privately, never
in public: see [SECURITY.md](SECURITY.md).

## What to write

Four things make a report fixable:

1. **What you did**, step by step: "Opened Settings → Your Body, deleted the weight, the app closed."
2. **What happened**, and what you expected instead.
3. **When** it happened (the time, roughly). Crash logs are stamped with the time, so this is how a
   report is matched to its log.
4. **Your device**: phone model, iOS/Android/macOS version, and Piru's version (Settings → About).

Screenshots and screen recordings help a lot. For a wrong curve, dose or timer, also share the
session: open it and tap **Share → Markdown**, then paste the result. It shows exactly what you
logged and what Piru calculated. Remove anything you'd rather keep to yourself.

## Getting the crash details

A description tells us *where* to look; the crash log tells us *what* went wrong. Here is how to
get one on each platform.

### iPhone and iPad

- **TestFlight users**: share the crash when TestFlight offers to; that sends the log for you.
- **Otherwise**: Settings → Privacy & Security → Analytics & Improvements → **Analytics Data**.
  Find entries starting with `Piru` and dated around the crash, open one, tap the share button,
  and attach it to your report. (This list only fills if *Share iPhone Analytics* is on.)

### Mac

Open the Console app → **Crash Reports** in the sidebar → the `Piru` entry from the time of the
crash → right-click → *Reveal in Finder*, and attach that `.ips` file. The files also live in
`~/Library/Logs/DiagnosticReports/`.

### Android

Android doesn't send crash reports to app developers on its own, so the details have to come from
your phone.

- **Settings → Report a problem** (alpha 4 and later). Piru collects why the app last closed or
  crashed, its own recent log, and your phone model and Android version into one file, then opens
  the share menu so you can send it on Discord or attach it to an issue. Do this right after the
  crash, before reinstalling or clearing the app's data. The file contains no journal entries and
  no substance names.
- **If Piru won't open at all** (it closes right away every time), use Android's built-in bug
  report instead:
  1. Settings → About phone → tap **Build number** seven times until it says you're a developer.
     On Samsung it's Settings → About phone → Software information → Build number.
  2. Settings → System → **Developer options** (on Samsung: Settings → Developer options) →
     **Take bug report** → *Interactive report*.
  3. Open Piru so it crashes once more, then wait for the "Bug report captured" notification
     (it can take a few minutes) and tap it to share the file.

  This report describes your whole phone, not only Piru, so send it **privately** (a direct message to a
  moderator on Discord) rather than posting it in a public channel or issue. You can turn Developer options off again
  afterwards.
