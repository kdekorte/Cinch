cask "cinch" do
  version "1.0"
  # Re-generate for every release with scripts/release.sh (it prints the sha256)
  sha256 "8e6f98cf6010b85ef24559416da187a0d6aef054c82527cc3f16921fd8e4e41b"

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
