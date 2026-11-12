cask "cinch" do
  version "1.0"
  # Re-generate for every release with scripts/release.sh (it prints the sha256)
  sha256 "4254ec8eae2fea6631b10ce82050d5d0dbceaea796bacc1c4ebae1ef2e1c253a"

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
