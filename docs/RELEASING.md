# Releasing Unreeled

Unreeled can't be on the App Store: App Review requires permission from the services an app uses. In the EU, Japan and Brazil, apps can be distributed through alternative marketplaces after Apple's lighter check, *notarization*, which looks at malware, accuracy, functionality and privacy. This page releases a version through [AltStore PAL](https://faq.altstore.io/developers/distribute-with-altstore-pal).

What notarization requires of Unreeled, and why it has it:

- **Accurate, and no impersonation** (guidelines 2.3.1, 4.1(b)): its own name and icon, and "not made or endorsed by Instagram or Meta" in the app and the listing.
- **A privacy policy** (5.1.1), linked in the app (About) and in App Store Connect: `https://unreeled.app/privacy`, from [PRIVACY.md](../PRIVACY.md).
- **No downloaded code** (2.5.2): the query list the app downloads is data (IDs and flags), checked before use.

## Once

1. **Paid membership.** Join the Apple Developer Program (US$99 a year). The Account Holder accepts the latest Program License Agreement in App Store Connect; since 1 October 2026 it includes the EU terms (Attachment 14). Alternatively distributed apps pay Apple 5% of digital sales only; Unreeled sells nothing.
2. **Signing.** In `Config/Local.xcconfig`, set the paid team's ID and the release bundle ID, `app.unreeled`.
3. **App record.** In App Store Connect, create the app: iOS, name "Unreeled", bundle ID `app.unreeled`. Fill in:
   - Description, saying it's unofficial and not endorsed by Instagram or Meta.
   - Screenshots, age rating, category Social Networking, support URL `https://unreeled.app`.
   - Privacy policy URL `https://unreeled.app/privacy`. App Privacy: Data Not Collected.
   - App Review Information: sign-in required. Reviewers need an Instagram account to see the app working: give them a test account made for this, never your own.
4. **AltStore PAL.** Register your developer ID with AltStore's REST API, then paste the token it returns in App Store Connect › Users and Access › Integrations › Marketplace. Choose Unreeled, and "Yes, send notifications" so AltStore processes each build by itself. ([AltStore's steps](https://faq.altstore.io/developers/distribute-with-altstore-pal).)

## Each version

1. **Version numbers.** Raise `MARKETING_VERSION` (and `CURRENT_PROJECT_VERSION`) in the target's build settings. A new version sets aside the query list older versions downloaded, and fetches the current one at launch.
2. **Archive and upload.** In Xcode, pick the **Unreeled for iPhone** scheme and "Any iOS Device", then Product › Archive. In the Organizer: Distribute App › App Store Connect › Upload.
3. **Notarization.** In App Store Connect, on the version's page: App Review Information › Review Type › Edit › **Notarization**, then Add for Review and Submit to App Review.
4. **The package.** Once it's approved and AltStore has processed it, download the Alternative Distribution Package with AltStore's REST API. Upload it to unreeled.app exactly as it is: same folders, same files, `manifest.json` untouched (its hashes are checked).
5. **The source.** Add the version at the top of `versions` in the source file on unreeled.app (below), with the package's `manifest.json` as `downloadURL` and its size in bytes.
6. **Check the permissions** still match the build: `codesign -d --entitlements :- Unreeled.app` on the exported app, and the usage descriptions in its Info.plist. AltStore refuses to install a build that doesn't match its source.

## The source file

Served from unreeled.app, for example `https://unreeled.app/altstore.json`. People add that address in AltStore PAL. The format is in [AltStore's documentation](https://faq.altstore.io/developers/make-a-source).

```json
{
  "name": "Unreeled",
  "subtitle": "Your friends on Instagram, without the rabbit hole.",
  "iconURL": "https://unreeled.app/icon.png",
  "website": "https://unreeled.app",
  "tintColor": "#3F729B",
  "apps": [
    {
      "name": "Unreeled",
      "bundleIdentifier": "app.unreeled",
      "marketplaceID": "<the app's Apple ID, from App Store Connect › App Information>",
      "developerName": "<as in App Store Connect>",
      "subtitle": "Your friends on Instagram, without the rabbit hole.",
      "localizedDescription": "Posts from the people you follow, newest first, their stories, and your messages. No Reels, no suggestions, no ads. Unofficial: not made or endorsed by Instagram or Meta.",
      "iconURL": "https://unreeled.app/icon.png",
      "tintColor": "#3F729B",
      "category": "social",
      "appPermissions": {
        "entitlements": [],
        "privacy": {
          "NSCameraUsageDescription": "Take photos and videos to post.",
          "NSMicrophoneUsageDescription": "Record voice messages and videos."
        }
      },
      "versions": [
        {
          "version": "1.0",
          "buildVersion": "1",
          "date": "2026-11-30",
          "localizedDescription": "First release.",
          "downloadURL": "https://unreeled.app/altstore/1.0/manifest.json",
          "size": 0,
          "minOSVersion": "18.0"
        }
      ]
    }
  ]
}
```

## Outside the EU, Japan and Brazil

AltStore PAL only installs there. Elsewhere, people can build the app themselves ([README](../README.md)).
