cask "devdeck" do
  version "0.1.8"
  sha256 "36db0268dce13a82d369453bf6e582e292ad72e5f749cf5dfe71f82ad6538278"

  url "https://github.com/SeanLuis/devdeck/releases/download/v#{version}/DevDeck.zip"
  name "DevDeck"
  desc "System monitor that attributes load to projects, coding agents and containers"
  homepage "https://github.com/SeanLuis/devdeck"

  depends_on macos: :sonoma

  app "DevDeck.app"
  binary "#{appdir}/DevDeck.app/Contents/MacOS/DevDeck", target: "devdeck"

  zap trash: "~/Library/Application Support/DevDeck"
end
