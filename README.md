# feed widget for notification center

A small native macOS Notification Center widget for your X and Instagram feeds. A menu bar app collects posts from signed-in WebKit sessions; the widget displays text, cached photos, video posters, and previous/next page controls. Open a post to view its full content on the original site.

WidgetKit provides snapshots and pagination, so the widget has no free scrolling or inline video playback. The collector refreshes every five minutes by default and retains the last successful feed when a source is unavailable. macOS controls when widget updates appear.

## Requirements

- macOS 14 or later.
- Full Xcode 16 or later, including the macOS SDK. Command Line Tools alone are insufficient.
- `xcodegen` and Python 3 available on `PATH`.
- Node.js 24 or later and npm for the test suite.
- Your own valid code-signing identity and Apple development team for an installed widget.

## Build

From the repository root:

```sh
./build.sh --unsigned
```

This is a compile-only build; `./build.sh` uses the same unsigned default. To create an app for installation, supply your own signing values:

```sh
export FEEDBAR_TEAM_ID="YOUR_TEAM_ID"
export FEEDBAR_SIGNING_IDENTITY="YOUR_CODE_SIGNING_IDENTITY"
./build.sh --signed
```

The identity must be available in your Keychain. Optional settings:

| Variable | Purpose |
| --- | --- |
| `FEEDBAR_APP_GROUP` | Override the shared App Group identifier. It must start with your team ID followed by a period. |
| `DEVELOPER_DIR` | Select the full Xcode installation used for this build. |
| `FEEDBAR_BUILD_DIR` | Choose a build output directory. |

The script reports the resulting app path. Installation and launch are separate manual steps.

## Install and connect

1. Copy the signed `FeedBar.app` to Applications and launch it.
2. Use its menu bar icon to open X and Instagram and sign in. Close each sign-in window when finished, then choose **Refresh Now**.
3. Open Notification Center, choose **Edit Widgets**, and add **Feed** from FeedBar.

FeedBar requests **Start at Login** on first launch to keep the collector available. Manage this from Preferences or macOS Login Items settings. Keep the menu bar app running for fresh posts; the widget can display saved posts while it is closed.

## Preferences

Choose **Preferences…** from the FeedBar menu bar icon, or the widget’s settings button. Changes save automatically.

- **General:** refresh manually or every 5, 10, 15, 30, or 60 minutes; manage Start at Login; refresh now.
- **Appearance:** system, light, or dark grayscale UI; small, standard, or large text; comfortable or compact density; show or hide media previews; standard or large media; fit entire images or fill the preview area.
- **Accounts:** check source status and open X or Instagram to sign in.

Manual mode skips automatic startup, timed, and wake refreshes. Explicit refresh actions and finishing sign-in still collect posts. Changing the interval lets an active refresh finish. Widget preferences are shared locally with the extension; macOS controls when the refreshed appearance appears. Smaller widgets and larger text may limit the number of visible posts.

For larger images, choose **Appearance → Media size → Large**. Large and extra-large widgets devote more space to each image and show fewer posts per page. The small and medium layouts also enlarge previews within their available space. Hide media to return to the selected feed density.

To resize the widget, **Control-click it in Notification Center and choose a size**. FeedBar supports small, medium, large, and extra-large layouts; available choices depend on macOS and the widget location. Notification Center uses preset sizes, so the widget cannot provide a freely draggable resize border. See [Apple’s widget guide](https://support.apple.com/108996).

## Tests

```sh
npm ci
npm test
```

Run these on macOS with the build requirements above. Tests use local HTML, generated media, and intercepted download fixtures; they do not sign in to live accounts.

## Data and limitations

No API keys are required. Sessions remain in local WebKit storage. Feed metadata, pagination state, and cached previews live in the local App Group shared by the app and widget. Preview downloads do not copy login cookies. Network access is still required to load the social sites and their media.

Extraction depends on the sites' page structure and currently recognizes English interface labels. Site changes, expired sessions, verification challenges, or rate limits can interrupt collection; the menu reports source status. Video posters may be available when a video itself cannot play outside the original page. Preview files are currently retained without automatic cache eviction.

## Contributing

Configure Git with your own name and GitHub noreply email before making commits. Keep credentials, signing identities, browser data, feed caches, and generated build artifacts out of the repository.

No license has been selected yet.
