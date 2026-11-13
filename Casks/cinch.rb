cask "cinch" do
  version "1.2"
  # Re-generate for every release with scripts/release.sh (it prints the sha256)
  sha256 "6983f1dd1549604a846d7c4b94530228a07103e91033a2747a4cfa2add4c79cc"

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
