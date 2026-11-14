cask "devdeck" do
  version "0.1.6"
  sha256 "a1be09a37adbccf162ce16cc3cd689a573f03862605e269126d2aa06cca25c22"

  url "https://github.com/SeanLuis/devdeck/releases/download/v#{version}/DevDeck.zip"
  name "DevDeck"
  desc "System monitor that attributes load to projects, coding agents and containers"
  homepage "https://github.com/SeanLuis/devdeck"

  depends_on macos: :sonoma

  app "DevDeck.app"
  binary "#{appdir}/DevDeck.app/Contents/MacOS/DevDeck", target: "devdeck"

  zap trash: "~/Library/Application Support/DevDeck"
end
