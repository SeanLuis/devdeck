cask "devdeck" do
  version "0.1.7"
  sha256 "5653a746536dd782b1b1cc8f5b566df2497acdced63063f99ef13a72a1fd122d"

  url "https://github.com/SeanLuis/devdeck/releases/download/v#{version}/DevDeck.zip"
  name "DevDeck"
  desc "System monitor that attributes load to projects, coding agents and containers"
  homepage "https://github.com/SeanLuis/devdeck"

  depends_on macos: :sonoma

  app "DevDeck.app"
  binary "#{appdir}/DevDeck.app/Contents/MacOS/DevDeck", target: "devdeck"

  zap trash: "~/Library/Application Support/DevDeck"
end
