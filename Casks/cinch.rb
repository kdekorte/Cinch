cask "cinch" do
  version "1.1"
  # Re-generate for every release with scripts/release.sh (it prints the sha256)
  sha256 "3eb27d0ef70a6faa0efe9645ed619860fa486cfb292ea26f6b18361aafa3f7c0"

  url "https://github.com/kdekorte/Cinch/releases/download/v#{version}/Cinch-#{version}.zip"
  name "Cinch"
  desc "Zip archive browser and editor"
  homepage "https://github.com/kdekorte/Cinch"

  app "Cinch.app"

  zap trash: [
    "~/Library/Preferences/com.kdekorte.Cinch.plist",
    "~/Library/Saved Application State/com.kdekorte.Cinch.savedState",
  ]
end
