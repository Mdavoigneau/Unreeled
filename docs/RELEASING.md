# Releasing Unreeled

Unreeled can't be on the App Store: App Review requires permission from the services an app uses. In the EU, Japan and Brazil, apps can be distributed through alternative marketplaces after Apple's lighter check, *notarization*, which looks at malware, accuracy, functionality and privacy. This page releases a version through [AltStore PAL](https://faq.altstore.io/developers/distribute-with-altstore-pal). The people working on the app can also get a build through TestFlight, with no review: [TestFlight, for the team](#testflight-for-the-team), at the end.

What notarization requires of Unreeled, and why it has it:

- **Accurate, and no impersonation** (guidelines 2.3.1, 4.1(b)): its own name and icon, and "not made or endorsed by Instagram or Meta" in the app and the listing.
- **A privacy policy** (5.1.1), linked in the app (About) and in App Store Connect: `https://unreeled.app/privacy`, from [PRIVACY.md](../PRIVACY.md).
- **No downloaded code** (2.5.2): the query list the app downloads is data (IDs and flags), signed by the project and checked before use.

Every upload to Apple is also asked, for export rules, whether the app uses encryption beyond the exempt kinds. `Config/Unreeled-Info.plist` answers no (`ITSAppUsesNonExemptEncryption`): all of Unreeled's encryption is the iPhone's own, which is HTTPS, the Keychain, and CryptoKit for the notification keys and for checking the query list's signature. Code that brought its own encryption would change that answer. [Apple's page](https://developer.apple.com/documentation/security/complying-with-encryption-export-regulations) says an app with exempt encryption may still owe the U.S. government a yearly self-classification report: whoever distributes a build decides that for themselves.

## Once

1. **Paid membership.** Join the Apple Developer Program (US$99 a year). The Account Holder accepts the latest Program License Agreement in App Store Connect; since 1 October 2026 it includes the EU terms (Attachment 14). Alternatively distributed apps pay Apple 5% of digital sales only; Unreeled sells nothing.
2. **Signing.** In `Config/Local.xcconfig`, set the paid team's ID and the release bundle ID, `app.unreeled.ios`.
3. **App record.** In App Store Connect, create the app: iOS, name "Unreeled", bundle ID `app.unreeled.ios`. Fill in:
   - Description, saying it's unofficial and not endorsed by Instagram or Meta.
   - Screenshots, age rating, category Social Networking, support URL `https://unreeled.app`.
   - Privacy policy URL `https://unreeled.app/privacy`. App Privacy: Data Not Collected.
   - App Review Information: sign-in required. Reviewers need an Instagram account to see the app working: give them a test account made for this, never your own.
4. **AltStore PAL.** Register your developer ID with AltStore's REST API, then paste the token it returns in App Store Connect › Users and Access › Integrations › Marketplace. Choose Unreeled, and "Yes, send notifications" so AltStore processes each build by itself. ([AltStore's steps](https://faq.altstore.io/developers/distribute-with-altstore-pal).)

## Each version

1. **Version numbers.** Raise `MARKETING_VERSION` (and `CURRENT_PROJECT_VERSION`) in the target's build settings. A new version sets aside the query list older versions downloaded, and fetches the current one at launch. Check the list it ships with is signed (`node tools/sign-queries.mjs check`): the app then knows not to take an older one.
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
      "bundleIdentifier": "app.unreeled.ios",
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

## TestFlight, for the team

TestFlight has two kinds of testers. *External* testers, who can join through a public link, get a build only after App Review has checked it against the App Store's rules, which is where Unreeled stops (above). *Internal* testers get every build with no review, but they must be users of the team's App Store Connect account: up to 100 people, each added under Users and Access. So this is for the people working on the app, not a way to hand it out. A build can be tested for 90 days ([Apple's overview](https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview)).

Once:

1. **Identifier.** At developer.apple.com › Certificates, Identifiers & Profiles › Identifiers, register the bundle ID as an explicit App ID, with Push Notifications ticked if the build has notifications. The notification extension's ID, the same with `.NotificationService` at the end, is registered by Xcode when it signs.
2. **App record,** as in [Once](#once) above. For testing, what the New App form asks for is enough.
3. **A key.** In App Store Connect › Users and Access › Integrations › App Store Connect API, make a team key with the Admin role (developers [report](https://developer.apple.com/forums/thread/698117) that a key with a lesser role is refused when it signs for distribution). Keep the file as it downloads, `AuthKey_<key ID>.p8`, in `~/.config/unreeled/appstoreconnect/`, with the Issuer ID from the same page in `issuer-id.txt` beside it, and both out of the repository. With the key, no account has to be signed in to Xcode. The archive is signed like any build for an iPhone, with the Mac's development certificate; for distribution Apple signs it with a certificate it keeps itself, so none sits on the Mac.
4. **A group.** In App Store Connect, on the app's TestFlight page, add a group under Internal Testing with automatic distribution, and the testers to it.
5. **The relay,** if the build has notifications: add the bundle ID to its `APNS_TOPIC` ([relay/worker](../relay/worker/README.md)). A build signed for App Store Connect is on Apple's production push service, whatever `Config/Push.entitlements` says.

Each build, once its build number (`CURRENT_PROJECT_VERSION`) is higher than the last one uploaded, which Apple checks:

```sh
tools/testflight.sh check app.unreeled.ios    # a rehearsal: nothing is uploaded
tools/testflight.sh upload app.unreeled.ios
```

`check` archives the app under that bundle ID (the one in `Config/Local.xcconfig` stays as it is), signs it for App Store Connect and has Apple validate the package, without uploading anything. `upload` does all of that and then sends the package. The group has the build once Apple has processed it, which took about a minute the first time.

The script marks the build for internal testing only: it can't be given to external testers or go any further afterwards. A build for notarization is uploaded without that mark, as in [Each version](#each-version).
