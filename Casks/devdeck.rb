cask "devdeck" do
  version "0.1.9"
  sha256 "81ca1989aec5bb27e8d37390d9c20ad12f1474958a205b1943f43ee7e486bfb5"

  url "https://github.com/SeanLuis/devdeck/releases/download/v#{version}/DevDeck.zip"
  name "DevDeck"
  desc "System monitor that attributes load to projects, coding agents and containers"
  homepage "https://github.com/SeanLuis/devdeck"

  depends_on macos: :sonoma

  app "DevDeck.app"
  binary "#{appdir}/DevDeck.app/Contents/MacOS/DevDeck", target: "devdeck"

  zap trash: "~/Library/Application Support/DevDeck"
end
