cask "cinch" do
  version "1.3"
  # Re-generate for every release with scripts/release.sh (it prints the sha256)
  sha256 "73a1bb4a7d21905e8ca71fa72709e9adb2cea5719245f496fd3a33b9c186aa8c"

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
