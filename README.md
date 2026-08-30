# WolfHouse Resource Pack Builder

This project combines the latest Java resource files from BuddyPack, WolfTeams, WolfSabers, and WolfPhone into one server-ready WolfHouse ZIP. The original plugin projects remain the source of truth; this project does not keep duplicate copies of their assets.

## Build the pack

Open PowerShell in this folder and run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Build-WolfHouseResourcePack.ps1
```

The result is written to `dist`. A changed source creates the next numbered release. Running the command again without changing any resources keeps the current revision.

Every release includes:

- `WolfHouse-ResourcePack-rN.zip`: the file to upload
- `.sha1`: the value Minecraft requires in `server.properties`
- `.sha256`: an independent integrity check
- `-build-report.txt`: included plugins, file counts, and hashes
- `-server.properties.txt`: safe copy-and-paste settings containing the permanent GitHub URL

The builder does not upload anything, edit the live server, or restart it.

## Normal future updates

For a new BuddyPack outfit or color:

1. Add or change the asset in `C:\Users\wolfh\IdeaProjects\BuddyPack\resource-pack\assets`.
2. Run the WolfHouse build command.
3. Publish a new GitHub Release (`r2`, `r3`, and so on) and upload the ZIP with the constant asset name `WolfHouse-ResourcePack.zip`.
4. Keep the existing permanent `resource-pack` URL and update `resource-pack-sha1` from the generated server template.
5. Restart normally.
6. Join with a clean client resource-pack cache and visually check Buddy models and WolfTeams menus.

The permanent download URL is:

```text
https://github.com/IronFaith/minecraft-/releases/latest/download/WolfHouse-ResourcePack.zip
```

WolfTeams updates follow the same steps using `C:\Users\wolfh\IdeaProjects\WolfTeams\resourcepack\assets`.

## Add a future Java plugin

The plugin needs a resource-pack source directory containing `pack.mcmeta` and `assets`. Give it a unique namespace such as `assets/newplugin` and target pack format 88.

Add one entry to `pack-sources.json`:

```json
{
  "name": "NewPlugin",
  "path": "../NewPlugin/resource-pack"
}
```

Then run the builder. From that point forward, the plugin is collected automatically.

Java and Bedrock packs are different formats. Do not register Geyser or Bedrock packs here.

## Collision protection

If two plugins provide the same destination file, the builder stops and names both plugins. Resolve the ownership deliberately; do not delete a file or let one plugin overwrite another just to make the build pass.

Files under `assets/minecraft` are global and deserve extra attention. If a future plugin needs to share a global JSON file such as `font/default.json`, add an intentional merge rule and a focused test before registering it.

## Run the checks

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\PackBuilder.Tests.ps1
```

The three checks cover source inventory and pack-format handling, collision rejection, and root-level ZIP/revision behavior.
