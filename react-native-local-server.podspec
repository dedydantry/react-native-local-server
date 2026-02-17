require "json"

package = JSON.parse(File.read(File.join(__dir__, "package.json")))

Pod::Spec.new do |s|
  s.name         = "react-native-local-server"
  s.version      = package["version"]
  s.summary      = package["description"]
  s.homepage     = "https://github.com/dedydantry/react-native-local-server"
  s.license      = "ISC"
  s.authors      = { "dedydantry" => "" }
  s.platforms    = { :ios => "13.0" }
  s.source       = { :git => "https://github.com/dedydantry/react-native-local-server.git", :tag => "#{s.version}" }

  s.source_files = "ios/**/*.{h,m,mm}"

  s.dependency "React-Core"
end
