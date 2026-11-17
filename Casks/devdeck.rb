cask "devdeck" do
  version "0.1.10"
  sha256 "257985d31dfbca8d9887320ac946829891907f78df1b946b872b7aaf0589e4b2"

  url "https://github.com/SeanLuis/devdeck/releases/download/v#{version}/DevDeck.zip"
  name "DevDeck"
  desc "System monitor that attributes load to projects, coding agents and containers"
  homepage "https://github.com/SeanLuis/devdeck"

  depends_on macos: :sonoma

  app "DevDeck.app"
  binary "#{appdir}/DevDeck.app/Contents/MacOS/DevDeck", target: "devdeck"

  zap trash: "~/Library/Application Support/DevDeck"
end
