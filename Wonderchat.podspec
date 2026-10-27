Pod::Spec.new do |s|
  s.name          = "Wonderchat"
  s.version       = "1.0.0"
  s.summary       = "Wonderchat AI support chat for iOS apps."
  s.homepage      = "https://wonderchat.io"
  s.license       = { :type => "MIT" }
  s.author        = { "Wonderchat" => "support@wonderchat.io" }
  s.platform      = :ios, "15.0"
  s.swift_version = "5.9"
  s.source        = { :git => "https://github.com/wonderchat/wonderchat-ios.git", :tag => s.version.to_s }
  s.source_files  = "Sources/Wonderchat/**/*.swift"
  s.frameworks    = "UIKit", "WebKit", "SwiftUI"
end
