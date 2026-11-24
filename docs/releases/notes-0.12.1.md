Keg 0.12.1 makes the console usable at every width from a phone to a wide screen, makes the Mac app quicker with long output and usable with VoiceOver throughout, and shows release notes when the Mac app offers an update.

## The console

- **Every page fits from 320 px wide to a wide monitor.** A page's actions stay in sight on a phone, where Run Container, Remove, Approve and Reject could sit past the edge of a toolbar that scrolled with no scroll bar. A name of 200 characters no longer breaks a page, a dialog or a table. On a wide screen, prose is at most 100 characters a line.
- **Made for a finger and for the keyboard.** Below 768 px, what you press is at least 44 px each way, and no text is smaller than 12 px. The sidebar's drawer is used with the keyboard: shut, its links are no longer reached by Tab; opened, focus moves into it. A click on the magnifier opens the filter. With reduced motion asked for, nothing moves.
- **Lighter at rest.** The console asks for containers' use only on the pages that show it, and for what only Events shows only there: 3 requests a minute on Overview where it made 33, with no redraws.
- **Long lists are quick.** A list of hundreds is drawn 200 rows at a time. With 500 containers a redraw takes about 21 ms where it took 53 to 80, and scrolling no longer stutters.
- **It recovers.** A request that was never answered left the console on its loading page for good; now it gives up on that request after 8 seconds and goes on.

## The Mac app

- **Check for Updates shows what is new.** The offer of an update carries the release's notes; it showed only a version number. Updating from 0.10.0, 0.11.1 and 0.12.0 was checked: offered, downloaded, verified and installed.
- **Usable with VoiceOver, Voice Control and Switch Control.** Every toolbar button can be pressed (New Work, Approve, Reject, Run a Container and others could not), and a button repeated in a list says which row it acts on: "Approve work 12", "Remove the shared folder …".
- **Quick with long output.** A piece of work with a 3,000-line difference, or a container with 20,000 lines of output, stopped the app answering for one to two seconds; both now open in about 0.15 s.
- **Storage's Clean Up sheet scrolls**, so its question and buttons stay in reach however much there is to tick, and it says "These go." only when something does.
- **Sizes read the same everywhere**, as the console and `keg cleanup` write them: the same disk is 28 GB in Overview and in Storage.
- **Text size makes all the app's text larger or smaller**, captions and Needs you included.
- Needs you stays readable in a narrow window or a long language; New work asks the node about a folder once, not at each letter typed; 23 more sentences are in the app's 37 other languages.

## Upgrading from 0.12.0

- `keg update`, then restart the node (`sudo systemctl restart kegd`). On a Mac the app updates itself.
- Nothing in an app, a service or a `keg.yaml` changes.

See [keg.rahultrikha.com](https://keg.rahultrikha.com) for more.
