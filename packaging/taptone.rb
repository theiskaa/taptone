# The taptone cask, as scripts/update-cask.sh first adds it to the tap
# (theiskaa/homebrew-tap, Casks/taptone.rb). Later releases change only its
# version and sha256 there, so carry other edits here to the tap by hand.
cask "taptone" do
  version "0.1.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/theiskaa/taptone/releases/download/v#{version}/Taptone-#{version}-macos.zip"
  name "Taptone"
  desc "Feel the bass of any audio through the Force Touch trackpad"
  homepage "https://github.com/theiskaa/taptone"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: :sonoma

  app "Taptone.app"

  uninstall quit: "com.theiskaa.taptone"

  zap trash: "~/Library/Preferences/com.theiskaa.taptone.plist"

  caveats <<~EOS
    Taptone needs macOS 14.2 or later and a Force Touch trackpad.
    Allow system audio access when macOS asks on first launch.
  EOS
end
