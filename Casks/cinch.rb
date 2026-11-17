cask "cinch" do
  version "1.3"
  # Re-generate for every release with scripts/release.sh (it prints the sha256)
  sha256 "8bc68e1be771fca73ee8c401b837316e1c1fe1b892168acf4a620c8162d0ef6b"

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
