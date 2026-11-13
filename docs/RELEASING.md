# Releasing

Pushing a tag builds, signs, notarizes and publishes the app:

```bash
git tag v0.1.1
git push origin v0.1.1
```

The `Release` workflow runs the tests, builds `DevDeck.app` for Apple silicon and Intel, signs it with your Developer ID, sends it to Apple for notarization, staples the ticket, and attaches `DevDeck.zip` to the GitHub release. A notarized app opens with a normal double click, with no Gatekeeper warning.

To rebuild the app for a tag that already exists, run the workflow by hand: **Actions → Release → Run workflow** and type the tag.

## One-time setup

Notarization needs a paid [Apple Developer Program](https://developer.apple.com/programs/) membership (99 USD a year). There is no free way to notarize.

### 1. Developer ID certificate

1. In Xcode: **Settings → Accounts → your team → Manage Certificates → + → Developer ID Application**.
2. Open **Keychain Access**, find "Developer ID Application: Your Name (TEAMID)", right-click it and **Export** as a `.p12` file with a password.
3. Encode it:

   ```bash
   base64 -i DeveloperID.p12 | pbcopy
   ```

### 2. App Store Connect API key (for notarization)

1. Go to [App Store Connect → Users and Access → Integrations → App Store Connect API](https://appstoreconnect.apple.com/access/integrations/api).
2. Create a **Team key** with the **Developer** role and download the `AuthKey_XXXXXXXXXX.p8` file (it can only be downloaded once).
3. Note the **Key ID** and the **Issuer ID** shown on that page.
4. Encode the key:

   ```bash
   base64 -i AuthKey_XXXXXXXXXX.p8 | pbcopy
   ```

### 3. Repository secrets

In GitHub: **Settings → Secrets and variables → Actions → New repository secret**. Or from the terminal with `gh secret set NAME`.

| Secret | Value |
|---|---|
| `DEVELOPER_ID_P12` | The base64 text of the `.p12` |
| `DEVELOPER_ID_P12_PASSWORD` | The password you chose when exporting it |
| `APPLE_API_KEY` | The base64 text of the `.p8` |
| `APPLE_API_KEY_ID` | The Key ID |
| `APPLE_API_ISSUER_ID` | The Issuer ID |

Delete the `.p12` and `.p8` files from your Mac once they are stored as secrets, or keep them somewhere safe. Never commit them.

Without these secrets the workflow still publishes a zip, but it is ad-hoc signed: people have to right-click → Open the first time.

## Doing it by hand

```bash
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" UNIVERSAL=1 SKIP_INSTALL=1 ./scripts/bundle.sh
ditto -c -k --keepParent build/DevDeck.app build/DevDeck.zip
xcrun notarytool submit build/DevDeck.zip --key AuthKey.p8 --key-id KEYID --issuer ISSUERID --wait
xcrun stapler staple build/DevDeck.app
spctl --assess --type execute --verbose build/DevDeck.app     # "accepted, source=Notarized Developer ID"
ditto -c -k --keepParent build/DevDeck.app build/DevDeck.zip
```

If Apple rejects it, `xcrun notarytool log <submission id> --key … --key-id … --issuer …` says why.
